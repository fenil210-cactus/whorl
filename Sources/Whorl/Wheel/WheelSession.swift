import AppKit
import WhorlCore

/// One wheel, from the moment a modifier key is tapped mid-drag until the file is dropped.
///
/// A transparent panel covers every screen and is a real drop target, so the drop never reaches
/// Finder or whatever sits under the pointer. That is what keeps the original file where it is.
@MainActor
final class WheelSession {
    private(set) var files: [URL]
    private(set) var mode: WheelMode
    private(set) var wedges: [Wedge] = []
    private(set) var highlighted: Int?
    private(set) var center: CGPoint
    private var panels: [(panel: NSPanel, canvas: WheelCanvas)] = []
    private var finished = false
    var onEnd: (() -> Void)?

    init(files: [URL], mode: WheelMode, at point: CGPoint) {
        self.files = files
        self.mode = mode
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let area = (screen?.frame ?? .zero).insetBy(dx: Wheel.outerRadius + 24, dy: Wheel.outerRadius + 56)
        center = CGPoint(x: min(max(point.x, area.minX), max(area.minX, area.maxX)), y: min(max(point.y, area.minY), max(area.minY, area.maxY)))
        refreshWedges()
        for screen in NSScreen.screens { addPanel(for: screen) }
        for item in panels {
            item.panel.alphaValue = 0
            item.panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            for item in panels { item.panel.animator().alphaValue = 1 }
        }
        for item in panels { item.canvas.stage?.animateIn() }
        hover(at: point)
    }

    /// While a drag is starting, macOS shows the dragged files only to the window the drag enters,
    /// so the wheel can open before it knows what is being dragged and fills in on first contact.
    func adopt(from info: NSDraggingInfo) {
        guard files.isEmpty, !finished else { return }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        Log.debug("adopted \(urls.count) files from the drop panel")
        files = urls
        refreshWedges()
        redraw()
    }

    var captionText: String {
        if files.isEmpty { return "Move onto the ring" }
        if let index = highlighted, wedges.indices.contains(index) { return wedges[index].caption }
        return wedges.isEmpty ? "Nothing in \(mode.title) for these files" : "Drop on a \(mode == .convert ? "format" : mode == .tools ? "tool" : "action")"
    }

    var summary: (symbol: String, text: String) {
        if files.isEmpty { return ("doc", "…") }
        if files.count == 1 { return ("doc", files[0].pathExtension.isEmpty ? "FILE" : files[0].pathExtension.uppercased()) }
        return ("square.stack", "\(files.count) files")
    }

    func setMode(_ new: WheelMode) {
        guard new != mode, !finished else { return }
        mode = new
        highlighted = nil
        refreshWedges()
        redraw()
    }

    func hover(at point: CGPoint?) {
        let index = point.flatMap { Wheel.index(center: center, point: $0, count: wedges.count) }
        guard index != highlighted else { return }
        highlighted = index
        redraw()
    }

    /// Returns true when the drop landed on a wedge.
    @discardableResult
    func drop(at point: CGPoint) -> Bool {
        guard !finished else { return false }
        let index = Wheel.index(center: center, point: point, count: wedges.count)
        finish()
        guard let index, wedges.indices.contains(index) else { return false }
        Self.perform(wedges[index], files: files)
        return true
    }

    func cancel() {
        guard !finished else { return }
        finish()
    }

    private func finish() {
        finished = true
        let closing = panels
        panels = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            for item in closing { item.panel.animator().alphaValue = 0 }
        }, completionHandler: {
            for item in closing { item.panel.orderOut(nil) }
        })
        onEnd?()
    }

    private func refreshWedges() {
        wedges = Catalog.wedges(extensions: files.map(\.pathExtension), mode: mode, engines: .current)
    }

    private func redraw() {
        for item in panels { item.canvas.stage?.redraw() }
    }

    private func addPanel(for screen: NSScreen) {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        // Nearly clear but not fully: fully transparent windows let drops fall through.
        panel.backgroundColor = NSColor(white: 0, alpha: 0.22)
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let canvas = WheelCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.place(center: center, on: screen, session: self)
        canvas.autoresizingMask = [.width, .height]
        panel.contentView = canvas
        panel.setFrame(screen.frame, display: false)
        panels.append((panel, canvas))
    }

    // MARK: Running a wedge

    static func perform(_ wedge: Wedge, files: [URL]) {
        switch wedge {
        case .convert(let format):
            HUD.shared.run(.convert(format), inputs: files)
        case .tool(let tool):
            HUD.shared.run(.tool(tool), inputs: files)
        case .action(let action):
            do {
                let moved = try Actions.perform(action, files: files)
                switch action {
                case .copyPath: HUD.shared.notice(files.count == 1 ? "Path copied" : "\(files.count) paths copied", symbol: "link")
                case .copy where !moved.isEmpty: HUD.shared.notice("Copied \(moved.count == 1 ? moved[0].lastPathComponent : "\(moved.count) items")", symbol: "doc.on.doc")
                case .move where !moved.isEmpty: HUD.shared.notice("Moved \(moved.count == 1 ? moved[0].lastPathComponent : "\(moved.count) items")", symbol: "folder")
                default: break
                }
            } catch {
                HUD.shared.fail(String(describing: error))
            }
        }
    }
}

/// The full-screen drop target. It owns the glass ring ("stage") that sits under the pointer.
final class WheelCanvas: NSView {
    weak var session: WheelSession?
    private(set) var stage: WheelStage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    /// `center` is in screen coordinates; `screen` is the screen this canvas covers.
    func place(center: CGPoint, on screen: NSScreen, session: WheelSession) {
        self.session = session
        let reach = WheelStage.reach
        let local = CGPoint(x: center.x - screen.frame.minX, y: center.y - screen.frame.minY)
        guard bounds.insetBy(dx: -reach, dy: -reach).contains(local) else { return }
        let stage = WheelStage(session: session, frame: NSRect(x: local.x - reach, y: local.y - reach, width: reach * 2, height: reach * 2))
        addSubview(stage)
        self.stage = stage
    }

    private func screenPoint(_ sender: NSDraggingInfo) -> CGPoint? {
        window?.convertPoint(toScreen: sender.draggingLocation)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Log.debug("panel draggingEntered")
        MainActor.assumeIsolated {
            session?.adopt(from: sender)
            session?.hover(at: screenPoint(sender))
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            session?.adopt(from: sender)
            session?.hover(at: screenPoint(sender))
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { session?.hover(at: nil) }
    }

    /// Dropping off the ring is a cancel: refusing the drop makes Finder slide the file back.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Log.debug("panel prepareForDragOperation")
        guard let point = screenPoint(sender) else { return false }
        return MainActor.assumeIsolated {
            guard let session else { return false }
            return Wheel.index(center: session.center, point: point, count: session.wedges.count) != nil
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Log.debug("panel performDragOperation")
        guard let point = screenPoint(sender) else { return false }
        return MainActor.assumeIsolated { session?.drop(at: point) ?? false }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        MainActor.assumeIsolated { session?.cancel() }
    }
}

/// Blurred glass ring plus the artwork on top of it. Opens with a small spring.
final class WheelStage: NSView {
    static let reach = Wheel.outerRadius + 84

    private let art: WheelArtView
    private let glass = NSVisualEffectView()

    init(session: WheelSession, frame: NSRect) {
        art = WheelArtView(session: session)
        super.init(frame: frame)
        wantsLayer = true
        let outer = Wheel.outerRadius
        let ringSize = (outer + 2) * 2
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .vibrantDark)
        glass.frame = NSRect(x: bounds.midX - ringSize / 2, y: bounds.midY - ringSize / 2, width: ringSize, height: ringSize)
        glass.maskImage = Self.ringMask(size: ringSize, inner: Wheel.innerRadius - 4)
        addSubview(glass)
        art.frame = bounds
        art.autoresizingMask = [.width, .height]
        addSubview(art)
    }

    required init?(coder: NSCoder) { nil }

    func redraw() { art.needsDisplay = true }

    func animateIn() {
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.82
        spring.toValue = 1
        spring.damping = 15
        spring.stiffness = 260
        spring.mass = 0.8
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }

    private static func ringMask(size: CGFloat, inner: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let hole = NSBezierPath(ovalIn: NSRect(x: rect.midX - inner, y: rect.midY - inner, width: inner * 2, height: inner * 2))
            NSGraphicsContext.current?.compositingOperation = .clear
            hole.fill()
            return true
        }
    }
}

final class WheelArtView: NSView {
    weak var session: WheelSession?

    init(session: WheelSession) {
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        WheelArt.draw(
            wedges: session.wedges, highlighted: session.highlighted, mode: session.mode,
            caption: session.captionText, summary: session.summary,
            center: CGPoint(x: bounds.midX, y: bounds.midY), glass: true
        )
    }
}
