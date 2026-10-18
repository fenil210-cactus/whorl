import AppKit
import Foundation
import Testing
@testable import WhorlCore

/// Documents survive the trip between formats with their structure, not just their words.
@Suite struct DocumentQuality {
    private let source = """
    # Quarterly Report

    This report covers **revenue** and *costs* for the quarter.

    ## Highlights

    - Revenue up
    - Churn down

    ## Numbers

    | Region | Q1 | Q2 |
    | --- | --- | --- |
    | North | 1,200 | 1,410 |
    | South | 980 | 1,020 |
    | East | 1,540 | 1,610 |

    1. First step
    2. Second step

    Closing paragraph after the list.
    """

    private func convert(_ url: URL, to format: Format) throws -> URL {
        try DocConvert.convert(input: url, to: format, engines: Engines.current)
    }

    private func markdown(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func start() throws -> URL {
        let md = try scratch().appendingPathComponent("report.md")
        try source.write(to: md, atomically: true, encoding: .utf8)
        return md
    }

    @Test func docxKeepsTablesListsAndHeadings() throws {
        let docx = try convert(try start(), to: .docx)
        let back = try markdown(try convert(docx, to: .md))
        #expect(back.contains("# Quarterly Report"))
        #expect(back.contains("## Numbers"))
        #expect(back.contains("| North | 1,200 | 1,410 |"))
        #expect(back.contains("- Revenue up"))
        #expect(back.contains("1. First step"))
        #expect(back.contains("**revenue**"))
    }

    @Test func pdfReadingRebuildsStructure() throws {
        let pdf = try convert(try start(), to: .pdf)
        let back = try markdown(try convert(pdf, to: .md))
        #expect(back.contains("# Quarterly Report"), "\(back)")
        #expect(back.contains("| Region | Q1 | Q2 |"), "\(back)")
        #expect(back.contains("| South | 980 | 1,020 |"), "\(back)")
        #expect(back.contains("- Revenue up"), "\(back)")
        #expect(back.contains("2. Second step\n\nClosing paragraph"), "\(back)")
    }

    @Test func picturesTravelThroughPdf() throws {
        let dir = try scratch()
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("pic.png"))
        let html = dir.appendingPathComponent("pic.html")
        try "<h1>Photo</h1><p>Before text goes here.</p><p><img src=\"pic.png\"></p><p>After text goes here.</p>".write(to: html, atomically: true, encoding: .utf8)
        let pdf = try convert(html, to: .pdf)
        let md = try convert(pdf, to: .md)
        let text = try markdown(md)
        #expect(text.contains("!["), "\(text)")
        let folder = dir.appendingPathComponent("pic-images")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(!files.isEmpty)
    }

    @Test func markdownImagesAreEmbedded() throws {
        let dir = try scratch()
        let image = NSImage(size: NSSize(width: 60, height: 40), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("b.png"))
        let md = dir.appendingPathComponent("doc.md")
        try "# T\n\n![blue](b.png)\n\nText\n".write(to: md, atomically: true, encoding: .utf8)
        let doc = try DocConvert.load(md)
        let hasImage = doc.blocks.contains { if case .image = $0.kind { return true } else { return false } }
        #expect(hasImage)
    }
}
