import AppKit
import SwiftUI
import WhorlCore

@MainActor
final class ConvertModel: ObservableObject {
    enum Tab { case convert, tools }

    @Published var files: [URL] = []
    @Published var tab: Tab = .convert
    @Published var engines = Engines.current
    @Published var running: JobRequest?
    @Published var fraction = 0.0
    @Published var detail = ""
    @Published var result: JobResult?
    private var handle: JobHandle?

    var extensions: [String] { files.map(\.pathExtension) }
    var targets: [Format] { Catalog.convertTargets(extensions: extensions, engines: engines) }
    var tools: [Tool] { Catalog.toolTargets(extensions: extensions) }
    var reason: String? { targets.isEmpty ? Catalog.unavailableReason(extensions: extensions, engines: engines) : nil }

    func add(_ urls: [URL]) {
        engines = .current
        var added = files
        for url in urls {
            for file in Self.expand(url) where !added.contains(file) { added.append(file) }
        }
        result = nil
        files = added
        tab = targets.isEmpty && !tools.isEmpty ? .tools : .convert
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        result = nil
        if files.isEmpty { clear() }
    }

    func clear() {
        files = []
        result = nil
        running = nil
        fraction = 0
    }

    func run(_ request: JobRequest) {
        guard running == nil, !files.isEmpty else { return }
        running = request
        fraction = 0
        detail = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        result = nil
        handle = JobRunner.start(request, inputs: files, progress: { [weak self] update in
            guard let self else { return }
            fraction = update.fraction
            if !update.name.isEmpty { detail = update.total > 1 ? "\(update.name) · \(update.done + 1) of \(update.total)" : update.name }
        }, completion: { [weak self] outcome in
            guard let self else { return }
            running = nil
            result = outcome
            handle = nil
        })
    }

    func cancel() { handle?.cancel() }

    /// A dropped folder contributes the files inside it, one level of ordering at a time.
    static func expand(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue || url.pathExtension.lowercased() == "rtfd" { return [url.standardizedFileURL] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [URL] = []
        while let item = walker?.nextObject() as? URL, found.count < 500 {
            if (try? item.resourceValues(forKeys: Set(keys)).isRegularFile) == true { found.append(item.standardizedFileURL) }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
