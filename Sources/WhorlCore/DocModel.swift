import AppKit
import Foundation

/// A small, format-neutral document: headings, paragraphs, lists, quotes, code.
/// Every text format reads into this and writes out of it.
struct Run: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var link: String?
}

struct TableData: Equatable {
    var rows: [[String]]
    /// The first row is a header (bold, shaded).
    var header = true
    var columns: Int { rows.map(\.count).max() ?? 0 }
}

struct ImageData: Equatable {
    var data: Data
    /// Natural size in points, used to size the picture on the page.
    var width: Double
    var height: Double
    /// "png" or "jpg".
    var ext = "png"
    var alt = ""
    var mime: String { ext == "jpg" ? "image/jpeg" : "image/png" }
}

/// Turns an `src` (embedded data, or a file beside the document) into a picture; the web is never touched.
enum ImageSource {
    static func load(_ src: String, base: URL?, width: Double? = nil, alt: String = "") -> ImageData? {
        var data: Data?
        if src.hasPrefix("data:") {
            if let comma = src.firstIndex(of: ",") { data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters) }
        } else if !src.contains("://"), let base {
            let path = src.removingPercentEncoding ?? src
            data = try? Data(contentsOf: path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path))
        }
        guard let data, let image = NSImage(data: data), image.size.width > 0 else { return nil }
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47]), isJPEG = data.starts(with: [0xFF, 0xD8])
        var bytes = data
        if !isPNG && !isJPEG {
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            bytes = png
        }
        let w = width ?? Double(image.size.width)
        return ImageData(data: bytes, width: w, height: w * Double(image.size.height) / Double(image.size.width), ext: isJPEG ? "jpg" : "png", alt: alt)
    }
}

enum BlockKind: Equatable {
    case paragraph, heading(Int), bullet, number(Int), quote, code
    case table(TableData)
    case image(ImageData)
}

struct Block: Equatable {
    var kind: BlockKind
    var runs: [Run]
    var plain: String { runs.map(\.text).joined() }
}

struct Doc {
    var title: String
    var blocks: [Block]
}

// MARK: - Markdown in

enum MarkdownParser {
    static func parse(_ source: String, base: URL? = nil) -> Doc {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(Block(kind: .paragraph, runs: inline(paragraph.joined(separator: " "))))
            paragraph = []
        }

        let text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            lineIndex += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inCode, trimmed.contains("|"), lineIndex < lines.count, isTableRule(lines[lineIndex]) {
                flush()
                var rows = [cells(trimmed)]
                lineIndex += 1
                while lineIndex < lines.count, lines[lineIndex].contains("|"),
                      !lines[lineIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[lineIndex]))
                    lineIndex += 1
                }
                blocks.append(Block(kind: .table(TableData(rows: rows)), runs: []))
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    blocks.append(Block(kind: .code, runs: [Run(text: code.joined(separator: "\n"), code: true)]))
                    code = []
                } else {
                    flush()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); continue }
            if let alt = HTMLParser.firstMatch("^!\\[([^\\]]*)\\]\\(([^)]*)\\)$", in: trimmed, group: 1), let src = HTMLParser.firstMatch("^!\\[([^\\]]*)\\]\\(([^)]*)\\)$", in: trimmed, group: 2) {
                flush()
                let link = src.split(separator: " ", maxSplits: 1).first.map(String.init) ?? src
                if let image = ImageSource.load(link, base: base, alt: alt) { blocks.append(Block(kind: .image(image), runs: [])) }
                continue
            }
            if isRule(trimmed) { flush(); continue }
            if let item = bullet(trimmed) { flush(); blocks.append(item); continue }
            if let item = numbered(trimmed) { flush(); blocks.append(item); continue }
            if trimmed.hasPrefix(">") {
                flush()
                let body = trimmed.drop(while: { $0 == ">" || $0 == " " })
                blocks.append(Block(kind: .quote, runs: inline(String(body))))
                continue
            }
            paragraph.append(trimmed)
        }
        flush()
        if inCode, !code.isEmpty { blocks.append(Block(kind: .code, runs: [Run(text: code.joined(separator: "\n"), code: true)])) }
        return Doc(title: firstHeading(blocks), blocks: blocks)
    }

    private static func isTableRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func firstHeading(_ blocks: [Block]) -> String {
        for block in blocks {
            if case .heading = block.kind { return block.plain }
        }
        return ""
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let body = line.dropFirst(hashes).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
        return Block(kind: .heading(hashes), runs: inline(body))
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func bullet(_ line: String) -> Block? {
        guard let first = line.first, "-*+".contains(first), line.dropFirst().first == " " else { return nil }
        var body = String(line.dropFirst(2))
        if body.hasPrefix("[ ] ") { body = "☐ " + body.dropFirst(4) }
        if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") { body = "☑ " + body.dropFirst(4) }
        return Block(kind: .bullet, runs: inline(body))
    }

    private static func numbered(_ line: String) -> Block? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count < 6 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return Block(kind: .number(Int(digits) ?? 1), runs: inline(String(rest.dropFirst(2))))
    }

    static func inline(_ source: String) -> [Run] {
        var runs: [Run] = []
        var buffer = ""
        var bold = false
        var italic = false
        let c = Array(source)
        var i = 0

        func flush() {
            if !buffer.isEmpty { runs.append(Run(text: buffer, bold: bold, italic: italic)); buffer = "" }
        }
        func spaceBefore(_ index: Int) -> Bool { index == 0 || c[index - 1].isWhitespace }
        func spaceAfter(_ index: Int) -> Bool { index + 1 >= c.count || c[index + 1].isWhitespace }

        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count { buffer.append(c[i + 1]); i += 2; continue }
            if ch == "`", let end = c[(i + 1)...].firstIndex(of: "`") {
                flush()
                runs.append(Run(text: String(c[(i + 1)..<end]), code: true))
                i = end + 1
                continue
            }
            if (ch == "*" || ch == "_"), i + 1 < c.count, c[i + 1] == ch {
                let opening = !bold && !(i + 2 < c.count && c[i + 2].isWhitespace)
                let closing = bold && !spaceBefore(i)
                if opening || closing { flush(); bold.toggle(); i += 2; continue }
            }
            if ch == "*" || ch == "_" {
                let prevWord = i > 0 && (c[i - 1].isLetter || c[i - 1].isNumber)
                let nextWord = i + 1 < c.count && (c[i + 1].isLetter || c[i + 1].isNumber)
                let wordInside = ch == "_" && (italic ? nextWord : prevWord)
                let opening = !italic && !spaceAfter(i)
                let closing = italic && !spaceBefore(i)
                if !wordInside, opening || closing { flush(); italic.toggle(); i += 1; continue }
            }
            if ch == "[" || (ch == "!" && i + 1 < c.count && c[i + 1] == "[") {
                let isImage = ch == "!"
                let open = isImage ? i + 1 : i
                if let close = c[(open + 1)...].firstIndex(of: "]"), close + 1 < c.count, c[close + 1] == "(",
                   let end = c[(close + 2)...].firstIndex(of: ")") {
                    flush()
                    let label = String(c[(open + 1)..<close])
                    let url = String(c[(close + 2)..<end])
                    var inner = inline(label)
                    if !isImage { for index in inner.indices { inner[index].link = url } }
                    inner.forEach { var run = $0; run.bold = run.bold || bold; run.italic = run.italic || italic; runs.append(run) }
                    i = end + 1
                    continue
                }
            }
            buffer.append(ch)
            i += 1
        }
        flush()
        return runs
    }
}

// MARK: - HTML in

enum HTMLParser {
    static func parse(_ html: String, base: URL? = nil) -> Doc {
        var source = html
        let title = firstMatch("<title[^>]*>(.*?)</title>", in: source).map { decode($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        for pattern in ["<!--.*?-->", "<script.*?</script>", "<style.*?</style>", "<head.*?</head>"] {
            source = source.replacingOccurrences(of: "(?s)" + pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        var blocks: [Block] = []
        var runs: [Run] = []
        var kind: BlockKind = .paragraph
        var bold = 0, italic = 0, pre = 0
        var link: String?
        var lists: [(ordered: Bool, count: Int)] = []
        var tableDepth = 0
        var tableRows: [[String]] = []
        var tableRow: [String] = []
        var tableHasHeader = false

        func flush() {
            let text = runs.map(\.text).joined()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var trimmed = runs
                if pre == 0, let first = trimmed.first { trimmed[0].text = String(first.text.drop(while: { $0.isWhitespace })) }
                blocks.append(Block(kind: kind, runs: trimmed.filter { !$0.text.isEmpty }))
            }
            runs = []
            kind = .paragraph
        }

        let scanner = Scanner(string: source)
        scanner.charactersToBeSkipped = nil
        while !scanner.isAtEnd {
            if let text = scanner.scanUpToString("<"), !text.isEmpty {
                var value = decode(text)
                if pre == 0 {
                    value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    if runs.isEmpty { value = String(value.drop(while: { $0 == " " })) }
                }
                if !value.isEmpty { runs.append(Run(text: value, bold: bold > 0, italic: italic > 0, code: pre > 0, link: link)) }
            }
            guard scanner.scanString("<") != nil else { break }
            let tag = scanner.scanUpToString(">") ?? ""
            _ = scanner.scanString(">")
            let closing = tag.hasPrefix("/")
            let name = tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if tableDepth == 0 { flush() }
                if !closing { kind = .heading(Int(name.dropFirst()) ?? 1) }
            case "table":
                if closing {
                    tableDepth = max(0, tableDepth - 1)
                    if tableDepth == 0 {
                        if !tableRow.isEmpty { tableRows.append(tableRow); tableRow = [] }
                        if !tableRows.isEmpty { blocks.append(Block(kind: .table(TableData(rows: tableRows, header: tableHasHeader || tableRows.count > 1)), runs: [])) }
                        tableRows = []
                        tableHasHeader = false
                    }
                } else {
                    if tableDepth == 0 { flush() }
                    tableDepth += 1
                }
            case "tr":
                if tableDepth == 1 {
                    if !tableRow.isEmpty { tableRows.append(tableRow) }
                    tableRow = []
                } else if tableDepth == 0 { flush() }
            case "img":
                if let src = firstMatch("src\\s*=\\s*[\"']([^\"']*)[\"']", in: tag),
                   let image = ImageSource.load(decode(src), base: base, width: Double(firstMatch("width\\s*=\\s*[\"']?(\\d+)", in: tag) ?? ""),
                                                alt: decode(firstMatch("alt\\s*=\\s*[\"']([^\"']*)[\"']", in: tag) ?? "")) {
                    flush()
                    blocks.append(Block(kind: .image(image), runs: []))
                }
            case "p", "div", "section", "article", "header", "footer", "figure", "caption":
                if tableDepth == 0 { flush() }
            case "br":
                runs.append(Run(text: "\n", bold: bold > 0, italic: italic > 0))
            case "ul", "ol":
                if tableDepth == 0 { flush() }
                if closing { _ = lists.popLast() } else { lists.append((name == "ol", 0)) }
            case "li":
                if tableDepth == 0 { flush() }
                if !closing, tableDepth == 0 {
                    if var top = lists.popLast() {
                        top.count += 1
                        lists.append(top)
                        kind = top.ordered ? .number(top.count) : .bullet
                    } else {
                        kind = .bullet
                    }
                }
            case "blockquote":
                flush()
                if !closing { kind = .quote }
            case "pre":
                flush()
                pre += closing ? -1 : 1
                if !closing { kind = .code }
            case "td", "th":
                if tableDepth >= 1 {
                    if closing {
                        if tableDepth == 1 {
                            tableRow.append(runs.map(\.text).joined().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines))
                            runs = []
                        }
                    } else if name == "th" { tableHasHeader = true }
                }
            case "strong", "b":
                bold = max(0, bold + (closing ? -1 : 1))
            case "em", "i":
                italic = max(0, italic + (closing ? -1 : 1))
            case "a":
                if closing { link = nil } else {
                    link = firstMatch("href\\s*=\\s*[\"']([^\"']*)[\"']", in: tag).map { decode($0) }
                }
            default:
                break
            }
        }
        flush()
        let heading = MarkdownParser.firstHeading(blocks)
        return Doc(title: title.isEmpty ? heading : title, blocks: blocks)
    }

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
            "hellip": "…", "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™",
            "bull": "•", "middot": "·", "laquo": "«", "raquo": "»", "eacute": "é", "euro": "€", "pound": "£",
        ]
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "&", let semi = text[index...].firstIndex(of: ";"), text.distance(from: index, to: semi) <= 10 {
                let entity = String(text[text.index(after: index)..<semi])
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String($0) }
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap { Unicode.Scalar($0) }.map { String($0) }
                } else {
                    replacement = named[entity]
                }
                if let replacement { out += replacement; index = text.index(after: semi); continue }
            }
            out.append(ch)
            index = text.index(after: index)
        }
        return out
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Plain text in

enum TextParser {
    static func parse(_ source: String, title: String) -> Doc {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = text.components(separatedBy: "\n\n").compactMap { chunk -> Block? in
            let body = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : Block(kind: .paragraph, runs: [Run(text: body)])
        }
        return Doc(title: title, blocks: blocks)
    }
}

// MARK: - Writers

enum DocWriter {
    /// `imagePath` returns where the n-th picture was saved (relative to the .md file); without it pictures are left out.
    static func markdown(_ doc: Doc, imagePath: ((Int) -> String)? = nil) -> String {
        var imageIndex = 0
        var out = ""
        var previous: BlockKind?
        /// Items of the same list sit on consecutive lines; a switch between bullets and numbers starts a new list.
        func sameList(_ a: BlockKind?, _ b: BlockKind) -> Bool {
            switch (a, b) {
            case (.bullet?, .bullet), (.number?, .number): return true
            default: return false
            }
        }
        for block in doc.blocks {
            let text = markdownInline(block.runs)
            let line: String
            switch block.kind {
            case .table(let table): line = markdownTable(table)
            case .image(let image):
                imageIndex += 1
                guard let imagePath else { continue }
                line = "![\(image.alt)](\(imagePath(imageIndex)))"
            case .heading(let level): line = String(repeating: "#", count: level) + " " + text
            case .bullet: line = "- " + text
            case .number(let n): line = "\(n). " + text
            case .quote: line = "> " + text.replacingOccurrences(of: "\n", with: "\n> ")
            case .code: line = "```\n" + block.plain + "\n```"
            case .paragraph: line = text
            }
            if previous != nil { out += sameList(previous, block.kind) ? "\n" : "\n\n" }
            out += line
            previous = block.kind
        }
        return out + "\n"
    }

    private static func markdownTable(_ table: TableData) -> String {
        let width = max(table.columns, 1)
        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: width - cells.count)
            return "| " + padded.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
        }
        var lines = [row(table.rows.first ?? [])]
        lines.append("|" + String(repeating: " --- |", count: width))
        for body in table.rows.dropFirst() { lines.append(row(body)) }
        return lines.joined(separator: "\n")
    }

    private static func markdownInline(_ runs: [Run]) -> String {
        runs.map { run in
            var text = run.text
            let leading = String(text.prefix(while: { $0 == " " }))
            let trailing = String(text.reversed().prefix(while: { $0 == " " }))
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return run.text }
            if run.code { text = "`\(text)`" }
            if run.bold && run.italic { text = "***\(text)***" } else if run.bold { text = "**\(text)**" } else if run.italic { text = "*\(text)*" }
            if let link = run.link, !link.isEmpty { text = "[\(text)](\(link))" }
            return leading + text + trailing
        }.joined()
    }

    static func text(_ doc: Doc) -> String {
        var out: [String] = []
        for block in doc.blocks {
            switch block.kind {
            case .bullet: out.append("• " + block.plain)
            case .number(let n): out.append("\(n). " + block.plain)
            case .quote: out.append("  " + block.plain)
            case .table(let table): out.append(table.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
            case .image: continue
            default: out.append(block.plain)
            }
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func htmlInline(_ runs: [Run]) -> String {
        runs.map { run in
            var text = escape(run.text).replacingOccurrences(of: "\n", with: "<br/>")
            if run.code { text = "<code>\(text)</code>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if run.italic { text = "<em>\(text)</em>" }
            if let link = run.link, !link.isEmpty { text = "<a href=\"\(escape(link))\">\(text)</a>" }
            return text
        }.joined()
    }

    /// Well-formed body markup, usable in HTML and XHTML.
    /// `imageSource` returns the `src` for the n-th picture; the default embeds it, so the page stands alone.
    static func htmlBody(_ doc: Doc, imageSource: ((Int, ImageData) -> String)? = nil) -> String {
        var imageIndex = 0
        var out = ""
        var open: String?
        func close() { if let tag = open { out += "</\(tag)>\n"; open = nil } }
        for block in doc.blocks {
            switch block.kind {
            case .bullet:
                if open != "ul" { close(); out += "<ul>\n"; open = "ul" }
                out += "<li>\(htmlInline(block.runs))</li>\n"
            case .number:
                if open != "ol" { close(); out += "<ol>\n"; open = "ol" }
                out += "<li>\(htmlInline(block.runs))</li>\n"
            case .heading(let level):
                close(); out += "<h\(level)>\(htmlInline(block.runs))</h\(level)>\n"
            case .quote:
                close(); out += "<blockquote><p>\(htmlInline(block.runs))</p></blockquote>\n"
            case .code:
                close(); out += "<pre><code>\(escape(block.plain))</code></pre>\n"
            case .paragraph:
                close(); out += "<p>\(htmlInline(block.runs))</p>\n"
            case .table(let table):
                close()
                out += "<table>\n"
                for (index, row) in table.rows.enumerated() {
                    let tag = index == 0 && table.header ? "th" : "td"
                    out += "<tr>" + row.map { "<\(tag)>\(escape($0))</\(tag)>" }.joined() + "</tr>\n"
                }
                out += "</table>\n"
            case .image(let image):
                close()
                imageIndex += 1
                let src = imageSource?(imageIndex, image) ?? "data:\(image.mime);base64,\(image.data.base64EncodedString())"
                out += "<p><img src=\"\(src)\" alt=\"\(escape(image.alt))\" width=\"\(Int(image.width))\"/></p>\n"
            }
        }
        close()
        return out
    }

    static func html(_ doc: Doc) -> String {
        let title = escape(doc.title)
        let style = "body{font:16px/1.6 -apple-system,Helvetica,Arial,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;color:#222}"
            + "pre{background:#f4f4f4;padding:.8rem;overflow:auto}code{font-family:Menlo,monospace}blockquote{margin-left:0;padding-left:1rem;border-left:3px solid #ccc;color:#555}"
            + "table{border-collapse:collapse;margin:1rem 0}th,td{border:1px solid #bbb;padding:.35rem .7rem;text-align:left}th{background:#f1f3f7}img{max-width:100%;height:auto}"
        return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\"/>\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>\n<title>\(title)</title>\n<style>\(style)</style>\n</head>\n<body>\n\(htmlBody(doc))</body>\n</html>\n"
    }
}
