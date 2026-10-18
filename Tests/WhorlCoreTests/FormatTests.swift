import Foundation
import Testing
@testable import WhorlCore

@Suite struct MarkdownTests {
    @Test func readsBlocks() {
        let doc = MarkdownParser.parse("# Title\n\nHello **bold** and *it*.\n\n- a\n- b\n\n1. one\n2. two\n\n> quote\n")
        let kinds = doc.blocks.map(\.kind)
        #expect(kinds == [.heading(1), .paragraph, .bullet, .bullet, .number(1), .number(2), .quote])
        #expect(doc.title == "Title")
        #expect(doc.blocks[1].runs.contains { $0.bold && $0.text == "bold" })
        #expect(doc.blocks[1].runs.contains { $0.italic && $0.text == "it" })
    }

    @Test func snakeCaseAndMathAreNotItalics() {
        let runs = MarkdownParser.inline("use my_var_name and 3 * 4 * 5")
        #expect(runs.map(\.text).joined() == "use my_var_name and 3 * 4 * 5")
        #expect(!runs.contains { $0.italic })
    }

    @Test func keepsLinks() {
        let runs = MarkdownParser.inline("see [the docs](https://example.com/a_b) now")
        #expect(runs.contains { $0.link == "https://example.com/a_b" && $0.text == "the docs" })
    }

    @Test func roundTripsThroughMarkdown() {
        let source = "# Title\n\nSome **bold** text.\n\n## Part\n\n- one\n- two\n\n1. first\n2. second\n"
        let again = DocWriter.markdown(MarkdownParser.parse(source))
        #expect(again == source)
    }

    @Test func htmlEscapesAndKeepsStructure() {
        let html = DocWriter.htmlBody(MarkdownParser.parse("# A & B\n\n- x < y\n"))
        #expect(html.contains("<h1>A &amp; B</h1>"))
        #expect(html.contains("<li>x &lt; y</li>"))
    }

    @Test func readsHTMLBack() {
        let doc = HTMLParser.parse("<html><head><title>T</title></head><body><h2>Head</h2><p>One <b>two</b> &amp; three</p><ul><li>a</li><li>b</li></ul></body></html>")
        #expect(doc.title == "T")
        #expect(doc.blocks.map(\.kind) == [.heading(2), .paragraph, .bullet, .bullet])
        #expect(doc.blocks[1].plain == "One two & three")
    }
}

@Suite struct SheetTests {
    @Test func parsesQuotedFields() {
        let table = Delimited.parse("a,b\n\"x, y\",\"he said \"\"hi\"\"\"\n\"line\nbreak\",z\n", delimiter: ",")
        #expect(table == [["a", "b"], ["x, y", "he said \"hi\""], ["line\nbreak", "z"]])
    }

    @Test func writesWhatItParses() {
        let table: Table = [["a", "b,c"], ["he said \"hi\"", "line\nbreak"]]
        #expect(Delimited.parse(Delimited.write(table, delimiter: ","), delimiter: ",") == table)
        #expect(Delimited.parse(Delimited.write(table, delimiter: "\t"), delimiter: "\t") == table)
    }

    @Test func handlesWindowsLineEndingsAndBOM() {
        let table = Delimited.parse("\u{FEFF}a,b\r\n1,2\r\n", delimiter: ",")
        #expect(table == [["a", "b"], ["1", "2"]])
    }

    @Test func xlsxAndOdsRoundTrip() throws {
        let dir = try scratch()
        let table: Table = [["name", "qty", "note"], ["Apples", "3", "fresh, red"], ["007", "1", ""], ["Café ☕", "2.50", "a & b <c>"]]
        let xlsx = dir.appendingPathComponent("t.xlsx")
        let ods = dir.appendingPathComponent("t.ods")
        try XLSX.write(table, to: xlsx)
        try ODS.write(table, to: ods)
        let fromXLSX = try XLSX.read(xlsx)
        let fromODS = try ODS.read(ods)
        // Trailing empty cells are not stored, so compare with them trimmed.
        func trimmed(_ t: Table) -> Table { t.map { row in var r = row; while r.last == "" { r.removeLast() }; return r } }
        #expect(fromXLSX == trimmed(table))
        #expect(fromODS == trimmed(table))
    }
}

@Suite struct SubtitleTests {
    private let srt = "1\n00:00:01,000 --> 00:00:03,500\nHello\n\n2\n00:01:04,000 --> 00:01:06,250\nTwo\nlines\n"

    @Test func srtToVttAndBack() throws {
        let cues = SubtitleConvert.parse(srt)
        #expect(cues.count == 2)
        let vtt = SubtitleConvert.render(cues, as: .vtt)
        #expect(vtt.hasPrefix("WEBVTT"))
        #expect(vtt.contains("00:00:01.000 --> 00:00:03.500"))
        let back = SubtitleConvert.render(SubtitleConvert.parse(vtt), as: .srt)
        #expect(back.contains("00:01:04,000 --> 00:01:06,250"))
        #expect(back.contains("Two\nlines"))
    }

    @Test func shortVttTimestampsAndCueSettings() {
        let vtt = "WEBVTT\n\nNOTE a comment\n\n01:02.500 --> 01:04.000 align:start position:0%\nHi\n"
        let cues = SubtitleConvert.parse(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].start == "00:01:02.500")
        #expect(cues[0].end == "00:01:04.000")
    }
}

func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whorl-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
