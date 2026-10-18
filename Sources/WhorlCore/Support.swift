import Foundation

/// The single source of truth for what Whorl can really do.
/// The wheel, the window, the CLI, and the job runner all ask this, so nothing is offered that fails.
enum Support {
    static let nativeAudioIn: Set<String> = ["mp3", "m4a", "wav", "flac", "aiff", "caf", "aac"]
    static let nativeVideoIn: Set<String> = ["mp4", "mov", "m4v"]
    static let nativeDocIn: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd", "txt", "md", "html", "epub"]

    static func outputs(forExtension ext: String, engines: Engines) -> [Format] {
        let e = Catalog.normalizedExtension(ext)
        switch Catalog.family(of: e) {
        case .image:
            let all: [Format] = [.jpeg, .png, .webp, .heic, .tiff, .avif, .bmp, .gif, .pdf]
            return all.filter { ImageCodecs.canEncode($0, engines: engines) }
        case .audio:
            guard nativeAudioIn.contains(e) || engines.ffmpeg else { return [] }
            var out: [Format] = [.m4a, .wav, .aiff, .flac]
            if engines.ffmpeg { out = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma] }
            return out
        case .video:
            if nativeVideoIn.contains(e) {
                var out: [Format] = [.mp4, .mov, .m4a, .gif]
                if engines.ffmpeg { out = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3, .m4a] }
                return out
            }
            guard engines.ffmpeg else { return [] }
            return [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3, .m4a]
        case .pdf:
            return [.jpeg, .png, .docx, .txt, .md, .html, .epub, .rtf]
        case .document:
            guard nativeDocIn.contains(e) else { return [] }
            return [.pdf, .docx, .txt, .md, .html, .epub, .rtf, .odt]
        case .slides:
            return engines.libreOffice ? [.pdf, .jpeg, .png] : []
        case .sheet:
            if e == "xls" { return engines.libreOffice ? [.xlsx, .ods, .csv, .tsv] : [] }
            return [.xlsx, .ods, .csv, .tsv]
        case .subtitle:
            return [.srt, .vtt]
        case .archive:
            return [.zip, .tar, .gz]
        case .unknown:
            return []
        }
    }

    static func tools(forExtension ext: String) -> [Tool] {
        let e = Catalog.normalizedExtension(ext)
        switch Catalog.family(of: e) {
        case .image:
            return e == "svg" ? [] : [.compress, .rotate, .metadata, .merge]
        case .pdf:
            return [.compress, .split, .merge, .rotate, .metadata]
        case .audio:
            return nativeAudioIn.contains(e) ? [.compress] : []
        case .video:
            return nativeVideoIn.contains(e) ? [.compress] : []
        default:
            return []
        }
    }

    static func engineHint(forExtension ext: String) -> String {
        let e = Catalog.normalizedExtension(ext)
        switch Catalog.family(of: e) {
        case .slides, .sheet:
            return "Install LibreOffice to open .\(e) files:  brew install --cask libreoffice"
        case .audio, .video:
            return "Install ffmpeg to open .\(e) files:  brew install ffmpeg"
        default:
            return "Whorl can't convert .\(e) files yet."
        }
    }
}
