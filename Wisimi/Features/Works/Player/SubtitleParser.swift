import Foundation

struct SubtitleLine: Identifiable, Hashable {
    let id = UUID()
    let start: TimeInterval
    var end: TimeInterval
    let text: String
}

enum SubtitleParser {
    static func parse(_ content: String) -> [SubtitleLine] {
        content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
            ? parseVTT(content)
            : parseLRC(content)
    }

    private static func parseVTT(_ content: String) -> [SubtitleLine] {
        let blocks = content.components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            guard let timing = lines.first(where: { $0.contains("-->") }) else { return nil }
            let parts = timing.components(separatedBy: "-->")
            guard parts.count == 2, let start = parseTimestamp(parts[0]), let end = parseTimestamp(parts[1]) else { return nil }
            let text = lines.drop(while: { !$0.contains("-->") }).dropFirst().joined(separator: "\n")
            return text.isEmpty ? nil : SubtitleLine(start: start, end: end, text: text)
        }
    }

    private static func parseLRC(_ content: String) -> [SubtitleLine] {
        let regex = try? NSRegularExpression(pattern: #"\[(\d{2}):(\d{2})\.(\d{2})\]"#)
        var lines: [SubtitleLine] = []

        for row in content.components(separatedBy: .newlines) {
            let range = NSRange(row.startIndex..<row.endIndex, in: row)
            let matches = regex?.matches(in: row, range: range) ?? []
            let text = regex?.stringByReplacingMatches(in: row, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !matches.isEmpty, !text.isEmpty else { continue }
            for match in matches {
                guard let minutes = Int(row[match.range(at: 1)]),
                      let seconds = Int(row[match.range(at: 2)]),
                      let centiseconds = Int(row[match.range(at: 3)]) else { continue }
                let start = Double(minutes * 60 + seconds) + Double(centiseconds) / 100
                lines.append(SubtitleLine(start: start, end: start + 5, text: text))
            }
        }

        lines.sort { $0.start < $1.start }
        for index in lines.indices.dropLast() {
            lines[index].end = lines[index + 1].start
        }
        return lines
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").first ?? raw
        let parts = cleaned.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2 else { return nil }
        let secondsPart = parts.last?.split(separator: ".") ?? []
        guard let secondsText = secondsPart.first, let seconds = Double(secondsText) else { return nil }
        let fraction = secondsPart.dropFirst().first.map { Double("0.\($0)") ?? 0 } ?? 0
        let minutes = Double(parts[parts.count - 2]) ?? 0
        let hours = parts.count == 3 ? (Double(parts[0]) ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds + fraction
    }
}

private extension String {
    subscript(_ range: NSRange) -> String {
        guard let range = Range(range, in: self) else { return "" }
        return String(self[range])
    }
}
