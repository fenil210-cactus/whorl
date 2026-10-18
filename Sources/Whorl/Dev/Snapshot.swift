import AppKit
import SwiftUI
import WhorlCore

extension CLI {
    static let commands: Set<String> = ["convert", "tool", "formats", "doctor", "action", "version", "--version", "-v", "help", "--help", "-h"]
}

/// `Whorl --snapshot <dir> [files…]` draws the main screens to PNGs so a change can be checked without clicking through the app.
@MainActor
enum Snapshot {
    static func run(into directory: URL, files: [URL]) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let empty = ConvertModel()
        render(HomeView(model: empty), size: NSSize(width: 640, height: 780), to: directory.appendingPathComponent("home-empty.png"))

        if !files.isEmpty {
            let loaded = ConvertModel()
            loaded.add(files)
            render(HomeView(model: loaded), size: NSSize(width: 640, height: 640), to: directory.appendingPathComponent("home-files.png"))
            loaded.tab = .tools
            render(HomeView(model: loaded), size: NSSize(width: 640, height: 640), to: directory.appendingPathComponent("home-tools.png"))

            let done = ConvertModel()
            done.add(files)
            done.result = JobResult(outputs: files.map { $0.deletingPathExtension().appendingPathExtension("jpg") }, failures: [JobFailure(file: "notes.xyz", message: "Whorl cannot convert .xyz files yet")])
            render(HomeView(model: done), size: NSSize(width: 640, height: 640), to: directory.appendingPathComponent("home-result.png"))
        }

        render(SettingsView(), size: NSSize(width: 520, height: 600), to: directory.appendingPathComponent("settings.png"))

        let engines = Engines.current
        for (name, extensions, mode, hot) in [
            ("wheel-convert", ["png"], WheelMode.convert, 2),
            ("wheel-tools", ["pdf"], WheelMode.tools, 1),
            ("wheel-actions", ["png"], WheelMode.actions, 4),
        ] {
            let wedges = Catalog.wedges(extensions: extensions, mode: mode, engines: engines)
            let view = WheelPreview(wedges: wedges, highlighted: min(hot, wedges.count - 1), mode: mode)
            renderView(view, size: view.frame.size, to: directory.appendingPathComponent("\(name).png"))
        }
        try? StatusIcon.writePNG(size: 256, to: directory.appendingPathComponent("icon.png"))
        print("snapshots in \(directory.path)")
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        renderView(host, size: size, to: url)
    }

    private static func renderView(_ view: NSView, size: NSSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

final class WheelPreview: NSView {
    let wedges: [Wedge]
    let highlighted: Int
    let mode: WheelMode

    init(wedges: [Wedge], highlighted: Int, mode: WheelMode) {
        self.wedges = wedges
        self.highlighted = highlighted
        self.mode = mode
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.93, alpha: 1).setFill()
        bounds.fill()
        WheelArt.draw(
            wedges: wedges, highlighted: highlighted, mode: mode,
            caption: wedges.indices.contains(highlighted) ? wedges[highlighted].caption : "",
            summary: ("doc", "PNG"), center: CGPoint(x: bounds.midX, y: bounds.midY)
        )
    }
}
