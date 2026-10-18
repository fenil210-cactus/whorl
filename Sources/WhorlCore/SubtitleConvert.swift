import Foundation

enum SubtitleConvert {
    static func convert(input: URL, to format: Format) throws -> URL {
        let text = try DocConvert.readText(input).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        let cues = parse(text)
        guard !cues.isEmpty else { throw ConvertError.failed("No subtitles found in \(input.lastPathComponent)") }
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension)
        try render(cues, as: format).write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    struct Cue {
        var start: String
        var end: String
        var lines: [String]
    }

    static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = clock(parts[0]), let end = clock(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]) else { continue }
            cues.append(Cue(start: start, end: end, lines: Array(lines[(timing + 1)...])))
        }
        return cues
    }

    /// Normalises "1:02,5" or "00:00:01.500" to "HH:MM:SS.mmm".
    private static func clock(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let split = text.components(separatedBy: ".")
        let millis = String((split.count > 1 ? split[1] : "0").prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        let units = split[0].components(separatedBy: ":").compactMap { Int($0) }
        guard (2...3).contains(units.count) else { return nil }
        let padded = units.count == 2 ? [0] + units : units
        return String(format: "%02d:%02d:%02d.%@", padded[0], padded[1], padded[2], millis)
    }

    static func render(_ cues: [Cue], as format: Format) -> String {
        var out = format == .vtt ? "WEBVTT\n\n" : ""
        for (index, cue) in cues.enumerated() {
            let stamp = format == .vtt ? "\(cue.start) --> \(cue.end)" : "\(cue.start.replacingOccurrences(of: ".", with: ",")) --> \(cue.end.replacingOccurrences(of: ".", with: ","))"
            out += "\(index + 1)\n\(stamp)\n\(cue.lines.joined(separator: "\n"))\n\n"
        }
        return out
    }
}
