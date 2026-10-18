import Foundation

public enum JobRequest: Sendable, Equatable {
    case convert(Format)
    case tool(Tool)

    public var title: String {
        switch self {
        case .convert(let format): return "Converting to \(format.label)"
        case .tool(let tool): return tool.label.capitalized
        }
    }
}

public struct JobProgress: Sendable {
    public var done: Int
    public var total: Int
    public var name: String
    /// 0...1 across the whole batch.
    public var fraction: Double
}

public struct JobFailure: Sendable {
    public var file: String
    public var message: String

    public init(file: String, message: String) {
        self.file = file
        self.message = message
    }
}

public struct JobResult: Sendable {
    public var outputs: [URL] = []
    public var failures: [JobFailure] = []
    public var cancelled = false

    public init(outputs: [URL] = [], failures: [JobFailure] = [], cancelled: Bool = false) {
        self.outputs = outputs
        self.failures = failures
        self.cancelled = cancelled
    }
}

public enum Jobs {
    /// Runs a request over every file. One bad file does not stop the others.
    public static func run(
        _ request: JobRequest,
        inputs: [URL],
        engines: Engines = .current,
        progress: (@Sendable (JobProgress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> JobResult {
        var result = JobResult()
        if case .tool(.merge) = request {
            progress?(JobProgress(done: 0, total: 1, name: inputs.first?.lastPathComponent ?? "", fraction: 0))
            do { result.outputs = [try PDFConvert.merge(inputs: inputs)] } catch {
                result.failures.append(JobFailure(file: inputs.first?.lastPathComponent ?? "", message: String(describing: error)))
            }
            progress?(JobProgress(done: 1, total: 1, name: "", fraction: 1))
            return result
        }
        let total = inputs.count
        for (index, input) in inputs.enumerated() {
            if isCancelled() { result.cancelled = true; break }
            progress?(JobProgress(done: index, total: total, name: input.lastPathComponent, fraction: Double(index) / Double(total)))
            do {
                let step: Progress = { fraction in
                    progress?(JobProgress(done: index, total: total, name: input.lastPathComponent, fraction: (Double(index) + fraction) / Double(total)))
                }
                switch request {
                case .convert(let format): result.outputs += try convertOne(input, to: format, engines: engines, progress: step)
                case .tool(let tool): result.outputs += try toolOne(input, tool: tool, engines: engines, progress: step)
                }
            } catch {
                result.failures.append(JobFailure(file: input.lastPathComponent, message: String(describing: error)))
            }
        }
        progress?(JobProgress(done: total, total: total, name: "", fraction: 1))
        return result
    }

    /// Convenience for scripts and tests: throws the first failure.
    public static func convert(inputs: [URL], to format: Format, engines: Engines = .current) throws -> [URL] {
        let result = run(.convert(format), inputs: inputs, engines: engines)
        if let failure = result.failures.first { throw ConvertError.failed(failure.message) }
        return result.outputs
    }

    public static func tool(_ tool: Tool, inputs: [URL], engines: Engines = .current) throws -> [URL] {
        let result = run(.tool(tool), inputs: inputs, engines: engines)
        if let failure = result.failures.first { throw ConvertError.failed(failure.message) }
        return result.outputs
    }

    typealias Progress = @Sendable (Double) -> Void

    private static func convertOne(_ input: URL, to format: Format, engines: Engines, progress: @escaping Progress) throws -> [URL] {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        if ext == format.fileExtension { return [] }
        guard Support.outputs(forExtension: ext, engines: engines).contains(format) else {
            if Support.outputs(forExtension: ext, engines: .everything).contains(format) {
                throw ConvertError.unsupported(Support.engineHint(forExtension: ext))
            }
            throw ConvertError.unsupported("Whorl cannot turn .\(ext) into \(format.label)")
        }
        switch Catalog.family(of: ext) {
        case .image:
            return [try ImageConvert.convert(input: input, to: format, engines: engines)]
        case .pdf where format == .jpeg || format == .png:
            return try PDFConvert.render(pdf: input, naming: input, format: format)
        case .pdf, .document:
            return [try DocConvert.convert(input: input, to: format, engines: engines)]
        case .sheet:
            return [try SheetConvert.convert(input: input, to: format, engines: engines)]
        case .subtitle:
            return [try SubtitleConvert.convert(input: input, to: format)]
        case .archive:
            return [try ArchiveConvert.convert(input: input, to: format)]
        case .audio, .video:
            return [try MediaConvert.convert(input: input, to: format, engines: engines, progress: progress)]
        case .slides:
            if format == .pdf { return [try Office.convert(input: input, to: .pdf, engines: engines)] }
            return try Office.render(input: input, to: format, engines: engines)
        case .unknown:
            throw ConvertError.unsupported("Whorl cannot convert .\(ext) files yet")
        }
    }

    private static func toolOne(_ input: URL, tool: Tool, engines: Engines, progress: @escaping Progress) throws -> [URL] {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        guard Support.tools(forExtension: ext).contains(tool) else {
            throw ConvertError.unsupported("\(tool.label.capitalized) does not work on .\(ext) files")
        }
        let family = Catalog.family(of: ext)
        switch (tool, family) {
        case (.compress, .pdf): return [try PDFConvert.compress(input)]
        case (.compress, .image): return [try ImageConvert.compress(input: input, engines: engines)]
        case (.compress, _): return [try MediaConvert.compress(input: input, progress: progress)]
        case (.rotate, .pdf): return [try PDFConvert.rotate(input)]
        case (.rotate, _): return [try ImageConvert.rotate(input: input, engines: engines)]
        case (.metadata, .pdf): return [try PDFConvert.stripMetadata(input)]
        case (.metadata, _): return [try ImageConvert.stripMetadata(input: input, engines: engines)]
        case (.split, _): return try PDFConvert.split(input: input)
        default: throw ConvertError.unsupported("\(tool.label.capitalized) does not work on .\(ext) files")
        }
    }
}
