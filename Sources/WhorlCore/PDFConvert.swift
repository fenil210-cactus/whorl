import CoreGraphics
import Foundation
import PDFKit
import Quartz

enum PDFConvert {
    static let dpi = 300.0

    static func open(_ input: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: input) else { throw ConvertError.unreadable(input.lastPathComponent) }
        if document.isLocked { throw ConvertError.failed("\(input.lastPathComponent) is password protected") }
        guard document.pageCount > 0 else { throw ConvertError.unreadable(input.lastPathComponent) }
        return document
    }

    /// Writes each page as an image, named after `naming` (the PDF's own name, or the slide deck it came from).
    static func render(pdf: URL, naming: URL, format: Format) throws -> [URL] {
        let document = try open(pdf)
        var urls: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let suffix = document.pageCount == 1 ? "" : "-\(index + 1)"
            let stem = URL(fileURLWithPath: naming.deletingPathExtension().path + suffix)
            let output = OutputNames.url(beside: stem, fileExtension: format.fileExtension)
            try ImageConvert.save(try rasterize(page), to: output, format: format, quality: 0.92, engines: .none)
            urls.append(output)
        }
        return urls
    }

    static func rasterize(_ page: PDFPage) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let scale = min(dpi / 72.0, 12000 / max(box.width, box.height, 1))
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConvertError.failed("Could not allocate page image") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // Pages are drawn relative to their crop box origin.
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw ConvertError.failed("Could not render page") }
        return image
    }

    static func plainText(_ input: URL) -> String {
        guard let document = PDFDocument(url: input), !document.isLocked else { return "" }
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
    }
}

// MARK: - Tools

extension PDFConvert {
    static func split(input: URL) throws -> [URL] {
        let document = try open(input)
        var urls: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else { continue }
            let part = PDFDocument()
            part.insert(copy, at: 0)
            let stem = URL(fileURLWithPath: input.deletingPathExtension().path + "-\(index + 1)")
            let output = OutputNames.url(beside: stem, fileExtension: "pdf")
            guard part.write(to: output) else { throw ConvertError.failed("Could not write page \(index + 1)") }
            urls.append(output)
        }
        return urls
    }

    /// Combines PDFs and images, in the order given, into one PDF beside the first file.
    static func merge(inputs: [URL]) throws -> URL {
        let merged = PDFDocument()
        for input in inputs {
            if Catalog.family(of: input.pathExtension) == .pdf {
                let document = try open(input)
                for index in 0..<document.pageCount {
                    if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            } else if let page = ImageConvert.pdfPage(try ImageConvert.load(input)) {
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.pageCount > 0, let first = inputs.first else { throw ConvertError.failed("Nothing to merge") }
        let output = OutputNames.url(beside: first, fileExtension: "pdf", tag: "merged")
        guard write(merged, to: output, jpeg: true) else { throw ConvertError.failed("Could not write the merged PDF") }
        return output
    }

    static func compress(_ input: URL) throws -> URL {
        let document = try open(input)
        let output = OutputNames.url(beside: input, fileExtension: "pdf", tag: "compressed")
        // The same filter Preview uses for "Reduce File Size". Text stays text; big images are downsampled.
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        let wrote: Bool
        if FileManager.default.fileExists(atPath: filterURL.path), let filter = QuartzFilter(url: filterURL) {
            wrote = document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        } else {
            wrote = write(document, to: output, jpeg: true, optimize: true)
        }
        guard wrote else { throw ConvertError.failed("Could not compress \(input.lastPathComponent)") }
        try ImageConvert.ensureSmaller(output, than: input)
        return output
    }

    static func rotate(_ input: URL) throws -> URL {
        let document = try open(input)
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { page.rotation = (page.rotation + 90) % 360 }
        }
        let output = OutputNames.url(beside: input, fileExtension: "pdf", tag: "rotated")
        guard document.write(to: output) else { throw ConvertError.failed("Could not rotate \(input.lastPathComponent)") }
        return output
    }

    static func stripMetadata(_ input: URL) throws -> URL {
        let document = try open(input)
        document.documentAttributes = [:]
        let output = OutputNames.url(beside: input, fileExtension: "pdf", tag: "clean")
        guard document.write(to: output) else { throw ConvertError.failed("Could not rewrite \(input.lastPathComponent)") }
        return output
    }
}

extension PDFConvert {
    /// Image options need macOS 13.4; older systems still write a valid PDF without them.
    static func write(_ document: PDFDocument, to url: URL, jpeg: Bool = false, optimize: Bool = false) -> Bool {
        if #available(macOS 13.4, *) {
            var options: [PDFDocumentWriteOption: Any] = [:]
            if jpeg { options[.saveImagesAsJPEGOption] = true }
            if optimize { options[.optimizeImagesForScreenOption] = true }
            return document.write(to: url, withOptions: options)
        }
        return document.write(to: url)
    }
}
