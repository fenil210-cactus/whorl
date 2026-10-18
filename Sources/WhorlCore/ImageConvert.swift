import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageConvert {
    static func convert(input: URL, to format: Format, engines: Engines) throws -> URL {
        if format == .pdf { return try imageToPDF(input) }
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension)
        try save(try load(input), to: output, format: format, quality: 0.92, engines: engines)
        return output
    }

    static func compress(input: URL, engines: Engines) throws -> URL {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        let image = downscale(try load(input), longEdge: 2560)
        let lossy: [String: Format] = ["jpg": .jpeg, "heic": .heic, "avif": .avif, "webp": .webp]
        let format: Format
        if let same = lossy[ext], ImageCodecs.canEncode(same, engines: engines) {
            format = same
        } else if hasAlpha(image) {
            format = .png
        } else {
            format = .jpeg
        }
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension, tag: "compressed")
        try save(image, to: output, format: format, quality: 0.6, engines: engines)
        try ensureSmaller(output, than: input)
        return output
    }

    static func stripMetadata(input: URL, engines: Engines) throws -> URL {
        let format = sameFormat(input, engines: engines)
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension, tag: "clean")
        try save(try load(input), to: output, format: format, quality: 0.95, engines: engines)
        return output
    }

    static func rotate(input: URL, engines: Engines) throws -> URL {
        let image = try load(input)
        let format = sameFormat(input, engines: engines)
        guard let context = CGContext(
            data: nil, width: image.height, height: image.width,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConvertError.failed("Could not rotate \(input.lastPathComponent)") }
        context.translateBy(x: 0, y: CGFloat(image.width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = context.makeImage() else { throw ConvertError.failed("Could not rotate \(input.lastPathComponent)") }
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension, tag: "rotated")
        try save(rotated, to: output, format: format, quality: 0.95, engines: engines)
        return output
    }

    private static func sameFormat(_ input: URL, engines: Engines) -> Format {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        if let format = Catalog.format(forExtension: ext), ImageCodecs.canEncode(format, engines: engines), format != .pdf { return format }
        return .png
    }

    static func ensureSmaller(_ output: URL, than input: URL) throws {
        let before = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if before > 0, after >= before {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError.failed("\(input.lastPathComponent) is already as small as Whorl can make it")
        }
    }
}

// MARK: - Reading and writing

extension ImageConvert {
    /// Decodes with the camera orientation applied, so phone photos come out upright.
    static func load(_ url: URL) throws -> CGImage {
        if Catalog.normalizedExtension(url.pathExtension) == "svg" { return try loadSVG(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if max(width, height) > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConvertError.unreadable(url.lastPathComponent) }
        return image
    }

    private static func loadSVG(_ url: URL) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        let scale = max(1, 2048 / max(image.size.width, image.size.height))
        let width = Int((image.size.width * scale).rounded())
        let height = Int((image.size.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConvertError.failed("Could not draw \(url.lastPathComponent)") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw ConvertError.failed("Could not draw \(url.lastPathComponent)") }
        return result
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func downscale(_ image: CGImage, longEdge: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longEdge else { return image }
        let scale = Double(longEdge) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// JPEG and BMP cannot hold transparency, so put the picture on white first.
    static func flatten(_ image: CGImage) -> CGImage {
        guard hasAlpha(image),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    static func save(_ image: CGImage, to output: URL, format: Format, quality: CGFloat, engines: Engines) throws {
        let needsFlat = format == .jpeg || format == .bmp
        let picture = needsFlat ? flatten(image) : image
        if format == .webp, !ImageCodecs.encodable.contains("org.webmproject.webp") {
            try cwebp(picture, to: output, quality: quality)
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, utType(format).identifier as CFString, 1, nil) else {
            throw ConvertError.failed("This Mac cannot write \(format.label)")
        }
        let props = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, picture, props)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError.failed("Could not save \(output.lastPathComponent)")
        }
    }

    private static func cwebp(_ image: CGImage, to output: URL, quality: CGFloat) throws {
        guard let binary = Binaries.find("cwebp") else { throw ConvertError.unsupported("Install webp to write WebP:  brew install webp") }
        let temp = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let png = temp.appendingPathComponent("in.png")
        try save(image, to: png, format: .png, quality: 1, engines: .none)
        try Shell.run(binary, ["-quiet", "-q", String(Int(quality * 100)), png.path, "-o", output.path])
    }

    static func utType(_ format: Format) -> UTType {
        switch format {
        case .jpeg: return .jpeg
        case .png: return .png
        case .gif: return .gif
        case .tiff: return .tiff
        case .heic: return UTType("public.heic") ?? .jpeg
        case .webp: return UTType("org.webmproject.webp") ?? .png
        case .avif: return UTType("public.avif") ?? .jpeg
        case .bmp: return UTType("com.microsoft.bmp") ?? .png
        default: return .png
        }
    }
}

// MARK: - PDF

extension ImageConvert {
    static func pdfPage(_ image: CGImage) -> PDFPage? {
        // 150 dpi: a 3000 px photo becomes a 1440 pt page.
        let size = NSSize(width: CGFloat(image.width) * 0.48, height: CGFloat(image.height) * 0.48)
        return PDFPage(image: NSImage(cgImage: image, size: size))
    }

    static func imageToPDF(_ input: URL) throws -> URL {
        let document = PDFDocument()
        guard let page = pdfPage(try load(input)) else { throw ConvertError.failed("Could not place \(input.lastPathComponent) in a PDF") }
        document.insert(page, at: 0)
        let output = OutputNames.url(beside: input, fileExtension: "pdf")
        guard PDFConvert.write(document, to: output, jpeg: true) else {
            throw ConvertError.failed("Could not write the PDF")
        }
        return output
    }
}
