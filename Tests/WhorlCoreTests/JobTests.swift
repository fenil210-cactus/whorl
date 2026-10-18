import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WhorlCore

/// The promise of the app: whatever the wheel or window offers for a file, converting to it works.
@Suite struct OfferedRoutesWork {
    private func makeFixtures() throws -> [String: URL] {
        let dir = try scratch()
        var files: [String: URL] = [:]
        func put(_ name: String, _ text: String) throws {
            let url = dir.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            files[(name as NSString).pathExtension] = url
        }
        try put("a.md", "# Title\n\nHello **world**\n\n- one\n- two\n")
        try put("a.txt", "Hello\n\nWorld\n")
        try put("a.csv", "x,y\n1,\"two, three\"\n")
        try put("a.srt", "1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        try put("a.html", "<html><body><h1>Hi</h1><p>there</p></body></html>")
        files["png"] = try writePNG(dir.appendingPathComponent("a.png"))
        files["wav"] = try writeWAV(dir.appendingPathComponent("a.wav"))
        let pack = dir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try "x".write(to: pack.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("pack.zip")
        try Shell.run("/usr/bin/ditto", ["-c", "-k", pack.path, zip.path])
        files["zip"] = zip
        return files
    }

    @Test func everyAdvertisedTargetConverts() throws {
        let engines = Engines.current
        let fixtures = try makeFixtures()
        var checked = 0
        for (ext, url) in fixtures.sorted(by: { $0.key < $1.key }) {
            for format in Catalog.convertTargets(extensions: [ext], engines: engines) {
                // Work on a copy so earlier outputs do not change names.
                let dir = try scratch()
                let copy = dir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                let result = Jobs.run(.convert(format), inputs: [copy], engines: engines)
                #expect(result.failures.isEmpty, "\(ext) → \(format.label): \(result.failures.first?.message ?? "")")
                #expect(!result.outputs.isEmpty, "\(ext) → \(format.label) produced nothing")
                for output in result.outputs {
                    let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    #expect(size > 0, "\(ext) → \(format.label) wrote an empty file")
                    #expect(output.deletingLastPathComponent().path == dir.path, "output must sit beside the original")
                }
                checked += 1
            }
        }
        #expect(checked > 30)
    }

    @Test func offeredToolsWork() throws {
        let fixtures = try makeFixtures()
        let dir = try scratch()
        let png = dir.appendingPathComponent("p.png")
        try FileManager.default.copyItem(at: fixtures["png"]!, to: png)
        for tool in Catalog.toolTargets(extensions: ["png"]) {
            let result = Jobs.run(.tool(tool), inputs: [png])
            // "Already as small as possible" is an honest answer for compress on a tiny image.
            let honest = result.failures.allSatisfy { $0.message.contains("already as small") }
            #expect(honest, "\(tool.label): \(result.failures.first?.message ?? "")")
        }
    }

    @Test func originalsAreNeverTouched() throws {
        let fixtures = try makeFixtures()
        let png = fixtures["png"]!
        let before = try Data(contentsOf: png)
        _ = Jobs.run(.convert(.jpeg), inputs: [png])
        _ = Jobs.run(.tool(.metadata), inputs: [png])
        #expect(try Data(contentsOf: png) == before)
    }

    @Test func oneBadFileDoesNotStopTheBatch() throws {
        let fixtures = try makeFixtures()
        let dir = try scratch()
        let junk = dir.appendingPathComponent("junk.png")
        try Data("not an image".utf8).write(to: junk)
        let result = Jobs.run(.convert(.jpeg), inputs: [junk, fixtures["png"]!])
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.file == "junk.png")
        #expect(result.outputs.count == 1)
    }

    @Test func unsupportedRoutesAreRefusedWithAReason() throws {
        let fixtures = try makeFixtures()
        let result = Jobs.run(.convert(.mkv), inputs: [fixtures["wav"]!], engines: .none)
        #expect(result.failures.count == 1)
        #expect(!result.outputs.contains { $0.pathExtension == "mkv" })
    }

    @Test func cancellationStopsBetweenFiles() throws {
        let fixtures = try makeFixtures()
        let result = Jobs.run(.convert(.jpeg), inputs: [fixtures["png"]!, fixtures["png"]!], isCancelled: { true })
        #expect(result.cancelled)
        #expect(result.outputs.isEmpty)
    }

    @Test func alreadyInTheTargetFormatIsSkippedNotRewritten() throws {
        let fixtures = try makeFixtures()
        let result = Jobs.run(.convert(.png), inputs: [fixtures["png"]!])
        #expect(result.outputs.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test func phonePhotosComeOutUpright() throws {
        // A 40×20 image tagged "rotate 90° clockwise" must become 20×40 pixels.
        let dir = try scratch()
        let source = dir.appendingPathComponent("tagged.jpg")
        guard let dest = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        let image = try makeImage(width: 40, height: 20)
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let outputs = try Jobs.convert(inputs: [source], to: .png)
        let loaded = try ImageConvert.load(outputs[0])
        #expect(loaded.width == 20 && loaded.height == 40)
    }

    @Test func transparentImagesBecomeWhiteJPEGsNotBlack() throws {
        let dir = try scratch()
        let png = dir.appendingPathComponent("clear.png")
        try writeTransparentPNG(png)
        let jpg = try Jobs.convert(inputs: [png], to: .jpeg)[0]
        let image = try ImageConvert.load(jpg)
        let pixel = try firstPixel(image)
        #expect(pixel.0 > 240 && pixel.1 > 240 && pixel.2 > 240, "expected white, got \(pixel)")
    }

    @Test func markdownBecomesRealDocuments() throws {
        let fixtures = try makeFixtures()
        let docx = try Jobs.convert(inputs: [fixtures["md"]!], to: .docx)[0]
        let back = try DocConvert.load(docx)
        #expect(back.blocks.map(\.plain).contains("Title"))
        #expect(back.blocks.contains { $0.kind == .bullet && $0.plain == "one" })
        let pdf = try Jobs.convert(inputs: [fixtures["md"]!], to: .pdf)[0]
        #expect(PDFConvert.plainText(pdf).contains("Hello world"))
    }
}

// MARK: - Fixture writers

private func makeImage(width: Int, height: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw ConvertError.failed("context") }
    context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw ConvertError.failed("image") }
    return image
}

@discardableResult
private func writePNG(_ url: URL) throws -> URL {
    try ImageConvert.save(try makeImage(width: 64, height: 48), to: url, format: .png, quality: 1, engines: .none)
    return url
}

private func writeTransparentPNG(_ url: URL) throws {
    guard let context = CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else { throw ConvertError.failed("context") }
    try ImageConvert.save(image, to: url, format: .png, quality: 1, engines: .none)
}

private func firstPixel(_ image: CGImage) throws -> (Int, Int, Int) {
    guard let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ), let data = context.data else { throw ConvertError.failed("pixel") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
}

/// 0.3 s of 16-bit mono silence at 22.05 kHz.
@discardableResult
private func writeWAV(_ url: URL) throws -> URL {
    let samples = 6615
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(22050); u32(44100); u16(2); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
    data.append(Data(count: samples * 2))
    try data.write(to: url)
    return url
}
