import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional helpers on the machine. The built-in engines (ImageIO, PDFKit, AVFoundation,
/// afconvert, AppKit text) always work; these light up extra routes.
public struct Engines: Equatable, Sendable {
    public var ffmpeg: Bool
    public var libreOffice: Bool
    public var cwebp: Bool

    public init(ffmpeg: Bool = false, libreOffice: Bool = false, cwebp: Bool = false) {
        self.ffmpeg = ffmpeg
        self.libreOffice = libreOffice
        self.cwebp = cwebp
    }

    public static let none = Engines()
    public static let everything = Engines(ffmpeg: true, libreOffice: true, cwebp: true)

    public static var current: Engines {
        Engines(
            ffmpeg: Binaries.find("ffmpeg") != nil,
            libreOffice: Binaries.soffice != nil,
            cwebp: Binaries.find("cwebp") != nil
        )
    }
}

enum Binaries {
    static let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func find(_ name: String) -> String? {
        directories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var soffice: String? {
        let app = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        if FileManager.default.isExecutableFile(atPath: app) { return app }
        return find("soffice")
    }
}

enum ImageCodecs {
    static let encodable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static let decodable: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    static func canEncode(_ format: Format, engines: Engines) -> Bool {
        switch format {
        case .pdf: return true
        case .webp: return engines.cwebp || encodable.contains("org.webmproject.webp")
        default: return encodable.contains(ImageConvert.utType(format).identifier)
        }
    }
}
