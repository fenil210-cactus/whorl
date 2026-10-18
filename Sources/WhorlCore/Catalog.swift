import Foundation

public enum WheelMode: String, CaseIterable, Sendable {
    case convert
    case tools
    case actions

    public var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }
}

public enum Family: String, Sendable {
    case image, audio, video, pdf, document, slides, sheet, subtitle, archive, unknown
}

public enum Format: String, CaseIterable, Sendable {
    case jpeg, png, webp, heic, tiff, avif, bmp, gif, pdf
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case mp4, mov, mkv, webm, avi, wmv
    case docx, pptx, xlsx, epub, txt, md, html, rtf, odt
    case ods, csv, tsv
    case srt, vtt
    case zip, tar, gz

    public var label: String {
        switch self {
        case .jpeg: return "JPG"
        case .md: return "MD"
        case .gz: return "GZIP"
        default: return rawValue.uppercased()
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        default: return rawValue
        }
    }
}

public enum Tool: String, CaseIterable, Sendable {
    case compress, rotate, metadata, split, merge

    public var label: String { rawValue.uppercased() }

    public var summary: String {
        switch self {
        case .compress: return "Make the file smaller"
        case .rotate: return "Turn 90° clockwise"
        case .metadata: return "Strip location and camera info"
        case .split: return "One file per page"
        case .merge: return "Combine into one PDF"
        }
    }
}

public enum FileAction: String, CaseIterable, Sendable {
    case airdrop, float, copy, move, copyPath, terminal

    public var label: String {
        switch self {
        case .copyPath: return "COPY PATH"
        default: return rawValue.uppercased()
        }
    }

    public var summary: String {
        switch self {
        case .airdrop: return "Send with AirDrop"
        case .float: return "Keep a preview above other windows"
        case .copy: return "Copy to a folder you pick"
        case .move: return "Move to a folder you pick"
        case .copyPath: return "Copy the file path"
        case .terminal: return "Open Terminal in its folder"
        }
    }
}

public enum Wedge: Equatable, Sendable {
    case convert(Format)
    case tool(Tool)
    case action(FileAction)

    public var id: String {
        switch self {
        case .convert(let format): return "convert:\(format.rawValue)"
        case .tool(let tool): return "tool:\(tool.rawValue)"
        case .action(let action): return "action:\(action.rawValue)"
        }
    }

    public var label: String {
        switch self {
        case .convert(let format): return format.label
        case .tool(let tool): return tool.label
        case .action(let action): return action.label
        }
    }

    public var caption: String {
        switch self {
        case .convert(let format): return "Convert to \(format.label)"
        case .tool(let tool): return tool.summary
        case .action(let action): return action.summary
        }
    }
}

public enum Catalog {
    public static func family(of ext: String) -> Family {
        switch normalizedExtension(ext) {
        case "jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "gif", "svg":
            return .image
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "caf", "aac":
            return .audio
        case "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv":
            return .video
        case "pdf":
            return .pdf
        case "docx", "doc", "odt", "pages", "md", "txt", "rtf", "rtfd", "epub", "html":
            return .document
        case "ppt", "pptx":
            return .slides
        case "xlsx", "xls", "ods", "csv", "tsv":
            return .sheet
        case "srt", "vtt":
            return .subtitle
        case "zip", "tar", "gz", "rar", "7z", "bz2", "xz":
            return .archive
        default:
            return .unknown
        }
    }

    public static func normalizedExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg", "jpg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "aif", "aifc": return "aiff"
        case "markdown", "mdown": return "md"
        case "htm", "xhtml": return "html"
        case "tgz", "gzip": return "gz"
        default: return ext.lowercased()
        }
    }

    public static func format(forExtension ext: String) -> Format? {
        let normalized = normalizedExtension(ext)
        return Format.allCases.first { $0.fileExtension == normalized }
    }

    /// Every format one file type can become on this machine (including its own).
    public static func outputs(forExtension ext: String, engines: Engines) -> [Format] {
        Support.outputs(forExtension: ext, engines: engines)
    }

    /// Formats every one of these files can become. A file already in a format is skipped for that format.
    public static func convertTargets(extensions: [String], engines: Engines) -> [Format] {
        let exts = extensions.map { normalizedExtension($0) }
        guard let first = exts.first else { return [] }
        let candidates = Support.outputs(forExtension: first, engines: engines)
            + exts.dropFirst().flatMap { Support.outputs(forExtension: $0, engines: engines) }
        var seen = Set<Format>()
        let ordered = candidates.filter { seen.insert($0).inserted }
        return ordered.filter { format in
            exts.contains { $0 != format.fileExtension } && exts.allSatisfy { ext in
                ext == format.fileExtension || Support.outputs(forExtension: ext, engines: engines).contains(format)
            }
        }
    }

    public static func toolTargets(extensions: [String]) -> [Tool] {
        let exts = extensions.map { normalizedExtension($0) }
        guard let first = exts.first else { return [] }
        return Support.tools(forExtension: first).filter { tool in
            exts.allSatisfy { Support.tools(forExtension: $0).contains(tool) }
        }
    }

    public static func wedges(extensions: [String], mode: WheelMode, engines: Engines) -> [Wedge] {
        switch mode {
        case .actions:
            return FileAction.allCases.map { .action($0) }
        case .tools:
            return toolTargets(extensions: extensions).map { .tool($0) }
        case .convert:
            return convertTargets(extensions: extensions, engines: engines).map { .convert($0) }
        }
    }

    /// A plain-English reason nothing is offered, or nil when something is.
    public static func unavailableReason(extensions: [String], engines: Engines) -> String? {
        guard !convertTargets(extensions: extensions, engines: engines).isEmpty else {
            for ext in extensions.map({ normalizedExtension($0) }) {
                let all = Support.outputs(forExtension: ext, engines: .everything)
                if Support.outputs(forExtension: ext, engines: engines).isEmpty, !all.isEmpty {
                    return Support.engineHint(forExtension: ext)
                }
                if family(of: ext) == .unknown { return "Whorl can't convert .\(ext) files yet." }
                if ext == "pages" { return "Pages files can't be read without Pages. Export to Word from Pages first." }
            }
            return "These files have no format in common. Try one kind of file at a time."
        }
        return nil
    }
}
