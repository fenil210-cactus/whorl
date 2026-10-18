import AppKit
import WhorlCore

/// Watches for "a file is being dragged, and a wheel key was tapped".
/// Needs Accessibility so modifier taps are visible while another app (Finder) is in front.
@MainActor
final class DragMonitor {
    private var monitors: [Any] = []
    private var previous = NSEvent.ModifierFlags()
    private var session: WheelSession?
    private var dragging = false
    private var boardCountAtMouseDown = 0

    func start() {
        stop()
        guard Prefs.wheelEnabled else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        session?.cancel()
        session = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragging = false
            boardCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            // A new drag has put new contents on the drag pasteboard. Without this check, a stale
            // drag from earlier could make the wheel appear on an ordinary click.
            if !dragging, NSPasteboard(name: .drag).changeCount != boardCountAtMouseDown { dragging = true }
        case .leftMouseUp:
            dragging = false
            if let session {
                // The wheel's own drop target normally ends the session; this covers drops it never saw.
                // The session stays referenced here until it ends, so the drop target can still find it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { session.cancel() }
            }
        case .flagsChanged:
            flagsChanged(event)
        default:
            break
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        let relevant: NSEvent.ModifierFlags = [.shift, .command, .control, .option]
        let now = event.modifierFlags.intersection(relevant)
        let pressed = now.subtracting(previous)
        previous = now
        guard dragging, !pressed.isEmpty, let mode = Prefs.mode(for: pressed) else { return }
        if let session {
            session.setMode(mode)
            return
        }
        guard let files = Self.dragFiles(), !files.isEmpty else { return }
        let engines = Engines.current
        let wedges = Catalog.wedges(extensions: files.map(\.pathExtension), mode: mode, engines: engines)
        // Opening the wheel with nothing on it would only confuse; Control (actions) always has content.
        guard !wedges.isEmpty || mode == .actions else { return }
        let session = WheelSession(files: files, mode: mode, at: NSEvent.mouseLocation)
        session.onEnd = { [weak self, weak session] in
            if self?.session === session { self?.session = nil }
        }
        self.session = session
    }

    static func dragFiles() -> [URL]? {
        let board = NSPasteboard(name: .drag)
        return board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}
