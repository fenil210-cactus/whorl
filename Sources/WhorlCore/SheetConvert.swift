import Foundation

typealias Table = [[String]]

enum SheetConvert {
    static func convert(input: URL, to format: Format, engines: Engines) throws -> URL {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        if ext == "xls" { return try Office.convert(input: input, to: format, engines: engines) }
        let table: Table
        switch ext {
        case "csv": table = Delimited.parse(try DocConvert.readText(input), delimiter: ",")
        case "tsv": table = Delimited.parse(try DocConvert.readText(input), delimiter: "\t")
        case "xlsx": table = try XLSX.read(input)
        case "ods": table = try ODS.read(input)
        default: throw ConvertError.unsupported("Cannot read .\(ext)")
        }
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension)
        switch format {
        case .csv: try Delimited.write(table, delimiter: ",").write(to: output, atomically: true, encoding: .utf8)
        case .tsv: try Delimited.write(table, delimiter: "\t").write(to: output, atomically: true, encoding: .utf8)
        case .xlsx: try XLSX.write(table, to: output)
        case .ods: try ODS.write(table, to: output)
        default: throw ConvertError.unsupported("Cannot write \(format.label) from a sheet")
        }
        return output
    }
}

enum Delimited {
    /// RFC 4180 style: quoted fields may hold the delimiter, quotes ("" escapes), and line breaks.
    static func parse(_ source: String, delimiter: Character) -> Table {
        var rows: Table = []
        var row: [String] = []
        var field = ""
        var quoted = false
        // "\r\n" is a single Character in Swift, so normalise line endings before scanning.
        let clean = (source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var chars = Array(clean)
        if chars.last != "\n" { chars.append("\n") }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"", field.isEmpty {
                quoted = true
            } else if ch == delimiter {
                row.append(field); field = ""
            } else if ch == "\n" || ch == "\r" {
                if ch == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.append(ch) }
            i += 1
        }
        return rows
    }

    static func write(_ table: Table, delimiter: Character) -> String {
        table.map { row in
            row.map { value in
                let needs = value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
                return needs ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
    }
}

private func isPlainNumber(_ value: String) -> Bool {
    value.range(of: "^-?(0|[1-9][0-9]{0,14})(\\.[0-9]+)?$", options: .regularExpression) != nil
}

private func columnName(_ index: Int) -> String {
    var n = index
    var name = ""
    repeat {
        name = String(UnicodeScalar(UInt8(65 + n % 26))) + name
        n = n / 26 - 1
    } while n >= 0
    return name
}

private func columnIndex(_ reference: String) -> Int {
    var value = 0
    for ch in reference.uppercased().prefix(while: { $0.isLetter }) {
        value = value * 26 + Int(ch.asciiValue ?? 65) - 64
    }
    return max(value - 1, 0)
}

enum XLSX {
    static func write(_ table: Table, to output: URL) throws {
        let root = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for dir in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try put("[Content_Types].xml", xml + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>")
        try put("_rels/.rels", xml + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        try put("xl/workbook.xml", xml + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        try put("xl/_rels/workbook.xml.rels", xml + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>")
        var sheet = xml + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (r, row) in table.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = "\(columnName(c))\(r + 1)"
                if isPlainNumber(value) {
                    sheet += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(DocWriter.escape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        try put("xl/worksheets/sheet1.xml", sheet)
        try Shell.zip(directory: root, to: output, first: ["[Content_Types].xml"])
    }

    static func read(_ input: URL) throws -> Table {
        let root = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do { try Shell.run("/usr/bin/ditto", ["-x", "-k", input.path, root.path]) } catch { throw ConvertError.unreadable(input.lastPathComponent) }
        var shared: [String] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent("xl/sharedStrings.xml")) {
            let reader = SharedStrings()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            shared = reader.strings
        }
        let sheets = root.appendingPathComponent("xl/worksheets")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sheets.path)) ?? []).filter { $0.hasSuffix(".xml") }.sorted()
        guard let first = names.contains("sheet1.xml") ? "sheet1.xml" : names.first,
              let data = try? Data(contentsOf: sheets.appendingPathComponent(first)) else {
            throw ConvertError.unreadable(input.lastPathComponent)
        }
        let reader = SheetReader(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.rows
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inText = false
        private var inItem = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "si" { inItem = true; current = "" }
            if name == "t", inItem { inText = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" { strings.append(current); inItem = false }
        }
    }

    private final class SheetReader: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: Table = []
        private var row: [String] = []
        private var column = 0
        private var type = ""
        private var value = ""
        private var inValue = false

        init(shared: [String]) { self.shared = shared }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "row": row = []
            case "c":
                column = attributes["r"].map(columnIndex) ?? row.count
                type = attributes["t"] ?? ""
                value = ""
            case "v", "t": inValue = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { value += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": inValue = false
            case "c":
                var text = value
                if type == "s", let index = Int(value.trimmingCharacters(in: .whitespaces)), shared.indices.contains(index) { text = shared[index] }
                if type == "b" { text = value == "1" ? "TRUE" : "FALSE" }
                while row.count < column { row.append("") }
                row.append(text)
            case "row":
                while let last = row.last, last.isEmpty { row.removeLast() }
                rows.append(row)
            default: break
            }
        }
    }
}

enum ODS {
    static func write(_ table: Table, to output: URL) throws {
        let root = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let mime = "application/vnd.oasis.opendocument.spreadsheet"
        try mime.write(to: root.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"\(mime)\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"
            .write(to: root.appendingPathComponent("META-INF/manifest.xml"), atomically: true, encoding: .utf8)
        var body = ""
        for row in table {
            body += "<table:table-row>"
            for value in row {
                let text = DocWriter.escape(value)
                if value.isEmpty {
                    body += "<table:table-cell/>"
                } else if isPlainNumber(value) {
                    body += "<table:table-cell office:value-type=\"float\" office:value=\"\(value)\"><text:p>\(text)</text:p></table:table-cell>"
                } else {
                    body += "<table:table-cell office:value-type=\"string\"><text:p>\(text)</text:p></table:table-cell>"
                }
            }
            body += "</table:table-row>"
        }
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:spreadsheet><table:table table:name=\"Sheet1\">\(body)</table:table></office:spreadsheet></office:body></office:document-content>"
            .write(to: root.appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)
        try Shell.zip(directory: root, to: output, first: ["mimetype"])
    }

    static func read(_ input: URL) throws -> Table {
        let root = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do { try Shell.run("/usr/bin/ditto", ["-x", "-k", input.path, root.path]) } catch { throw ConvertError.unreadable(input.lastPathComponent) }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("content.xml")) else { throw ConvertError.unreadable(input.lastPathComponent) }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.rows
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var rows: Table = []
        private var tables = 0
        private var row: [String] = []
        private var rowRepeat = 1
        private var cellRepeat = 1
        private var number: String?
        private var paragraphs: [String] = []
        private var inParagraph = false
        private var inCell = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "table:table": tables += 1
            case "table:table-row":
                row = []
                rowRepeat = Int(attributes["table:number-rows-repeated"] ?? "") ?? 1
            case "table:table-cell", "table:covered-table-cell":
                inCell = true
                cellRepeat = Int(attributes["table:number-columns-repeated"] ?? "") ?? 1
                number = ["float", "percentage", "currency"].contains(attributes["office:value-type"] ?? "") ? attributes["office:value"] : nil
                paragraphs = []
            case "text:p":
                inParagraph = true
                paragraphs.append("")
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inParagraph, !paragraphs.isEmpty { paragraphs[paragraphs.count - 1] += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "text:p": inParagraph = false
            case "table:table-cell", "table:covered-table-cell":
                let text = number ?? paragraphs.joined(separator: "\n")
                row += Array(repeating: text, count: text.isEmpty ? min(cellRepeat, 1) : min(cellRepeat, 256))
                inCell = false
            case "table:table-row":
                while let last = row.last, last.isEmpty { row.removeLast() }
                guard tables == 1 else { return }
                if row.isEmpty && rowRepeat > 1 { return }
                rows += Array(repeating: row, count: min(rowRepeat, 1000))
            default: break
            }
        }
    }
}
