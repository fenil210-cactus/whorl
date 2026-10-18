import AppKit
import QuickLookUI
import WhorlCore

/// The Control wheel: things you do with a file that are not conversions. Run on the main thread.
enum Actions {
    static func perform(_ action: FileAction, files: [URL]) throws -> [URL] {
        switch action {
        case .copyPath:
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            return []
        case .terminal:
            try openTerminal(files)
            return []
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
                throw ConvertError.failed("AirDrop is not available. Turn on Wi-Fi and Bluetooth.")
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: files)
            return []
        case .float:
            FloatPanel.show(files)
            return []
        case .copy:
            return try transfer(files, moving: false)
        case .move:
            return try transfer(files, moving: true)
        }
    }

    private static func openTerminal(_ files: [URL]) throws {
        guard let first = files.first else { return }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
        let folder = exists && isDirectory.boolValue ? first : first.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw ConvertError.failed("Terminal.app was not found")
        }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func transfer(_ files: [URL], moving: Bool) throws -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = moving ? "Move Here" : "Copy Here"
        panel.message = moving ? "Choose where to move \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) items")" : "Choose where to copy \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) items")"
        guard panel.runModal() == .OK, let folder = panel.url else { return [] }
        return try files.map { file in
            let destination = OutputNames.url(
                beside: folder.appendingPathComponent(file.lastPathComponent),
                fileExtension: file.pathExtension,
                tag: "copy",
                existing: { FileManager.default.fileExists(atPath: $0) }
            )
            let target = file.pathExtension.isEmpty ? folder.appendingPathComponent(file.lastPathComponent) : destination
            if moving {
                try FileManager.default.moveItem(at: file, to: target)
            } else {
                try FileManager.default.copyItem(at: file, to: target)
            }
            return target
        }
    }
}

/// A Quick Look preview that stays above every other window.
final class FloatPanel: NSPanel {
    private static var open: [FloatPanel] = []

    static func show(_ files: [URL]) {
        for (index, file) in files.prefix(6).enumerated() {
            let panel = FloatPanel(
                contentRect: NSRect(x: 120 + index * 36, y: 160 + index * 36, width: 420, height: 340),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = file.lastPathComponent
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 420, height: 340), style: .normal) {
                preview.previewItem = file as NSURL
                preview.autoresizingMask = [.width, .height]
                panel.contentView = preview
            }
            panel.orderFrontRegardless()
            open.append(panel)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
                open.removeAll { $0 === panel }
            }
        }
    }
}
