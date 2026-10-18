import CoreGraphics
import Foundation

public enum Wheel {
    public static let innerRadius: CGFloat = 58
    public static let outerRadius: CGFloat = 150

    /// Wedge 0 is centred at 12 o'clock. Later wedges continue clockwise.
    /// `point` uses y-up coordinates, matching AppKit views.
    public static func index(center: CGPoint, point: CGPoint, count: Int, inner: CGFloat = innerRadius, outer: CGFloat = outerRadius) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= inner, distance <= outer else { return nil }
        let slice = (2 * Double.pi) / Double(count)
        var clockwiseFromTop = (Double.pi / 2) - atan2(dy, dx) + slice / 2
        clockwiseFromTop = clockwiseFromTop.truncatingRemainder(dividingBy: 2 * Double.pi)
        if clockwiseFromTop < 0 { clockwiseFromTop += 2 * Double.pi }
        return min(Int(clockwiseFromTop / slice), count - 1)
    }

    /// AppKit degrees (0 = 3 o'clock, counter-clockwise positive) of the clockwise-leading edge of wedge `index`.
    public static func angle(index: Int, count: Int) -> CGFloat {
        let slice = 360 / CGFloat(max(count, 1))
        return 90 + slice / 2 - CGFloat(index) * slice
    }
}

public enum OutputNames {
    /// Output lands beside the input. If that folder is read-only, it goes to Downloads instead.
    public static func url(beside input: URL, fileExtension: String, tag: String = "converted", existing: ((String) -> Bool)? = nil) -> URL {
        let exists = existing ?? { FileManager.default.fileExists(atPath: $0) }
        var directory = input.deletingLastPathComponent()
        if existing == nil, !FileManager.default.isWritableFile(atPath: directory.path),
           let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            directory = downloads
        }
        let base = input.deletingPathExtension().lastPathComponent
        func candidate(_ name: String) -> URL {
            directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        }
        var url = candidate(base)
        if url.path == input.path { url = candidate("\(base) \(tag)") }
        var number = 2
        let stem = url.deletingPathExtension().lastPathComponent
        while exists(url.path) {
            url = candidate("\(stem) \(number)")
            number += 1
        }
        return url
    }
}
