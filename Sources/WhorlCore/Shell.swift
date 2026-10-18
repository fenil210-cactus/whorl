import Foundation

enum Shell {
    /// Runs a tool, waits, and returns what it printed. Output goes to files so a chatty tool can't fill a pipe and hang.
    @discardableResult
    static func run(_ launch: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("whorl-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConvertError.failed("Could not start \(URL(fileURLWithPath: launch).lastPathComponent)")
        }
        process.waitUntilExit()
        try? out.close()
        try? err.close()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let lines = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            throw ConvertError.failed(lines.isEmpty ? "\(URL(fileURLWithPath: launch).lastPathComponent) failed" : lines)
        }
        return stdout
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whorl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Zips the contents of `directory` into `output`. `first` entries are stored uncompressed and written first (EPUB and ODF need this).
    static func zip(directory: URL, to output: URL, first: [String] = []) throws {
        try? FileManager.default.removeItem(at: output)
        for name in first { try run("/usr/bin/zip", ["-X0", output.path, name], cwd: directory) }
        try run("/usr/bin/zip", ["-Xr9D", output.path, "."] + first.flatMap { ["-x", $0] }, cwd: directory)
    }
}
