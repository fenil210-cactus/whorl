import AppKit
import SwiftUI
import WhorlCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let monitor = DragMonitor()
    private let model = ConvertModel()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var wasTrusted = Permissions.accessibilityGranted
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        monitor.start()
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.start() }
        }
        // Accessibility can be granted while Whorl is running; restart the monitor when that happens.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Permissions.accessibilityGranted
                if now != self.wasTrusted { self.wasTrusted = now; self.monitor.start() }
            }
        }
        if !Prefs.seenWelcome {
            Prefs.seenWelcome = true
            showWindow()
        }
    }

    // MARK: Opening files (Finder → Open With, drop on the app icon, Services menu)

    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
        showWindow()
    }

    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        model.add(urls)
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = StatusIcon.make(size: 18, template: true)
        status.button?.toolTip = "Whorl"
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Open Whorl", #selector(openWindow), "o"))
        menu.addItem(item("Choose Files…", #selector(chooseFiles), ""))
        menu.addItem(.separator())
        let keys = WheelMode.allCases.map { "\(Prefs.key(for: $0).symbol) \($0.title)" }.joined(separator: "   ")
        if !Prefs.wheelEnabled {
            menu.addItem(disabled("Wheel is off"))
        } else if Permissions.accessibilityGranted {
            menu.addItem(disabled("Drag a file, then tap:"))
            menu.addItem(disabled("   \(keys)"))
        } else {
            menu.addItem(item("Turn on the wheel…", #selector(enableWheel), ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(item("Whorl on GitHub", #selector(openGitHub), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Whorl", #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openWindow() { showWindow() }
    @objc private func openSettings() { showSettings() }
    @objc private func openGitHub() { NSWorkspace.shared.open(AppInfo.repository) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func enableWheel() {
        Permissions.requestAccessibility()
        showWindow()
    }

    @objc private func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            model.add(panel.urls)
            showWindow()
        }
    }

    // MARK: Windows

    func showWindow() {
        if window == nil {
            let view = HomeView(model: model, openSettings: { [weak self] in self?.showSettings() }, chooseFiles: { [weak self] in self?.chooseFiles() })
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            win.title = "Whorl"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = true
            win.contentView = NSHostingView(rootView: view)
            win.isReleasedWhenClosed = false
            win.setFrameAutosaveName("WhorlMain")
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Whorl Settings"
            win.contentView = NSHostingView(rootView: SettingsView())
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
