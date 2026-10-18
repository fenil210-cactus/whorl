import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Reads a PDF the way a person would: lines from character positions and fonts, then paragraphs,
/// headings, lists, tables and pictures. Scanned pages are read with the system's text recognition.
/// The result is a `Doc`, so every output format (DOCX, Markdown, HTML, EPUB, ...) benefits.
enum PDFLayout {
    // MARK: Building blocks

    struct StyledText {
        var text: String
        var bold = false
        var italic = false
        var mono = false
    }

    struct Piece {
        var text: String
        var x0: CGFloat
        var x1: CGFloat
    }

    struct Line {
        var runs: [StyledText]
        var pieces: [Piece]
        var x0: CGFloat
        var x1: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var size: CGFloat
        var allBold: Bool

        var text: String { runs.map(\.text).joined() }
        var midY: CGFloat { (top + bottom) / 2 }
    }

    struct Placed {
        var block: Block
        var top: CGFloat
    }

    // MARK: Entry point

    static func doc(from input: URL, title: String) throws -> Doc {
        let document = try PDFConvert.open(input)
        var pageLines: [[Line]] = []
        var pageImages: [[(image: ImageData, rect: CGRect)]] = []
        var boxes: [CGRect] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            boxes.append(box)
            var lines = textLines(on: page)
            var images: [(ImageData, CGRect)] = []
            if lines.count < 2 {
                // A scan or a picture-only page: read it with text recognition.
                let recognised = recognisedLines(on: page, box: box)
                if !recognised.isEmpty { lines = recognised } else if let whole = crop(page, rect: box) { images = [(whole, box)] }
            } else {
                images = pictures(on: page, box: box, hasText: true)
            }
            pageLines.append(lines)
            pageImages.append(images)
        }
        pageLines = dropRepeatedMargins(pageLines, boxes: boxes)
        let repeated = repeatedImageKeys(pageImages)

        let body = bodySize(pageLines)
        var headingSizes = Set<CGFloat>()
        for lines in pageLines { for line in lines where isHeadingSize(line, body: body) { headingSizes.insert(roundHalf(line.size)) } }
        let ranked = headingSizes.sorted(by: >)

        var blocks: [Block] = []
        for (index, lines) in pageLines.enumerated() {
            var placed = assemble(lines, body: body, ranked: ranked, box: boxes[index])
            for item in pageImages[index] where !repeated.contains(key(item.rect)) {
                let top = item.rect.maxY
                let block = Block(kind: .image(item.image), runs: [])
                if let at = placed.firstIndex(where: { $0.top < top - 1 }) { placed.insert(Placed(block: block, top: top), at: at) } else { placed.append(Placed(block: block, top: top)) }
            }
            var next = placed.map(\.block)
            // A sentence that runs across the page break is one paragraph.
            if let last = blocks.last, let first = next.first, last.kind == .paragraph, first.kind == .paragraph,
               !endsSentence(last.plain), let start = first.plain.first, start.isLowercase {
                var merged = last
                merged.runs = joinRuns(merged.runs, first.runs)
                blocks[blocks.count - 1] = merged
                next.removeFirst()
            }
            blocks += next
        }
        let heading = MarkdownParser.firstHeading(blocks)
        return Doc(title: heading.isEmpty ? title : heading, blocks: blocks)
    }

    // MARK: Lines from the PDF text layer

    /// PDFKit's per-character boxes are unreliable, but its line and word selections are what its own text selection uses.
    private static func textLines(on page: PDFPage) -> [Line] {
        let box = page.bounds(for: .cropBox)
        guard let everything = page.selection(for: box) else { return [] }
        var lines: [Line] = []
        for selection in everything.selectionsByLine() {
            let rect = selection.bounds(for: page)
            guard rect.width > 1, rect.height > 1, let attributed = selection.attributedString, attributed.length > 0 else { continue }
            let whole = attributed.string as NSString
            var runs: [StyledText] = []
            var weights: [CGFloat: Int] = [:]
            var boldChars = 0
            var chars = 0
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                let piece = whole.substring(with: range).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                guard !piece.isEmpty else { return }
                let style = Style(font: attributes[.font] as? NSFont, fallbackSize: rect.height / 1.2)
                runs.append(StyledText(text: piece, bold: style.bold, italic: style.italic, mono: style.mono))
                let visible = piece.filter { !$0.isWhitespace }.count
                weights[(style.size * 2).rounded() / 2, default: 0] += visible
                chars += visible
                if style.bold { boldChars += visible }
            }
            // Tidy: collapse repeated spaces, trim the ends, merge neighbours with the same style.
            var merged: [StyledText] = []
            for run in runs {
                var text = run.text.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                if let last = merged.last, last.text.hasSuffix(" ") { text = String(text.drop(while: { $0 == " " })) }
                guard !text.isEmpty else { continue }
                if var last = merged.last, last.bold == run.bold, last.italic == run.italic, last.mono == run.mono {
                    last.text += text
                    merged[merged.count - 1] = last
                } else {
                    merged.append(StyledText(text: text, bold: run.bold, italic: run.italic, mono: run.mono))
                }
            }
            if var first = merged.first { first.text = String(first.text.drop(while: { $0 == " " })); merged[0] = first }
            if var last = merged.last { last.text = String(last.text.reversed().drop(while: { $0 == " " }).reversed()); merged[merged.count - 1] = last }
            merged = merged.filter { !$0.text.isEmpty }
            guard !merged.isEmpty, chars > 0 else { continue }
            let size = weights.max { $0.value < $1.value }?.key ?? rect.height / 1.2
            let pieces = splitIntoPieces(on: page, rect: rect, size: size, fallback: merged.map(\.text).joined())
            lines.append(Line(runs: merged, pieces: pieces, x0: rect.minX, x1: rect.maxX, top: rect.maxY, bottom: rect.minY,
                              size: size, allBold: boldChars * 10 >= chars * 9))
        }
        return mergeRows(lines)
    }

    /// PDFKit reports table cells (and list markers beside their text) as separate lines on the same baseline; they are one row.
    private static func mergeRows(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        func sameRow(_ row: Line, _ line: Line) -> Bool {
            abs(row.midY - line.midY) <= min(row.top - row.bottom, line.top - line.bottom) * 0.5 && line.x0 >= row.x1 - 1
        }
        for line in lines {
            // PDFKit can emit one column of a table after the others, so short cells look further back for their row.
            var target: Int?
            if let i = out.indices.last, sameRow(out[i], line) {
                target = i
            } else if line.text.count <= 40 {
                target = out.indices.reversed().prefix(80).first { sameRow(out[$0], line) && out[$0].pieces.allSatisfy { $0.text.count <= 40 } }
            }
            if let target {
                var last = out[target]
                let gap = line.x0 - last.x1
                var pieces = last.pieces
                if gap > max(max(last.size, line.size) * 1.8, 16) || line.pieces.count > 1 {
                    pieces += line.pieces
                } else if var tail = pieces.popLast(), let head = line.pieces.first {
                    tail.text += " " + head.text
                    tail.x1 = head.x1
                    pieces.append(tail)
                    pieces += line.pieces.dropFirst()
                } else {
                    pieces += line.pieces
                }
                last.runs += [StyledText(text: " ")] + line.runs
                last.pieces = pieces
                last.x1 = max(last.x1, line.x1)
                last.top = max(last.top, line.top)
                last.bottom = min(last.bottom, line.bottom)
                last.allBold = last.allBold && line.allBold
                out[target] = last
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// Walks a line word by word; wide gaps become separate cells (the raw material for tables).
    private static func splitIntoPieces(on page: PDFPage, rect: CGRect, size: CGFloat, fallback: String) -> [Piece] {
        let y = rect.midY
        var words: [(rect: CGRect, text: String)] = []
        var x = rect.minX + 0.5
        var guardCount = 0
        while x < rect.maxX, guardCount < 400 {
            guardCount += 1
            guard let word = page.selectionForWord(at: CGPoint(x: x, y: y)) else { x += 2; continue }
            let b = word.bounds(for: page)
            if b.width <= 0 || b.maxX <= x { x += 2; continue }
            if let last = words.last, abs(last.rect.minX - b.minX) < 0.5 { x = b.maxX + 0.5; continue }
            // A hit that belongs to another line (taller overlap) is ignored.
            if abs(b.midY - y) <= rect.height { words.append((b, (word.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))) }
            x = b.maxX + 0.5
        }
        words = words.filter { !$0.text.isEmpty }
        guard !words.isEmpty else { return [Piece(text: fallback, x0: rect.minX, x1: rect.maxX)] }
        let threshold = max(size * 1.8, 16)
        var pieces: [Piece] = []
        var text = words[0].text
        var start = words[0].rect.minX
        var end = words[0].rect.maxX
        for word in words.dropFirst() {
            if word.rect.minX - end > threshold {
                pieces.append(Piece(text: text, x0: start, x1: end))
                text = word.text
                start = word.rect.minX
            } else {
                text += " " + word.text
            }
            end = word.rect.maxX
        }
        pieces.append(Piece(text: text, x0: start, x1: end))
        // Word hits can split or drop symbols like "+" or "%"; a selection over the cell's own box reads it whole.
        do {
            pieces = pieces.map { piece in
                let box = CGRect(x: piece.x0 - 0.5, y: rect.minY + rect.height * 0.3, width: piece.x1 - piece.x0 + 1, height: rect.height * 0.4)
                let read = (page.selection(for: box)?.string ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                return read.isEmpty ? piece : Piece(text: read, x0: piece.x0, x1: piece.x1)
            }
        }
        return pieces
    }

    private struct Style {
        var size: CGFloat
        var bold = false
        var italic = false
        var mono = false

        init(font: NSFont?, fallbackSize: CGFloat) {
            guard let font else { size = fallbackSize; return }
            size = font.pointSize
            let traits = font.fontDescriptor.symbolicTraits
            let name = font.fontName.lowercased()
            bold = traits.contains(.bold) || name.contains("bold") || name.contains("black") || name.contains("heavy") || name.contains("semibold")
            italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
            mono = traits.contains(.monoSpace) || name.contains("courier") || name.contains("mono") || name.contains("consolas")
        }
    }

    // MARK: Scanned pages

    private static func recognisedLines(on page: PDFPage, box: CGRect) -> [Line] {
        guard let image = try? PDFConvert.rasterize(page) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let found = request.results else { return [] }
        var lines: [Line] = []
        for observation in found {
            guard let candidate = observation.topCandidates(1).first, !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let b = observation.boundingBox
            let x0 = box.minX + b.minX * box.width
            let x1 = box.minX + b.maxX * box.width
            let bottom = box.minY + b.minY * box.height
            let top = box.minY + b.maxY * box.height
            let text = candidate.string
            lines.append(Line(runs: [StyledText(text: text)], pieces: [Piece(text: text, x0: x0, x1: x1)], x0: x0, x1: x1, top: top, bottom: bottom, size: (top - bottom) / 1.25, allBold: false))
        }
        return lines.sorted { abs($0.midY - $1.midY) > min($0.size, $1.size) * 0.5 ? $0.midY > $1.midY : $0.x0 < $1.x0 }
    }

    // MARK: Pictures

    private final class Scan {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var rects: [CGRect] = []
        var depth = 0
    }

    private static func pictures(on page: PDFPage, box: CGRect, hasText: Bool) -> [(ImageData, CGRect)] {
        guard page.rotation == 0, let ref = page.pageRef else { return [] }
        let scan = Scan()
        scanContent(CGPDFContentStreamCreateWithPage(ref), scan: scan)
        var found: [(ImageData, CGRect)] = []
        for raw in scan.rects {
            let rect = raw.intersection(box)
            if rect.width < 28 || rect.height < 28 { continue }
            // A picture the size of the page behind real text is a background, not content.
            if hasText, rect.width * rect.height > box.width * box.height * 0.85 { continue }
            if let data = crop(page, rect: rect) { found.append((data, rect)) }
            if found.count >= 40 { break }
        }
        return found
    }

    private static func scanContent(_ content: CGPDFContentStreamRef, scan: Scan) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info else { return }
            let scan = Unmanaged<Scan>.fromOpaque(info).takeUnretainedValue()
            scan.stack.append(scan.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info else { return }
            let scan = Unmanaged<Scan>.fromOpaque(info).takeUnretainedValue()
            if let last = scan.stack.popLast() { scan.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let info else { return }
            let scan = Unmanaged<Scan>.fromOpaque(info).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 6)
            for index in stride(from: 5, through: 0, by: -1) {
                guard CGPDFScannerPopNumber(scanner, &v[index]) else { return }
            }
            let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            scan.ctm = m.concatenating(scan.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let scan = Unmanaged<Scan>.fromOpaque(info).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            let content = CGPDFScannerGetContentStream(scanner)
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                scan.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(scan.ctm))
            case "Form":
                guard scan.depth < 4 else { return }
                var form = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { CGPDFArrayGetNumber(array, index, &v[index]) }
                    form = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                guard let resources else { return }
                let saved = (scan.ctm, scan.stack)
                scan.ctm = form.concatenating(scan.ctm)
                scan.stack = []
                scan.depth += 1
                PDFLayout.scanContent(CGPDFContentStreamCreateWithStream(stream, resources, content), scan: scan)
                scan.depth -= 1
                (scan.ctm, scan.stack) = saved
            default:
                break
            }
        }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(scan).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    /// Renders one rectangle of a page, which captures a picture exactly as the PDF shows it.
    private static func crop(_ page: PDFPage, rect: CGRect) -> ImageData? {
        let box = page.bounds(for: .mediaBox)
        let scale = max(1.5, min(3.0, 2000 / max(rect.width, rect.height, 1)))
        let width = max(1, Int((rect.width * scale).rounded()))
        let height = max(1, Int((rect.height * scale).rounded()))
        guard width * height < 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        _ = box
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        let big = rect.width > 150 && rect.height > 150
        guard let data = big ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) : rep.representation(using: .png, properties: [:]) else { return nil }
        return ImageData(data: data, width: Double(rect.width), height: Double(rect.height), ext: big ? "jpg" : "png")
    }

    private static func key(_ rect: CGRect) -> String {
        "\(Int(rect.minX / 4)),\(Int(rect.minY / 4)),\(Int(rect.width / 4)),\(Int(rect.height / 4))"
    }

    /// Logos and watermarks that repeat on most pages are decoration, so they stay out of the text flow.
    private static func repeatedImageKeys(_ pages: [[(image: ImageData, rect: CGRect)]]) -> Set<String> {
        guard pages.count >= 3 else { return [] }
        var counts: [String: Int] = [:]
        for page in pages { for item in Set(page.map { key($0.rect) }) { counts[item, default: 0] += 1 } }
        return Set(counts.filter { Double($0.value) >= Double(pages.count) * 0.6 }.keys)
    }

    // MARK: Headers, footers, page numbers

    private static func dropRepeatedMargins(_ pages: [[Line]], boxes: [CGRect]) -> [[Line]] {
        guard pages.count >= 2 else { return pages }
        func inMargin(_ line: Line, _ box: CGRect) -> Bool {
            line.midY > box.maxY - box.height * 0.09 || line.midY < box.minY + box.height * 0.09
        }
        func shape(_ line: Line) -> String {
            line.text.lowercased().replacingOccurrences(of: "\\d+", with: "#", options: .regularExpression)
        }
        var counts: [String: Int] = [:]
        for (index, lines) in pages.enumerated() {
            for text in Set(lines.filter { inMargin($0, boxes[index]) }.map(shape)) { counts[text, default: 0] += 1 }
        }
        let needed = max(2, Int((Double(pages.count) * 0.5).rounded(.up)))
        return pages.enumerated().map { index, lines in
            lines.filter { line in
                guard inMargin(line, boxes[index]) else { return true }
                let text = shape(line)
                if text == "#" || text.range(of: "^(page|p\\.|seite|página)\\s*#( of #| / #)?$", options: .regularExpression) != nil { return false }
                return (counts[text] ?? 0) < needed
            }
        }
    }

    // MARK: Paragraphs, headings, lists, tables

    private static func roundHalf(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    private static func bodySize(_ pages: [[Line]]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for lines in pages { for line in lines { weights[roundHalf(line.size), default: 0] += line.text.count } }
        return weights.max { $0.value < $1.value }?.key ?? 11
    }

    private static func isHeadingSize(_ line: Line, body: CGFloat) -> Bool {
        line.size >= body * 1.15 && line.text.count <= 160
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return true }
        return ".!?:;\u{201D}\")".contains(last)
    }

    private static func marker(of line: Line) -> (kind: BlockKind, rest: String)? {
        let text = line.text
        if let first = text.first, "•◦▪‣●■□○◆–—-*·".contains(first), text.dropFirst().first == " " {
            return (.bullet, String(text.dropFirst(2)))
        }
        if let match = text.range(of: "^(\\d{1,3})[.)]\\s+(?=\\S)", options: .regularExpression) {
            let digits = text[..<match.upperBound].filter(\.isNumber)
            return (.number(Int(digits) ?? 1), String(text[match.upperBound...]))
        }
        return nil
    }

    private static func joinRuns(_ a: [Run], _ b: [Run]) -> [Run] {
        guard var last = a.last, let first = b.first else { return a + b }
        var out = a
        if last.text.hasSuffix("-"), let start = first.text.first, start.isLowercase, last.text.dropLast().last?.isLetter == true {
            last.text.removeLast()
            out[out.count - 1] = last
        } else if !last.text.hasSuffix(" "), !first.text.hasPrefix(" ") {
            out.append(Run(text: " "))
        }
        return out + b
    }

    private static func runs(of line: Line, dropping prefix: Int = 0) -> [Run] {
        var skip = prefix
        return line.runs.compactMap { styled in
            var text = styled.text
            if skip > 0 {
                let cut = min(skip, text.count)
                text = String(text.dropFirst(cut))
                skip -= cut
            }
            guard !text.isEmpty else { return nil }
            return Run(text: text, bold: styled.bold && !line.allBold, italic: styled.italic, code: styled.mono)
        }
    }

    private static func assemble(_ lines: [Line], body: CGFloat, ranked: [CGFloat], box: CGRect) -> [Placed] {
        guard !lines.isEmpty else { return [] }
        let rightEdge = lines.map(\.x1).sorted()[Int(Double(lines.count - 1) * 0.9)]
        var out: [Placed] = []
        var index = 0

        var paragraph: (kind: BlockKind, runs: [Run], first: Line, last: Line, leftX: CGFloat, top: CGFloat)?
        func flush() {
            guard let open = paragraph else { return }
            paragraph = nil
            let trimmed = open.runs.filter { !$0.text.isEmpty }
            guard !trimmed.isEmpty else { return }
            out.append(Placed(block: Block(kind: open.kind, runs: trimmed), top: open.top))
        }

        while index < lines.count {
            let line = lines[index]

            // Tables: several consecutive lines split into aligned columns.
            if let (table, consumed) = table(from: lines, at: index, body: body) {
                flush()
                out.append(Placed(block: Block(kind: .table(table), runs: []), top: line.top))
                index += consumed
                continue
            }

            // Headings (a bigger font, or a short bold line standing alone).
            let sized = isHeadingSize(line, body: body)
            let boldAlone = line.allBold && line.text.count <= 100 && !endsSentence(line.text) && line.size >= body * 0.95 && marker(of: line) == nil
            if sized || boldAlone {
                flush()
                var heading = runs(of: line).map { Run(text: $0.text) }
                var last = line
                var next = index + 1
                // A heading that wraps onto a second line is still one heading.
                while next < lines.count, lines[next].size == line.size || abs(lines[next].size - line.size) < 0.6, lines[next].allBold == line.allBold,
                      last.midY - lines[next].midY < line.size * 1.6, abs(lines[next].x0 - line.x0) < line.size * 2, (sized || lines[next].allBold), lines[next].text.count <= 100 {
                    heading = joinRuns(heading, runs(of: lines[next]).map { Run(text: $0.text) })
                    last = lines[next]
                    next += 1
                }
                let rank = ranked.firstIndex(of: roundHalf(line.size))
                let level = sized ? min((rank ?? 0) + 1, 4) : min(ranked.count + 1, 4)
                out.append(Placed(block: Block(kind: .heading(level), runs: heading), top: line.top))
                index = next
                continue
            }

            // List items.
            if let (kind, rest) = marker(of: line) {
                flush()
                let prefixLength = line.text.count - rest.count
                paragraph = (kind, runs(of: line, dropping: prefixLength), line, line, line.x0 + line.size * 1.2, line.top)
                index += 1
                continue
            }

            if var open = paragraph {
                let advance = open.last.midY - line.midY
                let sameBlock = advance > 0 && advance <= max(open.last.size, line.size) * 1.75
                let aligned = min(abs(line.x0 - open.first.x0), abs(line.x0 - open.leftX)) <= max(line.size, 8) * 1.5
                let isList: Bool = { if case .bullet = open.kind { return true }; if case .number = open.kind { return true }; return false }()
                let indentedUnderItem = isList && line.x0 > open.first.x0 + 2
                let previousEndedShort = open.last.x1 < rightEdge - body * 3 && endsSentence(open.last.text) && !isList
                let continues = isList ? (line.x0 > open.first.x0 + max(line.size * 0.8, 6)) : aligned
                if sameBlock, continues, !previousEndedShort || line.x0 > open.first.x0 + body * 3 {
                    open.runs = joinRuns(open.runs, runs(of: line))
                    if open.first.x0 == open.last.x0 && open.first.midY == open.last.midY { open.leftX = line.x0 }
                    open.last = line
                    paragraph = open
                    index += 1
                    continue
                }
                flush()
            }
            paragraph = (.paragraph, runs(of: line), line, line, line.x0, line.top)
            index += 1
        }
        flush()
        return out
    }

    /// Looks for a table starting at `start`: at least three lines in a row, each split into the same few columns.
    private static func table(from lines: [Line], at start: Int, body: CGFloat) -> (TableData, Int)? {
        func cells(_ line: Line) -> Bool { line.pieces.count >= 2 && line.pieces.count <= 12 }
        guard cells(lines[start]) else { return nil }
        var end = start
        while end < lines.count, cells(lines[end]) || (end > start && continuation(lines[end], after: lines[end - 1], size: body)) { end += 1 }
        let rows = Array(lines[start..<end])
        guard rows.filter(cells).count >= 3 else { return nil }
        var anchors: [CGFloat] = []
        for x in rows.filter(cells).flatMap({ $0.pieces.map(\.x0) }).sorted() {
            if let last = anchors.last, x - last < 9 { continue }
            anchors.append(x)
        }
        guard anchors.count >= 2, anchors.count <= 12 else { return nil }
        let cellLines = rows.filter(cells)
        // A column of bullets or numbers beside text is a list, not a table.
        let listy = cellLines.filter { line in
            guard let first = line.pieces.first?.text else { return false }
            return first.count <= 4 && (first.range(of: "^(\\d{1,3}[.)]|[•◦▪‣●·–\\-*])$", options: .regularExpression) != nil)
        }.count
        guard Double(listy) < Double(cellLines.count) * 0.6 else { return nil }
        let lengths = cellLines.flatMap { $0.pieces.map { $0.text.count } }
        guard Double(lengths.reduce(0, +)) / Double(max(lengths.count, 1)) < 48, (lengths.max() ?? 0) < 120 else { return nil }
        // Columns must actually line up: most pieces start at (nearly) an anchor.
        let aligned = cellLines.flatMap(\.pieces).filter { piece in anchors.contains { abs($0 - piece.x0) < 9 } }.count
        guard Double(aligned) >= Double(cellLines.flatMap(\.pieces).count) * 0.55 else { return nil }

        func column(of x: CGFloat) -> Int {
            var best = 0
            for (index, anchor) in anchors.enumerated() where anchor <= x + 9 { best = index }
            return best
        }
        var grid: [[String]] = []
        for row in rows {
            if cells(row) {
                var out = Array(repeating: "", count: anchors.count)
                for piece in row.pieces {
                    let c = column(of: piece.x0)
                    out[c] = out[c].isEmpty ? piece.text : out[c] + " " + piece.text
                }
                grid.append(out)
            } else if var last = grid.popLast() {
                // A wrapped cell: the continuation joins the cell above it.
                let c = column(of: row.x0)
                last[c] = last[c].isEmpty ? row.text : last[c] + " " + row.text
                grid.append(last)
            }
        }
        let headerBold = rows.first?.allBold ?? false
        return (TableData(rows: grid, header: headerBold || grid.count > 1), end - start)
    }

    private static func continuation(_ line: Line, after previous: Line, size: CGFloat) -> Bool {
        line.pieces.count == 1 && previous.midY - line.midY <= max(previous.size, line.size) * 1.3 && line.text.count < 40 && line.x1 - line.x0 < 140
    }
}
