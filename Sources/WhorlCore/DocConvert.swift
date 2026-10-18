import AppKit
import Foundation

enum DocConvert {
    static func convert(input: URL, to format: Format, engines: Engines) throws -> URL {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        if format == .pdf, engines.libreOffice, ["docx", "doc", "odt", "rtf"].contains(ext) {
            return try Office.convert(input: input, to: .pdf, engines: engines)
        }
        // Word-family files keep their fonts, colours, tables and pictures when the target is also a rich format.
        if ["doc", "odt", "rtf", "rtfd"].contains(ext), [.pdf, .docx, .odt, .rtf].contains(format),
           let attributed = try? loadAttributed(input) {
            return try writeRich(attributed, format: format, title: input.deletingPathExtension().lastPathComponent, beside: input)
        }
        return try write(try load(input), format: format, beside: input)
    }

    static func loadAttributed(_ input: URL) throws -> NSAttributedString {
        let type: NSAttributedString.DocumentType
        switch Catalog.normalizedExtension(input.pathExtension) {
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "odt": type = .openDocument
        case "rtfd": type = .rtfd
        default: type = .rtf
        }
        do {
            return try NSAttributedString(url: input, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw ConvertError.unreadable(input.lastPathComponent)
        }
    }

    static func writeRich(_ attributed: NSAttributedString, format: Format, title: String, beside input: URL) throws -> URL {
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension)
        switch format {
        case .pdf: try RichText.pdf(attributed, title: title).write(to: output)
        case .docx: try RichText.data(attributed, type: .officeOpenXML, title: title).write(to: output)
        case .odt: try RichText.data(attributed, type: .openDocument, title: title).write(to: output)
        default: try RichText.data(attributed, type: .rtf, title: title).write(to: output)
        }
        return output
    }

    static func load(_ input: URL) throws -> Doc {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        let title = input.deletingPathExtension().lastPathComponent
        switch ext {
        case "md":
            var doc = MarkdownParser.parse(try readText(input), base: input.deletingLastPathComponent())
            if doc.title.isEmpty { doc.title = title }
            return doc
        case "txt":
            return TextParser.parse(try readText(input), title: title)
        case "html":
            var doc = HTMLParser.parse(try readText(input), base: input.deletingLastPathComponent())
            if doc.title.isEmpty { doc.title = title }
            return doc
        case "docx":
            return try Docx.read(input, title: title)
        case "epub":
            return try Epub.read(input)
        case "pdf":
            return try PDFLayout.doc(from: input, title: title)
        default:
            return try loadRich(input, title: title)
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        guard let text = String(data: data, encoding: .isoLatin1) else { throw ConvertError.unreadable(url.lastPathComponent) }
        return text
    }

    static func write(_ doc: Doc, format: Format, beside input: URL) throws -> URL {
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension)
        switch format {
        case .md: try writeMarkdown(doc, to: output)
        case .txt: try DocWriter.text(doc).write(to: output, atomically: true, encoding: .utf8)
        case .html: try DocWriter.html(doc).write(to: output, atomically: true, encoding: .utf8)
        case .epub: try Epub.write(doc, to: output)
        case .pdf: try RichText.pdf(RichText.attributed(doc), title: doc.title).write(to: output)
        case .docx: try Docx.write(doc, to: output)
        case .odt: try RichText.data(RichText.attributed(doc), type: .openDocument, title: doc.title).write(to: output)
        case .rtf: try RichText.data(RichText.attributed(doc), type: .rtf, title: doc.title).write(to: output)
        default: throw ConvertError.unsupported("Cannot write \(format.label) from text")
        }
        return output
    }

    /// Pictures go in a folder beside the .md file, so the markdown stays readable.
    private static func writeMarkdown(_ doc: Doc, to output: URL) throws {
        let images = doc.blocks.compactMap { block -> ImageData? in
            if case .image(let image) = block.kind { return image }
            return nil
        }
        var folderName = ""
        if !images.isEmpty {
            let stem = output.deletingPathExtension().lastPathComponent
            folderName = "\(stem)-images"
            let folder = output.deletingLastPathComponent().appendingPathComponent(folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, image) in images.enumerated() {
                try image.data.write(to: folder.appendingPathComponent("image-\(index + 1).\(image.ext)"))
            }
        }
        let encodedFolder = folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folderName
        let text = DocWriter.markdown(doc) { index in
            "\(encodedFolder)/image-\(index).\(images[index - 1].ext)"
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    private static func loadRich(_ input: URL, title: String) throws -> Doc {
        let type: NSAttributedString.DocumentType
        switch Catalog.normalizedExtension(input.pathExtension) {
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "odt": type = .openDocument
        case "rtfd": type = .rtfd
        default: type = .rtf
        }
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(url: input, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw ConvertError.unreadable(input.lastPathComponent)
        }
        return RichText.doc(from: attributed, title: title)
    }
}

/// NSAttributedString is the bridge to Word, ODT, RTF, and PDF.
enum RichText {
    static func doc(from text: NSAttributedString, title: String) -> Doc {
        let whole = text.string as NSString
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize, default: 0] += range.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        var blocks: [Block] = []
        var sizeOfBlock: [CGFloat?] = []
        var headingSizes = Set<CGFloat>()
        var location = 0
        var openTable: (table: NSTextTable, cells: [Int: [Int: String]])?

        func closeTable() {
            guard let open = openTable else { return }
            openTable = nil
            let columns = max(open.table.numberOfColumns, (open.cells.values.flatMap { $0.keys }.max() ?? -1) + 1)
            let rows = (open.cells.keys.max() ?? -1) + 1
            guard rows > 0, columns > 0 else { return }
            let grid = (0..<rows).map { r in (0..<columns).map { c in open.cells[r]?[c] ?? "" } }
            blocks.append(Block(kind: .table(TableData(rows: grid)), runs: []))
            sizeOfBlock.append(nil)
        }

        while location < whole.length {
            let range = whole.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            if let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
               let cell = style.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                if let open = openTable, open.table !== cell.table { closeTable() }
                if openTable == nil { openTable = (cell.table, [:]) }
                var piece = whole.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                var existing = openTable?.cells[cell.startingRow]?[cell.startingColumn] ?? ""
                if !piece.isEmpty { existing += existing.isEmpty ? piece : " " + piece }
                openTable?.cells[cell.startingRow, default: [:]][cell.startingColumn] = existing
                continue
            }
            closeTable()
            var pictures: [ImageData] = []
            text.enumerateAttribute(.attachment, in: range) { value, _, _ in
                if let attachment = value as? NSTextAttachment, let picture = Self.picture(from: attachment) { pictures.append(picture) }
            }
            defer { for picture in pictures { blocks.append(Block(kind: .image(picture), runs: [])); sizeOfBlock.append(nil) } }
            var runs: [Run] = []
            var largest: CGFloat = 0
            text.enumerateAttributes(in: range) { attributes, subrange, _ in
                var piece = whole.substring(with: subrange).replacingOccurrences(of: "\u{FFFC}", with: "")
                piece = piece.replacingOccurrences(of: "\u{2028}", with: "\n")
                guard !piece.isEmpty else { return }
                var run = Run(text: piece)
                if let font = attributes[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    run.bold = traits.contains(.bold)
                    run.italic = traits.contains(.italic)
                    run.code = traits.contains(.monoSpace)
                    if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { largest = max(largest, font.pointSize) }
                }
                if let link = attributes[.link] { run.link = (link as? URL)?.absoluteString ?? (link as? String) }
                runs.append(run)
            }
            guard var first = runs.first else { continue }
            var kind: BlockKind = .paragraph
            let lead = first.text.drop(while: { $0 == "\t" || $0 == " " })
            if let marker = lead.first, "•◦▪‣-–".contains(marker), lead.dropFirst().first == "\t" || lead.dropFirst().first == " " {
                kind = .bullet
                first.text = String(lead.dropFirst().drop(while: { $0 == "\t" || $0 == " " }))
            } else if let match = lead.range(of: "^\\d{1,3}([.)]\\s|[.)]?\\t)", options: .regularExpression) {
                kind = .number(Int(lead[..<match.upperBound].filter(\.isNumber)) ?? 1)
                first.text = String(lead[match.upperBound...])
            }
            runs[0] = first
            while let last = runs.last, last.text.allSatisfy(\.isNewline) { runs.removeLast() }
            if var last = runs.popLast() {
                last.text = last.text.trimmingCharacters(in: .newlines)
                runs.append(last)
            }
            guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            let short = runs.map(\.text).joined().count < 160 && kind == .paragraph
            let ratio = largest / max(body, 1)
            if short, ratio >= 1.12 { headingSizes.insert((largest * 2).rounded() / 2) }
            blocks.append(Block(kind: kind, runs: runs))
            sizeOfBlock.append(short && ratio >= 1.12 ? (largest * 2).rounded() / 2 : nil)
        }
        // Heading levels come from rank, not fixed sizes: the biggest size is H1, the next H2, and so on.
        closeTable()
        let ranked = headingSizes.sorted(by: >)
        for index in blocks.indices {
            guard let size = sizeOfBlock[index], let rank = ranked.firstIndex(of: size) else { continue }
            blocks[index].kind = .heading(min(rank + 1, 4))
            for run in blocks[index].runs.indices { blocks[index].runs[run].bold = false }
        }
        let heading = MarkdownParser.firstHeading(blocks)
        return Doc(title: heading.isEmpty ? title : heading, blocks: blocks)
    }

    static func picture(from attachment: NSTextAttachment) -> ImageData? {
        let image = attachment.image
            ?? attachment.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) }
        guard let image, image.size.width > 1, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let size = attachment.bounds.size.width > 1 ? attachment.bounds.size : image.size
        return ImageData(data: png, width: size.width, height: size.height, ext: "png")
    }

    static func attributed(_ doc: Doc) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = NSFont(name: "Helvetica Neue", size: 11) ?? .systemFont(ofSize: 11)
        let mono = NSFont(name: "Menlo", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        func font(_ run: Run, size: CGFloat, bold: Bool) -> NSFont {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if bold || run.bold { traits.insert(.bold) }
            if run.italic { traits.insert(.italic) }
            let family = run.code ? mono : (NSFont(name: base.fontName, size: size) ?? base)
            let descriptor = family.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: descriptor, size: run.code ? mono.pointSize : size) ?? family
        }
        for block in doc.blocks {
            if case .table(let data) = block.kind {
                result.append(Self.tableText(data, base: base))
                continue
            }
            if case .image(let image) = block.kind {
                result.append(Self.pictureText(image, base: base))
                continue
            }
            var size: CGFloat = 11
            var bold = false
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8
            style.lineSpacing = 2
            var prefix = ""
            switch block.kind {
            case .heading(let level):
                size = [22, 18, 15, 13, 12, 11][min(level, 6) - 1]
                bold = true
                style.paragraphSpacingBefore = 8
            case .bullet:
                prefix = "\u{2022}\t"
                style.firstLineHeadIndent = 8
                style.headIndent = 28
                style.tabStops = [NSTextTab(textAlignment: .left, location: 28)]
                style.paragraphSpacing = 3
            case .number(let n):
                prefix = "\(n).\t"
                style.firstLineHeadIndent = 8
                style.headIndent = 28
                style.tabStops = [NSTextTab(textAlignment: .left, location: 28)]
                style.paragraphSpacing = 3
            case .quote:
                style.firstLineHeadIndent = 18
                style.headIndent = 18
            case .code:
                style.firstLineHeadIndent = 8
                style.headIndent = 8
            case .paragraph, .table, .image:
                break
            }
            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: [.font: font(Run(text: ""), size: size, bold: false), .paragraphStyle: style]))
            }
            for run in block.runs {
                var attributes: [NSAttributedString.Key: Any] = [.font: font(run, size: size, bold: bold), .paragraphStyle: style]
                if let link = run.link, let url = URL(string: link) {
                    attributes[.link] = url
                    attributes[.foregroundColor] = NSColor.systemBlue
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if case .quote = block.kind { attributes[.foregroundColor] = NSColor.darkGray }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: font(Run(text: ""), size: size, bold: false), .paragraphStyle: style]))
        }
        return result
    }

    /// Widest a picture may be on a page with the default margins (A4 / Letter).
    static let contentWidth: CGFloat = 467

    static func pictureText(_ image: ImageData, base: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment(data: image.data, ofType: image.ext == "jpg" ? "public.jpeg" : "public.png")
        let scale = min(1, contentWidth / max(CGFloat(image.width), 1))
        attachment.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 10
        style.paragraphSpacingBefore = 4
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "\n"))
        result.addAttributes([.paragraphStyle: style, .font: base], range: NSRange(location: 0, length: result.length))
        return result
    }

    static func tableText(_ data: TableData, base: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let columns = max(data.columns, 1)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        for (r, row) in data.rows.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(0.6, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NSColor(white: 0.62, alpha: 1))
                cell.setWidth(5, type: .absoluteValueType, for: .padding)
                let header = r == 0 && data.header
                if header { cell.backgroundColor = NSColor(white: 0.92, alpha: 1) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                let text = c < row.count ? row[c] : ""
                let font = header ? (NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.bold), size: 11) ?? base) : base
                result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .paragraphStyle: style]))
            }
        }
        let spacer = NSMutableParagraphStyle()
        spacer.paragraphSpacing = 8
        result.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: spacer]))
        return result
    }

    static func data(_ text: NSAttributedString, type: NSAttributedString.DocumentType, title: String) throws -> Data {
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if !title.isEmpty { attributes[.title] = title }
        do {
            return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
        } catch {
            throw ConvertError.failed("Could not write the document")
        }
    }

    /// Paginated, selectable-text PDF drawn with the system text engine.
    static func pdf(_ text: NSAttributedString, title: String) throws -> Data {
        let letter = Locale.current.measurementSystem == .us
        let page = letter ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
        let margin: CGFloat = 64
        let content = CGSize(width: page.width - margin * 2, height: page.height - margin * 2)
        let storage = NSTextStorage(attributedString: text.length == 0 ? NSAttributedString(string: " ") : text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        var lastEnd = -1
        while containers.count < 5000 {
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            layout.ensureLayout(for: container)
            let end = NSMaxRange(layout.glyphRange(for: container))
            if end >= layout.numberOfGlyphs || end == lastEnd { break }
            lastEnd = end
        }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Whorl"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
            throw ConvertError.failed("Could not start the PDF")
        }
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: margin, y: page.height - margin)
            context.scaleBy(x: 1, y: -1)
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let glyphs = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: glyphs, at: .zero)
            layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

enum Epub {
    static func write(_ doc: Doc, to output: URL) throws {
        let root = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: root.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: root.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        let title = DocWriter.escape(doc.title.isEmpty ? "Untitled" : doc.title)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(stamp.prefix(19))Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """.write(to: root.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"en\">\n"
        try (head + "<head><title>\(title)</title></head>\n<body>\n<nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml\">\(title)</a></li></ol></nav>\n</body>\n</html>\n")
            .write(to: root.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)
        var pictures: [(name: String, image: ImageData)] = []
        let body = DocWriter.htmlBody(doc) { index, image in
            let name = "image-\(index).\(image.ext)"
            pictures.append((name, image))
            return "images/\(name)"
        }
        try (head + "<head><title>\(title)</title></head>\n<body>\n\(body)</body>\n</html>\n")
            .write(to: root.appendingPathComponent("OEBPS/chapter.xhtml"), atomically: true, encoding: .utf8)
        if !pictures.isEmpty {
            let folder = root.appendingPathComponent("OEBPS/images")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in pictures { try item.image.data.write(to: folder.appendingPathComponent(item.name)) }
            let manifest = pictures.enumerated().map { "    <item id=\"img\($0.offset + 1)\" href=\"images/\($0.element.name)\" media-type=\"\($0.element.image.mime)\"/>" }.joined(separator: "\n")
            let opfURL = root.appendingPathComponent("OEBPS/content.opf")
            let opf = try String(contentsOf: opfURL, encoding: .utf8)
                .replacingOccurrences(of: "  </manifest>", with: manifest + "\n  </manifest>")
            try opf.write(to: opfURL, atomically: true, encoding: .utf8)
        }
        try Shell.zip(directory: root, to: output, first: ["mimetype"])
    }

    static func read(_ input: URL) throws -> Doc {
        let root = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Shell.run("/usr/bin/ditto", ["-x", "-k", input.path, root.path])
        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard let container = try? String(contentsOf: containerURL, encoding: .utf8),
              let opfPath = attribute("full-path", in: container) else {
            throw ConvertError.unreadable(input.lastPathComponent)
        }
        let opfURL = root.appendingPathComponent(opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        var manifest: [String: String] = [:]
        for item in tags("item", in: opf) {
            if let id = attribute("id", in: item), let href = attribute("href", in: item) { manifest[id] = href }
        }
        var blocks: [Block] = []
        var title = tags("dc:title", in: opf).first.flatMap { _ in HTMLParser.decode(text(of: "dc:title", in: opf) ?? "") } ?? ""
        for ref in tags("itemref", in: opf) {
            guard let id = attribute("idref", in: ref), let href = manifest[id] else { continue }
            let decoded = href.removingPercentEncoding ?? href
            let page = opfURL.deletingLastPathComponent().appendingPathComponent(decoded)
            guard let html = try? String(contentsOf: page, encoding: .utf8) else { continue }
            blocks += HTMLParser.parse(html).blocks
        }
        if title.isEmpty { title = input.deletingPathExtension().lastPathComponent }
        return Doc(title: title, blocks: blocks)
    }

    private static func tags(_ name: String, in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: []) else { return [] }
        return regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap {
            Range($0.range, in: xml).map { String(xml[$0]) }
        }
    }

    private static func text(of name: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>(.*?)</\(name)>", options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: []),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }
}

enum Office {
    /// LibreOffice does the heavy lifting for formats macOS cannot read (slides, legacy sheets) and for faithful PDF output.
    static func convert(input: URL, to format: Format, engines: Engines) throws -> URL {
        let temp = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let produced = try produce(input: input, format: format, in: temp)
        let target = OutputNames.url(beside: input, fileExtension: format.fileExtension)
        try FileManager.default.copyItem(at: produced, to: target)
        return target
    }

    /// Slides to page images: LibreOffice makes a PDF, then each page is rendered.
    static func render(input: URL, to format: Format, engines: Engines) throws -> [URL] {
        let temp = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let pdf = try produce(input: input, format: .pdf, in: temp)
        return try PDFConvert.render(pdf: pdf, naming: input, format: format)
    }

    private static func produce(input: URL, format: Format, in temp: URL) throws -> URL {
        guard let soffice = Binaries.soffice else {
            throw ConvertError.unsupported("Install LibreOffice to open .\(input.pathExtension) files:  brew install --cask libreoffice")
        }
        let profile = temp.appendingPathComponent("profile")
        let out = temp.appendingPathComponent("out")
        try Shell.run(soffice, ["-env:UserInstallation=file://\(profile.path)", "--headless", "--convert-to", format.fileExtension, "--outdir", out.path, input.path])
        let produced = out.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(format.fileExtension)
        guard FileManager.default.fileExists(atPath: produced.path) else { throw ConvertError.failed("LibreOffice produced nothing") }
        return produced
    }
}
