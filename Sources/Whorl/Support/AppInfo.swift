import AppKit
import ApplicationServices
import WhorlCore

enum AppInfo {
    static let version = "0.2.0"
    static let repository = URL(string: "https://github.com/fenil210-cactus/whorl")!
    static let accent = NSColor(calibratedRed: 0.36, green: 0.42, blue: 1.0, alpha: 1)
}

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The three modifier keys that open the wheel while a file is being dragged.
enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }

    var title: String { rawValue.capitalized }
}

enum Prefs {
    private static let defaults = UserDefaults.standard
    static let changed = Notification.Name("WhorlPrefsChanged")

    static func key(for mode: WheelMode) -> ModifierKey {
        if let raw = defaults.string(forKey: "key.\(mode.rawValue)"), let key = ModifierKey(rawValue: raw) { return key }
        switch mode {
        case .convert: return .shift
        case .tools: return .command
        case .actions: return .control
        }
    }

    /// Assigning a key another mode already uses swaps the two, so the three stay distinct.
    static func setKey(_ key: ModifierKey, for mode: WheelMode) {
        let old = self.key(for: mode)
        for other in WheelMode.allCases where other != mode && self.key(for: other) == key {
            defaults.set(old.rawValue, forKey: "key.\(other.rawValue)")
        }
        defaults.set(key.rawValue, forKey: "key.\(mode.rawValue)")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func mode(for flag: NSEvent.ModifierFlags) -> WheelMode? {
        WheelMode.allCases.first { flag.contains(key(for: $0).flag) }
    }

    static var wheelEnabled: Bool {
        get { defaults.object(forKey: "wheelEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wheelEnabled"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    static var seenWelcome: Bool {
        get { defaults.bool(forKey: "seenWelcome") }
        set { defaults.set(newValue, forKey: "seenWelcome") }
    }
}
