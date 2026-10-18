import CoreGraphics
import Foundation
import Testing
@testable import WhorlCore

@Suite struct WheelMathTests {
    private let center = CGPoint(x: 200, y: 200)

    @Test func firstWedgeIsCenteredAtTwelveOClock() {
        // Four wedges: top, right, bottom, left, each centred on its compass point.
        let radius = (Wheel.innerRadius + Wheel.outerRadius) / 2
        #expect(Wheel.index(center: center, point: CGPoint(x: 200, y: 200 + radius), count: 4) == 0)
        #expect(Wheel.index(center: center, point: CGPoint(x: 200 + radius, y: 200), count: 4) == 1)
        #expect(Wheel.index(center: center, point: CGPoint(x: 200, y: 200 - radius), count: 4) == 2)
        #expect(Wheel.index(center: center, point: CGPoint(x: 200 - radius, y: 200), count: 4) == 3)
    }

    @Test func slightlyLeftOfTopStillBelongsToTheFirstWedge() {
        let radius = (Wheel.innerRadius + Wheel.outerRadius) / 2
        #expect(Wheel.index(center: center, point: CGPoint(x: 200 - radius * 0.2, y: 200 + radius), count: 8) == 0)
        #expect(Wheel.index(center: center, point: CGPoint(x: 200 + radius * 0.2, y: 200 + radius), count: 8) == 0)
    }

    @Test func holeAndOutsideAreNotWedges() {
        #expect(Wheel.index(center: center, point: CGPoint(x: 200, y: 230), count: 4) == nil)
        #expect(Wheel.index(center: center, point: CGPoint(x: 200 + Wheel.outerRadius + 5, y: 200), count: 4) == nil)
        #expect(Wheel.index(center: center, point: CGPoint(x: 200, y: 280), count: 0) == nil)
    }

    @Test func everyWedgeIsReachable() {
        for count in 1...12 {
            var seen = Set<Int>()
            for step in 0..<360 {
                let angle = Double(step) * .pi / 180
                let r = Double(Wheel.innerRadius + Wheel.outerRadius) / 2
                let point = CGPoint(x: 200 + r * cos(angle), y: 200 + r * sin(angle))
                if let index = Wheel.index(center: center, point: point, count: count) { seen.insert(index) }
            }
            #expect(seen == Set(0..<count), "count \(count)")
        }
    }
}

@Suite struct OutputNameTests {
    @Test func sitsBesideTheOriginal() {
        let input = URL(fileURLWithPath: "/tmp/shot.png")
        let url = OutputNames.url(beside: input, fileExtension: "jpg", existing: { _ in false })
        #expect(url.path == "/tmp/shot.jpg")
    }

    @Test func numbersInsteadOfOverwriting() {
        let input = URL(fileURLWithPath: "/tmp/shot.png")
        let taken: Set<String> = ["/tmp/shot.jpg", "/tmp/shot 2.jpg"]
        let url = OutputNames.url(beside: input, fileExtension: "jpg", existing: { taken.contains($0) })
        #expect(url.lastPathComponent == "shot 3.jpg")
    }

    @Test func sameExtensionGetsATag() {
        let input = URL(fileURLWithPath: "/tmp/shot.png")
        #expect(OutputNames.url(beside: input, fileExtension: "png", existing: { _ in false }).lastPathComponent == "shot converted.png")
        #expect(OutputNames.url(beside: input, fileExtension: "png", tag: "compressed", existing: { _ in false }).lastPathComponent == "shot compressed.png")
    }
}

@Suite struct CatalogTests {
    @Test func mixedImageTypesShareTargets() {
        let targets = Catalog.convertTargets(extensions: ["heic", "png"], engines: .none)
        #expect(targets.contains(.jpeg))
        // PNG stays offered: the HEIC can become a PNG while the PNG is skipped.
        #expect(targets.contains(.png))
        #expect(!Catalog.convertTargets(extensions: ["png"], engines: .none).contains(.png))
    }

    @Test func aliasesAreTreatedAsTheSameFormat() {
        #expect(Catalog.normalizedExtension("JPEG") == "jpg")
        #expect(Catalog.normalizedExtension("tif") == "tiff")
        #expect(Catalog.normalizedExtension("tgz") == "gz")
        #expect(!Catalog.convertTargets(extensions: ["jpeg"], engines: .none).contains(.jpeg))
    }

    @Test func missingToolsHideTheirFormats() {
        let without = Catalog.convertTargets(extensions: ["mp4"], engines: .none)
        let with = Catalog.convertTargets(extensions: ["mp4"], engines: Engines(ffmpeg: true))
        #expect(!without.contains(.mkv))
        #expect(with.contains(.mkv))
        #expect(without.contains(.mov))
        #expect(without.contains(.gif))
    }

    @Test func nothingIsOfferedThatNeedsASlidesEngine() {
        #expect(Catalog.convertTargets(extensions: ["pptx"], engines: .none).isEmpty)
        #expect(Catalog.convertTargets(extensions: ["pptx"], engines: Engines(libreOffice: true)).contains(.pdf))
        #expect(Catalog.unavailableReason(extensions: ["pptx"], engines: .none)?.contains("LibreOffice") == true)
    }

    @Test func unknownFilesExplainThemselves() {
        #expect(Catalog.convertTargets(extensions: ["xyz"], engines: .none).isEmpty)
        #expect(Catalog.unavailableReason(extensions: ["xyz"], engines: .none) != nil)
    }

    @Test func toolsMatchTheFileKind() {
        #expect(Catalog.toolTargets(extensions: ["pdf"]).contains(.split))
        #expect(!Catalog.toolTargets(extensions: ["png"]).contains(.split))
        #expect(Catalog.toolTargets(extensions: ["png", "jpg"]).contains(.compress))
        #expect(Catalog.toolTargets(extensions: ["docx"]).isEmpty)
    }

    @Test func actionsAlwaysOfferTheSixActions() {
        let wedges = Catalog.wedges(extensions: ["anything"], mode: .actions, engines: .none)
        #expect(wedges.count == FileAction.allCases.count)
    }

    @Test func outputsNeverContainDuplicates() {
        for ext in ["png", "mp4", "wav", "pdf", "docx", "xlsx", "srt", "zip", "pptx"] {
            let targets = Catalog.convertTargets(extensions: [ext], engines: .everything)
            #expect(Set(targets).count == targets.count, "\(ext)")
        }
    }
}
