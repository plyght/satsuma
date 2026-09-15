import Foundation

struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleParser {
    static func parse(_ text: String, hint: FileFormat) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if hint == .vtt || lines.first?.hasPrefix("WEBVTT") == true {
            lines = Array(lines.drop { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.contains("-->") }.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
        var cues: [SubtitleCue] = []
        var index = 0
        var sawTimecode = false
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                sawTimecode = true
                let parts = line.components(separatedBy: "-->")
                let start = parseTimestamp(parts[0]) ?? 0
                let endToken = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "" : ""
                let end = parseTimestamp(endToken) ?? start
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    body.append(lines[index])
                    index += 1
                }
                cues.append(SubtitleCue(start: start, end: end, text: body.joined(separator: "\n")))
            } else {
                index += 1
            }
        }
        if !sawTimecode {
            return plainTextCues(normalized)
        }
        return cues
    }

    static func plainTextCues(_ text: String) -> [SubtitleCue] {
        let blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let source = blocks.isEmpty ? text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } : blocks
        var cues: [SubtitleCue] = []
        var clock = 0.0
        for block in source {
            let words = block.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
            let duration = max(1.5, min(8, Double(words) * 0.35))
            cues.append(SubtitleCue(start: clock, end: clock + duration, text: block))
            clock += duration
        }
        return cues
    }

    static func parseTimestamp(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func format(_ seconds: Double, separator: String) -> String {
        let clamped = max(0, seconds)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let secs = Int(clamped) % 60
        let millis = Int(((clamped - Double(Int(clamped))) * 1000).rounded())
        return String(format: "%02d:%02d:%02d\(separator)%03d", hours, minutes, secs, min(millis, 999))
    }

    static func serialize(_ cues: [SubtitleCue], as format: FileFormat) -> String {
        switch format {
        case .vtt:
            var output = "WEBVTT\n\n"
            for cue in cues {
                output += "\(SubtitleParser.format(cue.start, separator: ".")) --> \(SubtitleParser.format(cue.end, separator: "."))\n\(cue.text)\n\n"
            }
            return output
        case .srt:
            var output = ""
            for (index, cue) in cues.enumerated() {
                output += "\(index + 1)\n\(SubtitleParser.format(cue.start, separator: ",")) --> \(SubtitleParser.format(cue.end, separator: ","))\n\(cue.text)\n\n"
            }
            return output
        default:
            return cues.map { stripTags($0.text) }.joined(separator: "\n\n") + "\n"
        }
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
    }
}

struct SubtitleEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .subtitle && (to.category == .subtitle || to == .txt)
    }

    func convert(_ request: ConversionRequest) async throws {
        let text = try TextFile.read(request.source)
        let cues = SubtitleParser.parse(text, hint: request.sourceFormat)
        let output = SubtitleParser.serialize(cues, as: request.target)
        try output.write(to: request.destination, atomically: true, encoding: .utf8)
        request.progress(1)
    }
}
