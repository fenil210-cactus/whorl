import AppKit
import ServiceManagement
import SwiftUI
import WhorlCore

struct SettingsView: View {
    @State private var wheelOn = Prefs.wheelEnabled
    @State private var keys: [WheelMode: ModifierKey] = Dictionary(uniqueKeysWithValues: WheelMode.allCases.map { ($0, Prefs.key(for: $0)) })
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var dock = Prefs.showInDock
    @State private var loginError: String?
    @State private var engines = Engines.current
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Wheel") {
                Toggle("Open the wheel when I drag a file", isOn: $wheelOn)
                    .onChange(of: wheelOn) { Prefs.wheelEnabled = $0 }
                ForEach(WheelMode.allCases, id: \.self) { mode in
                    Picker(label(for: mode), selection: Binding(
                        get: { keys[mode] ?? Prefs.key(for: mode) },
                        set: { Prefs.setKey($0, for: mode); refreshKeys() }
                    )) {
                        ForEach(ModifierKey.allCases) { Text("\($0.symbol)  \($0.title)").tag($0) }
                    }
                    .disabled(!wheelOn)
                }
                Text("No permission needed. Hold a file, tap the key, and the wheel opens.").font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open Whorl at login", isOn: $login)
                    .onChange(of: login) { setLogin($0) }
                Toggle("Show Whorl in the Dock", isOn: $dock)
                    .onChange(of: dock) { Prefs.showInDock = $0 }
                Text("Turn this on if you can't see Whorl in a crowded menu bar. Clicking the Dock icon opens the window.")
                    .font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section("Extra tools") {
                engineRow("ffmpeg", present: engines.ffmpeg, unlocks: "MKV, WebM, AVI, WMV, MP3, OGG, Opus, WMA", command: "brew install ffmpeg")
                engineRow("LibreOffice", present: engines.libreOffice, unlocks: "PPT, PPTX, XLS, and sharper Word to PDF", command: "brew install --cask libreoffice")
                engineRow("webp", present: engines.cwebp, unlocks: "WebP output on older macOS", command: "brew install webp")
                Text("Whorl works fully without these. They only switch on more formats.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Source code") {
                    Link("github.com/fenil210-cactus/whorl", destination: AppInfo.repository)
                }
                Text("Free and open source under the MIT license. Everything runs on this Mac, and no file is ever uploaded. Whorl is independent and not affiliated with Leap Studio or Tangerine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
        .onReceive(tick) { _ in
            engines = .current
        }
    }

    private func label(for mode: WheelMode) -> String {
        switch mode {
        case .convert: return "Convert (pick a format)"
        case .tools: return "Tools (compress, rotate, …)"
        case .actions: return "Actions (copy, move, AirDrop, …)"
        }
    }

    private func refreshKeys() {
        keys = Dictionary(uniqueKeysWithValues: WheelMode.allCases.map { ($0, Prefs.key(for: $0)) })
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS did not allow that: \(error.localizedDescription). Add Whorl in System Settings → General → Login Items instead."
            login = SMAppService.mainApp.status == .enabled
        }
    }

    private func engineRow(_ name: String, present: Bool, unlocks: String, command: String) -> some View {
        HStack {
            Image(systemName: present ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(present ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(present ? "Found. Unlocks \(unlocks)." : "Adds \(unlocks).").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !present {
                Button("Copy install command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .help(command)
            }
        }
    }
}
