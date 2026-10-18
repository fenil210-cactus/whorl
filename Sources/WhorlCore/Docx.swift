import AppKit
import Foundation

/// Word documents, read and written directly. macOS's own importer flattens tables and drops links and pictures,
/// so this reads the file's XML and keeps real headings, lists, tables, hyperlinks and images.
enum Docx {
    // MARK: Reading

    static func read(_ input: URL, title: String) throws -> Doc {
        let root = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try Shell.run("/usr/bin/ditto", ["-x", "-k", input.path, root.path])
        } catch {
            throw ConvertError.unreadable(input.lastPathComponent)
        }
        let word = root.appendingPathComponent("word")
        guard let documentXML = try? Data(contentsOf: word.appendingPathComponent("document.xml")) else {
            throw ConvertError.unreadable(input.lastPathComponent)
        }
        let rels = RelationshipReader.read(word.appendingPathComponent("_rels/document.xml.rels"))
        let styles = StyleReader.read(word.appendingPathComponent("styles.xml"))
        let numbering = NumberingReader.read(word.appendingPathComponent("numbering.xml"))
        let reader = BodyReader(folder: word, rels: rels, styles: styles, numbering: numbering)
        let parser = XMLParser(data: documentXML)
        parser.delegate = reader
        guard parser.parse() || !reader.blocks.isEmpty else { throw ConvertError.unreadable(input.lastPathComponent) }
        reader.promoteHeadings()
        let heading = MarkdownParser.firstHeading(reader.blocks)
        return Doc(title: heading.isEmpty ? title : heading, blocks: reader.blocks)
    }

    private final class RelationshipReader: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]

        static func read(_ url: URL) -> [String: String] {
            guard let data = try? Data(contentsOf: url) else { return [:] }
            let reader = RelationshipReader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.targets
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
        }
    }

    private final class StyleReader: NSObject, XMLParserDelegate {
        struct Table {
            var names: [String: String] = [:]
            var sizes: [String: CGFloat] = [:]
            var defaultSize: CGFloat = 11
        }

        var table = Table()
        private var current: String?
        private var inDefaults = false

        static func read(_ url: URL) -> Table {
            guard let data = try? Data(contentsOf: url) else { return Table() }
            let reader = StyleReader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.table
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "w:docDefaults": inDefaults = true
            case "w:style": current = attributes["w:styleId"]
            case "w:name": if let current, let value = attributes["w:val"] { table.names[current] = value.lowercased() }
            case "w:sz":
                guard let half = attributes["w:val"].flatMap(Double.init) else { break }
                if inDefaults { table.defaultSize = CGFloat(half / 2) } else if let current { table.sizes[current] = CGFloat(half / 2) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "w:docDefaults" { inDefaults = false }
            if name == "w:style" { current = nil }
        }
    }

    private final class NumberingReader: NSObject, XMLParserDelegate {
        struct Table {
            var formats: [Int: [Int: String]] = [:]  // abstractNumId -> ilvl -> numFmt
            var abstractOf: [Int: Int] = [:]  // numId -> abstractNumId
            func isBullet(numId: Int, level: Int) -> Bool {
                guard let abstract = abstractOf[numId], let format = formats[abstract]?[level] ?? formats[abstract]?[0] else { return true }
                return format == "bullet" || format == "none"
            }
        }

        var table = Table()
        private var abstract: Int?
        private var level = 0
        private var num: Int?

        static func read(_ url: URL) -> Table {
            guard let data = try? Data(contentsOf: url) else { return Table() }
            let reader = NumberingReader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.table
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "w:abstractNum": abstract = attributes["w:abstractNumId"].flatMap(Int.init)
            case "w:lvl": level = attributes["w:ilvl"].flatMap(Int.init) ?? 0
            case "w:numFmt": if let abstract, let value = attributes["w:val"] { table.formats[abstract, default: [:]][level] = value }
            case "w:num": num = attributes["w:numId"].flatMap(Int.init)
            case "w:abstractNumId": if let num, let id = attributes["w:val"].flatMap(Int.init) { table.abstractOf[num] = id }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "w:abstractNum" { abstract = nil }
            if name == "w:num" { num = nil }
        }
    }

    private final class BodyReader: NSObject, XMLParserDelegate {
        let folder: URL
        let rels: [String: String]
        let styles: StyleReader.Table
        let numbering: NumberingReader.Table
        var blocks: [Block] = []
        /// Biggest font size of each paragraph block, by block index, for documents that mark headings by size alone.
        private var sizeAt: [Int: CGFloat] = [:]
        private var weights: [CGFloat: Int] = [:]
        private var runSize: CGFloat?
        private var paragraphSize: CGFloat = 0

        // Paragraph state
        private var runs: [Run] = []
        private var pictures: [ImageData] = []
        private var styleId = ""
        private var numId: Int?
        private var level = 0
        private var outline: Int?
        private var counters: [Int: Int] = [:]
        // Run state
        private var inRPr = false
        private var inPPr = false
        private var bold = false
        private var italic = false
        private var mono = false
        private var inText = false
        private var text = ""
        // Links and fields
        private var links: [String?] = []
        private var fieldLink: String?
        private var instruction = ""
        private var inInstruction = false
        private var fieldDepth = 0
        // Drawings
        private var embed: String?
        private var drawingSize: CGSize?
        // Tables
        private var tableDepth = 0
        private var rows: [[String]] = []
        private var row: [String] = []
        private var cell = ""
        private var headerRows = 0

        init(folder: URL, rels: [String: String], styles: StyleReader.Table, numbering: NumberingReader.Table) {
            self.folder = folder
            self.rels = rels
            self.styles = styles
            self.numbering = numbering
        }

        private var currentLink: String? { links.last.flatMap { $0 } ?? fieldLink }

        private func isOn(_ attributes: [String: String]) -> Bool {
            guard let value = attributes["w:val"]?.lowercased() else { return true }
            return !(value == "0" || value == "false" || value == "off")
        }

        private func addRun(_ value: String) {
            guard !value.isEmpty else { return }
            runs.append(Run(text: value, bold: bold, italic: italic, code: mono, link: currentLink))
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let size = runSize ?? styles.sizes[styleId] ?? styles.defaultSize
                paragraphSize = max(paragraphSize, size)
                weights[size, default: 0] += value.count
            }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "w:p":
                runs = []
                paragraphSize = 0
                pictures = []
                styleId = ""
                numId = nil
                level = 0
                outline = nil
            case "w:pPr": inPPr = true
            case "w:pStyle": if inPPr { styleId = attributes["w:val"] ?? "" }
            case "w:ilvl": if inPPr { level = attributes["w:val"].flatMap(Int.init) ?? 0 }
            case "w:numId": if inPPr { numId = attributes["w:val"].flatMap(Int.init) }
            case "w:outlineLvl": if inPPr, let value = attributes["w:val"].flatMap(Int.init), value < 9 { outline = value + 1 }
            case "w:r":
                bold = false
                italic = false
                mono = false
                runSize = nil
            case "w:rPr": inRPr = true
            case "w:sz": if inRPr, let half = attributes["w:val"].flatMap(Double.init) { runSize = CGFloat(half / 2) }
            case "w:b": if inRPr { bold = isOn(attributes) }
            case "w:i": if inRPr { italic = isOn(attributes) }
            case "w:rFonts":
                if inRPr, let font = (attributes["w:ascii"] ?? attributes["w:hAnsi"])?.lowercased() {
                    mono = font.contains("courier") || font.contains("consolas") || font.contains("mono") || font.contains("menlo")
                }
            case "w:t": inText = true; text = ""
            case "w:tab": addRun("\t")
            case "w:br": if attributes["w:type"] != "page" { addRun("\n") }
            case "w:noBreakHyphen": addRun("-")
            case "w:hyperlink": links.append(attributes["r:id"].flatMap { rels[$0] } ?? attributes["w:anchor"].map { "#" + $0 })
            case "w:fldSimple":
                links.append(Self.hyperlink(in: attributes["w:instr"] ?? ""))
            case "w:fldChar":
                switch attributes["w:fldCharType"] {
                case "begin": fieldDepth += 1; instruction = ""
                case "separate": fieldLink = Self.hyperlink(in: instruction); inInstruction = false
                case "end": fieldDepth = max(0, fieldDepth - 1); fieldLink = nil; inInstruction = false
                default: break
                }
            case "w:instrText": inInstruction = true
            case "wp:extent":
                if let cx = attributes["cx"].flatMap(Double.init), let cy = attributes["cy"].flatMap(Double.init) {
                    drawingSize = CGSize(width: cx / 12700, height: cy / 12700)
                }
            case "a:blip": if let id = attributes["r:embed"] { embed = id }
            case "w:drawing": embed = nil; drawingSize = nil
            case "w:tbl":
                tableDepth += 1
                if tableDepth == 1 { rows = []; headerRows = 0 }
            case "w:tr": if tableDepth == 1 { row = [] }
            case "w:tblHeader": if tableDepth == 1 { headerRows += 1 }
            case "w:tc": if tableDepth == 1 { cell = "" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { text += string } else if inInstruction { instruction += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "w:t":
                inText = false
                addRun(text)
            case "w:pPr": inPPr = false
            case "w:rPr": inRPr = false
            case "w:instrText": inInstruction = false
            case "w:hyperlink", "w:fldSimple": _ = links.popLast()
            case "w:drawing":
                if let embed, let target = rels[embed], let picture = Self.load(folder.appendingPathComponent(target), size: drawingSize) { pictures.append(picture) }
            case "w:tc":
                if tableDepth == 1 { row.append(cell.trimmingCharacters(in: .whitespacesAndNewlines)) }
            case "w:tr":
                if tableDepth == 1, !row.isEmpty { rows.append(row) }
            case "w:tbl":
                tableDepth = max(0, tableDepth - 1)
                if tableDepth == 0, !rows.isEmpty {
                    blocks.append(Block(kind: .table(TableData(rows: rows, header: true)), runs: []))
                }
            case "w:p": finishParagraph()
            default: break
            }
        }

        private func finishParagraph() {
            if tableDepth > 0 {
                let value = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { cell += cell.isEmpty ? value : " " + value }
                return
            }
            defer { for picture in pictures { blocks.append(Block(kind: .image(picture), runs: [])) } }
            var merged: [Run] = []
            for run in runs {
                if var last = merged.last, last.bold == run.bold, last.italic == run.italic, last.code == run.code, last.link == run.link {
                    last.text += run.text
                    merged[merged.count - 1] = last
                } else {
                    merged.append(run)
                }
            }
            if var first = merged.first { first.text = String(first.text.drop(while: { $0 == " " || $0 == "\n" })); merged[0] = first }
            if var last = merged.last { last.text = String(last.text.reversed().drop(while: { $0 == " " || $0 == "\n" }).reversed()); merged[merged.count - 1] = last }
            merged = merged.filter { !$0.text.isEmpty }
            guard !merged.isEmpty else { return }

            let name = (styles.names[styleId] ?? styleId).lowercased()
            var kind: BlockKind = .paragraph
            if let level = headingLevel(name) ?? outline {
                kind = .heading(min(level, 6))
                for index in merged.indices { merged[index].bold = false }
            } else if let numId, numId != 0 {
                if numbering.isBullet(numId: numId, level: level) {
                    kind = .bullet
                } else {
                    counters[numId, default: 0] += 1
                    kind = .number(counters[numId] ?? 1)
                }
            } else if name.contains("list bullet") {
                kind = .bullet
            } else if name.contains("list number") {
                counters[-1, default: 0] += 1
                kind = .number(counters[-1] ?? 1)
            } else if name.contains("quote") {
                kind = .quote
            } else if name.contains("code") || name.contains("preformatted") || name.contains("macro") {
                kind = .code
            }
            // Bullets and numbers typed as text ("•<tab>item") are still lists.
            if kind == .paragraph, var first = merged.first {
                let t = String(first.text.drop(while: { $0 == "\t" || $0 == " " }))
                if let mark = t.first, "•◦▪‣●·–".contains(mark), t.dropFirst().first == "\t" || t.dropFirst().first == " " {
                    kind = .bullet
                    first.text = String(t.dropFirst().drop(while: { $0 == "\t" || $0 == " " }))
                    merged[0] = first
                } else if let match = t.range(of: "^\\d{1,3}([.)]\\s|[.)]?\\t)", options: .regularExpression) {
                    kind = .number(Int(t[..<match.upperBound].filter(\.isNumber)) ?? 1)
                    first.text = String(t[match.upperBound...])
                    merged[0] = first
                }
            }
            for index in merged.indices { merged[index].text = merged[index].text.replacingOccurrences(of: "\t", with: " ") }
            merged = merged.filter { !$0.text.isEmpty }
            guard !merged.isEmpty else { return }
            if kind == .paragraph { sizeAt[blocks.count] = paragraphSize }
            blocks.append(Block(kind: kind, runs: merged))
        }

        /// Documents without heading styles show headings as bigger text: the biggest size is H1, the next H2, and so on.
        func promoteHeadings() {
            let body = weights.max { $0.value < $1.value }?.key ?? styles.defaultSize
            var candidates: [Int: CGFloat] = [:]
            for (index, size) in sizeAt where size >= body * 1.12 && blocks[index].plain.count <= 160 && blocks[index].kind == .paragraph {
                candidates[index] = (size * 2).rounded() / 2
            }
            let ranked = Set(candidates.values).sorted(by: >)
            for (index, size) in candidates {
                guard let rank = ranked.firstIndex(of: size) else { continue }
                blocks[index].kind = .heading(min(rank + 1, 4))
                for run in blocks[index].runs.indices { blocks[index].runs[run].bold = false }
            }
        }

        private func headingLevel(_ name: String) -> Int? {
            if name == "title" { return 1 }
            if name == "subtitle" { return 2 }
            for prefix in ["heading ", "heading", "kop ", "überschrift "] where name.hasPrefix(prefix) {
                if let digit = name.dropFirst(prefix.count).first?.wholeNumberValue, digit > 0 { return digit }
            }
            return nil
        }

        static func hyperlink(in instruction: String) -> String? {
            let parts = instruction.split(separator: "\"", omittingEmptySubsequences: false)
            guard instruction.contains("HYPERLINK"), parts.count >= 2 else { return nil }
            return String(parts[1])
        }

        static func load(_ url: URL, size: CGSize?) -> ImageData? {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.size.width > 0 else { return nil }
            let width = size?.width ?? image.size.width
            let height = size?.height ?? image.size.height
            let ext = url.pathExtension.lowercased()
            if ext == "png" { return ImageData(data: data, width: width, height: height, ext: "png") }
            if ext == "jpg" || ext == "jpeg" { return ImageData(data: data, width: width, height: height, ext: "jpg") }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return ImageData(data: png, width: width, height: height, ext: "png")
        }
    }

    // MARK: Writing

    private static let namespaces = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
        + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""

    static func write(_ doc: Doc, to output: URL) throws {
        let root = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for folder in ["_rels", "word/_rels", "word/media", "docProps"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }

        var relationships: [String] = [
            "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>",
            "<Relationship Id=\"rIdNumbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>",
        ]
        var body = ""
        var imageCount = 0
        var linkCount = 0
        var numberedLists = 0
        var previous: BlockKind?
        var hasJpeg = false

        func runXML(_ run: Run) -> String {
            var props = ""
            if run.code { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>" }
            if run.bold { props += "<w:b/>" }
            if run.italic { props += "<w:i/>" }
            if run.link != nil { props += "<w:rStyle w:val=\"Hyperlink\"/>" }
            let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
            let pieces = clean(run.text).components(separatedBy: "\n")
            let content = pieces.enumerated().map { index, piece in
                (index > 0 ? "<w:br/>" : "") + (piece.isEmpty ? "" : "<w:t xml:space=\"preserve\">\(DocWriter.escape(piece))</w:t>")
            }.joined()
            var xml = "<w:r>\(rPr)\(content)</w:r>"
            if let link = run.link, !link.isEmpty {
                linkCount += 1
                let id = "rIdLink\(linkCount)"
                relationships.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(DocWriter.escape(link))\" TargetMode=\"External\"/>")
                xml = "<w:hyperlink r:id=\"\(id)\">\(xml)</w:hyperlink>"
            }
            return xml
        }

        func paragraph(_ runs: [Run], style: String? = nil, numbering: (id: Int, level: Int)? = nil) -> String {
            var props = ""
            if let style { props += "<w:pStyle w:val=\"\(style)\"/>" }
            if let numbering { props += "<w:numPr><w:ilvl w:val=\"\(numbering.level)\"/><w:numId w:val=\"\(numbering.id)\"/></w:numPr>" }
            return "<w:p>\(props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>")\(runs.map(runXML).joined())</w:p>"
        }

        for block in doc.blocks {
            switch block.kind {
            case .heading(let level):
                body += paragraph(block.runs, style: "Heading\(min(max(level, 1), 4))")
            case .bullet:
                body += paragraph(block.runs, style: "ListParagraph", numbering: (1, 0))
            case .number(let n):
                if case .number? = previous, n != 1 {} else { numberedLists += 1 }
                body += paragraph(block.runs, style: "ListParagraph", numbering: (1 + numberedLists, 0))
            case .quote:
                body += paragraph(block.runs, style: "Quote")
            case .code:
                body += paragraph(block.runs.map { var r = $0; r.code = false; return r }, style: "Code")
            case .paragraph:
                body += paragraph(block.runs)
            case .table(let table):
                body += tableXML(table)
            case .image(let image):
                imageCount += 1
                let name = "image\(imageCount).\(image.ext)"
                try image.data.write(to: root.appendingPathComponent("word/media/\(name)"))
                if image.ext == "jpg" { hasJpeg = true }
                relationships.append("<Relationship Id=\"rIdImg\(imageCount)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>")
                body += imageXML(image, id: imageCount, name: name)
            }
            previous = block.kind
        }

        let letter = Locale.current.measurementSystem == .us
        let page = letter ? "w:w=\"12240\" w:h=\"15840\"" : "w:w=\"11906\" w:h=\"16838\""
        let sectPr = "<w:sectPr><w:pgSz \(page)/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document \(namespaces)><w:body>\(body)\(sectPr)</w:body></w:document>")
            .write(to: root.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships.joined())</Relationships>")
            .write(to: root.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        try styles.write(to: root.appendingPathComponent("word/styles.xml"), atomically: true, encoding: .utf8)
        try numberingXML(numberedLists: numberedLists).write(to: root.appendingPathComponent("word/numbering.xml"), atomically: true, encoding: .utf8)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
            + "</Relationships>").write(to: root.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>\(DocWriter.escape(clean(doc.title)))</dc:title><dc:creator>Whorl</dc:creator>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created></cp:coreProperties>")
            .write(to: root.appendingPathComponent("docProps/core.xml"), atomically: true, encoding: .utf8)
        var defaults = "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/>"
        if hasJpeg { defaults += "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>" }
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\(defaults)"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
            + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>")
            .write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try Shell.zip(directory: root, to: output)
    }

    /// XML cannot hold most control characters.
    private static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }))
    }

    private static func tableXML(_ table: TableData) -> String {
        let columns = max(table.columns, 1)
        let total = 9000
        let widthEach = total / columns
        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblLook w:val=\"04A0\"/></w:tblPr><w:tblGrid>"
        xml += String(repeating: "<w:gridCol w:w=\"\(widthEach)\"/>", count: columns) + "</w:tblGrid>"
        for (index, row) in table.rows.enumerated() {
            let header = index == 0 && table.header
            xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for column in 0..<columns {
                let text = column < row.count ? row[column] : ""
                let shade = header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"E8ECF4\"/>" : ""
                let run = "<w:r>\(header ? "<w:rPr><w:b/></w:rPr>" : "")<w:t xml:space=\"preserve\">\(DocWriter.escape(clean(text)))</w:t></w:r>"
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(widthEach)\" w:type=\"dxa\"/>\(shade)</w:tcPr><w:p><w:pPr><w:spacing w:after=\"40\"/></w:pPr>\(run)</w:p></w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl><w:p><w:pPr><w:spacing w:after=\"60\"/></w:pPr></w:p>"
    }

    private static func imageXML(_ image: ImageData, id: Int, name: String) -> String {
        let maxWidth = 432.0
        let scale = min(1, maxWidth / max(image.width, 1))
        let cx = Int(image.width * scale * 12700)
        let cy = Int(image.height * scale * 12700)
        return "<w:p><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:docPr id=\"\(id)\" name=\"Picture \(id)\" descr=\"\(DocWriter.escape(image.alt))\"/>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
            + "<pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"rIdImg\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    }

    private static func numberingXML(numberedLists: Int) -> String {
        let indent = "<w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr>"
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:numbering \(namespaces)>"
        xml += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:lvlJc w:val=\"left\"/>\(indent)</w:lvl></w:abstractNum>"
        xml += "<w:abstractNum w:abstractNumId=\"2\"><w:multiLevelType w:val=\"hybridMultilevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/><w:lvlJc w:val=\"left\"/>\(indent)</w:lvl></w:abstractNum>"
        xml += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num>"
        for index in 0..<numberedLists {
            xml += "<w:num w:numId=\"\(index + 2)\"><w:abstractNumId w:val=\"2\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        return xml + "</w:numbering>"
    }

    private static var styles: String {
        func heading(_ level: Int, size: Int, color: String) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
                + "<w:pPr><w:keepNext/><w:spacing w:before=\"\(level == 1 ? 360 : 240)\" w:after=\"100\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr>"
                + "<w:rPr><w:b/><w:color w:val=\"\(color)\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:styles \(namespaces)>"
            + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"140\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + heading(1, size: 36, color: "1F3864") + heading(2, size: 30, color: "2F5496") + heading(3, size: 26, color: "2F5496") + heading(4, size: 24, color: "404040")
            + "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:spacing w:after=\"60\"/><w:ind w:left=\"720\"/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:ind w:left=\"567\"/></w:pPr><w:rPr><w:i/><w:color w:val=\"555555\"/></w:rPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/><w:spacing w:after=\"120\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/><w:sz w:val=\"19\"/></w:rPr></w:style>"
            + "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
            + "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:basedOn w:val=\"TableNormal\"/><w:tblPr><w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/>" }.joined()
            + "</w:tblBorders><w:tblCellMar><w:top w:w=\"60\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/><w:bottom w:w=\"60\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
            + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/></w:tblPr></w:style>"
            + "</w:styles>"
    }
}
