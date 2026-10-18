import Foundation
import WhorlCore

/// `whorl` on the command line. Same engines as the app, no window.
enum CLI {
    static let usage = """
    Whorl \(AppInfo.version) — local file converter

    Usage:
      whorl convert <files…> --to <format>   convert, e.g. whorl convert photo.heic --to jpg
      whorl tool <name> <files…>             compress | rotate | metadata | split | merge
      whorl formats <file>                   what this file can become
      whorl action <name> <files…>           copyPath | terminal | copy | move | airdrop | float
      whorl doctor                           show which engines are available
      whorl version

    Run `whorl` with no arguments from Finder or the Applications folder to open the app.
    """

    static func main(_ args: [String]) -> Int32 {
        do {
            return try run(args)
        } catch {
            fputs("whorl: \(error)\n", stderr)
            return 1
        }
    }

    static func run(_ args: [String]) throws -> Int32 {
        guard let command = args.first else { throw ConvertError.failed(usage) }
        let rest = Array(args.dropFirst())
        switch command {
        case "convert":
            return try convert(rest)
        case "tool":
            return try tool(rest)
        case "formats":
            return try formats(rest)
        case "doctor":
            doctor()
            return 0
        case "action":
            return try action(rest)
        case "version", "--version", "-v":
            print(AppInfo.version)
            return 0
        case "help", "--help", "-h":
            print(usage)
            return 0
        default:
            throw ConvertError.failed(usage)
        }
    }
}

extension CLI {
    static func convert(_ args: [String]) throws -> Int32 {
        let parsed = try parse(args, flag: "--to")
        guard let name = parsed.value, let format = Format(rawValue: name.lowercased()) ?? Catalog.format(forExtension: name) else {
            throw ConvertError.failed("Name the output with --to, for example --to jpg")
        }
        return report(Jobs.run(.convert(format), inputs: parsed.files))
    }

    static func tool(_ args: [String]) throws -> Int32 {
        guard let name = args.first, let tool = Tool(rawValue: name) else {
            throw ConvertError.failed("Usage: whorl tool compress|rotate|metadata|split|merge <files>")
        }
        return report(Jobs.run(.tool(tool), inputs: try urls(Array(args.dropFirst()))))
    }

    static func formats(_ args: [String]) throws -> Int32 {
        let files = try urls(args)
        let exts = files.map(\.pathExtension)
        let engines = Engines.current
        let targets = Catalog.convertTargets(extensions: exts, engines: engines)
        if targets.isEmpty {
            print(Catalog.unavailableReason(extensions: exts, engines: engines) ?? "Nothing to convert to.")
        } else {
            print("convert: " + targets.map { $0.fileExtension }.joined(separator: " "))
        }
        let tools = Catalog.toolTargets(extensions: exts)
        if !tools.isEmpty { print("tools:   " + tools.map(\.rawValue).joined(separator: " ")) }
        return 0
    }

    static func doctor() {
        let engines = Engines.current
        print("Whorl \(AppInfo.version)")
        print("built in   images, PDF, documents, sheets, subtitles, archives, MP4/MOV/M4A/WAV/AIFF/FLAC/GIF")
        print("ffmpeg     \(engines.ffmpeg ? "found" : "missing — adds MKV, WebM, AVI, WMV, MP3, OGG, Opus, WMA  (brew install ffmpeg)")")
        print("LibreOffice \(engines.libreOffice ? "found" : "missing — adds PPT/PPTX/XLS and sharper DOCX→PDF  (brew install --cask libreoffice)")")
        print("cwebp      \(engines.cwebp ? "found" : "missing — only needed for WebP output on older macOS  (brew install webp)")")
        print("Accessibility (wheel anywhere): \(Permissions.accessibilityGranted ? "granted" : "not granted")")
    }

    static func report(_ result: JobResult) -> Int32 {
        result.outputs.forEach { print($0.path) }
        result.failures.forEach { fputs("whorl: \($0.file): \($0.message)\n", stderr) }
        return result.failures.isEmpty ? 0 : 1
    }
}

extension CLI {
    static func parse(_ args: [String], flag: String) throws -> (files: [URL], value: String?) {
        var files: [String] = []
        var value: String?
        var index = 0
        while index < args.count {
            if args[index] == flag {
                guard index + 1 < args.count else { throw ConvertError.failed("Missing value for \(flag)") }
                value = args[index + 1]
                index += 2
            } else {
                files.append(args[index])
                index += 1
            }
        }
        return (try urls(files), value)
    }

    static func urls(_ paths: [String]) throws -> [URL] {
        guard !paths.isEmpty else { throw ConvertError.failed("Give at least one file") }
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    static func action(_ args: [String]) throws -> Int32 {
        guard let name = args.first, let action = FileAction(rawValue: name) else {
            throw ConvertError.failed("Usage: whorl action copyPath|terminal|copy|move|airdrop|float <files>")
        }
        let outputs = try Actions.perform(action, files: try urls(Array(args.dropFirst())))
        outputs.forEach { print($0.path) }
        return 0
    }
}
