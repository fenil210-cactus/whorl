import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

// Command-line use: `whorl convert …`. Anything else (including Finder's launch) opens the app.
if let first = arguments.first, CLI.commands.contains(first) {
    exit(CLI.main(arguments))
}

// Developer helpers used by the build and test scripts.
if arguments.first == "--make-icon", arguments.count == 3, let size = Int(arguments[1]) {
    do { try StatusIcon.writePNG(size: size, to: URL(fileURLWithPath: arguments[2])) } catch { fputs("\(error)\n", stderr); exit(1) }
    exit(0)
}
if arguments.first == "--snapshot", arguments.count >= 2 {
    MainActor.assumeIsolated { Snapshot.run(into: URL(fileURLWithPath: arguments[1]), files: arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
