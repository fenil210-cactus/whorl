import AppKit
import WhorlCore

/// Watches for "a file is being dragged, and a wheel key was tapped".
///
/// This polls the live mouse-button and modifier-key state instead of installing event monitors.
/// Reading that state needs no permission, so the wheel works the moment the app is installed
/// (event monitors for key presses would need Accessibility, which an ad-hoc signed app keeps losing on update).
@MainActor
final class DragMonitor {
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var session: WheelSession?
    private var leftWasDown = false
    private var dragging = false
    private var boardCountAtMouseDown = 0
    private var mouseDownAt = CGPoint.zero
    private var draggedFiles: [URL] = []
    private var ticksSinceRead = 0
    private var previous = NSEvent.ModifierFlags()

    private static let idleInterval: TimeInterval = 1.0 / 20
    private static let dragInterval: TimeInterval = 1.0 / 90
    private static let relevant: NSEvent.ModifierFlags = [.shift, .command, .control, .option]

    func start() {
        stop()
        guard Prefs.wheelEnabled else { return }
        schedule(Self.idleInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        interval = 0
        session?.cancel()
        session = nil
        leftWasDown = false
        dragging = false
    }

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = seconds * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let flags = NSEvent.modifierFlags.intersection(Self.relevant)
        defer { previous = flags; leftWasDown = down }

        if down, !leftWasDown {
            dragging = false
            draggedFiles = []
            boardCountAtMouseDown = NSPasteboard(name: .drag).changeCount
            mouseDownAt = NSEvent.mouseLocation
            schedule(Self.dragInterval)
        } else if !down, leftWasDown {
            dragging = false
            schedule(Self.idleInterval)
            if let session {
                // The wheel's own drop target normally ends the session; this covers drops it never saw.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { session.cancel() }
            }
            return
        }
        guard down else { return }

        if !dragging {
            // A real drag puts new contents on the drag pasteboard. Without that check, an ordinary
            // click-and-hold with a key tap would summon the wheel.
            let moved = hypot(NSEvent.mouseLocation.x - mouseDownAt.x, NSEvent.mouseLocation.y - mouseDownAt.y)
            if moved > 4, NSPasteboard(name: .drag).changeCount != boardCountAtMouseDown {
                dragging = true
                ticksSinceRead = 99
                Log.debug("drag detected (changeCount \(boardCountAtMouseDown) -> \(NSPasteboard(name: .drag).changeCount))")
            }
        }

        // The files may land on the drag pasteboard a moment after the drag starts; keep trying (about 10 times a second).
        if dragging, draggedFiles.isEmpty {
            ticksSinceRead += 1
            if ticksSinceRead >= 9 {
                ticksSinceRead = 0
                draggedFiles = Self.dragFiles() ?? []
            }
        }

        let pressed = flags.subtracting(previous)
        guard dragging, !pressed.isEmpty, let mode = Prefs.mode(for: pressed) else { return }
        Log.debug("key tap -> \(mode.title)")
        if let session {
            session.setMode(mode)
            return
        }
        let files = draggedFiles.isEmpty ? (Self.dragFiles() ?? []) : draggedFiles
        // Opening the wheel with nothing on it would only confuse; Control (actions) always has content.
        // With no files known yet (see WheelSession.adopt) it opens anyway and fills in.
        if !files.isEmpty {
            let wedges = Catalog.wedges(extensions: files.map(\.pathExtension), mode: mode, engines: Engines.current)
            guard !wedges.isEmpty || mode == .actions else { Log.debug("no wedges for \(mode.title)"); return }
        }
        let session = WheelSession(files: files, mode: mode, at: NSEvent.mouseLocation)
        session.onEnd = { [weak self, weak session] in
            if self?.session === session { self?.session = nil }
        }
        self.session = session
        Log.debug("wheel opened for \(files.count) files")
    }

    static func dragFiles() -> [URL]? {
        let board = NSPasteboard(name: .drag)
        return board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}

enum Log {
    /// Off by default. `defaults write com.fenil210.whorl debug -bool true` writes ~/Library/Logs/Whorl.log.
    static func debug(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "debug") || ProcessInfo.processInfo.environment["WHORL_DEBUG"] != nil else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Whorl.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
