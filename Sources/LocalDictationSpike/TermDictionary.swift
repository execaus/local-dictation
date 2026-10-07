import Foundation

struct TermRule: Codable, Equatable {
    let spoken: String
    let written: String
}

enum TermDictionary {
    static func apply(_ rules: [TermRule], to text: String) -> String {
        // Longest source first avoids a short term consuming part of a longer one.
        let sorted = rules.filter { !$0.spoken.isEmpty }
            .sorted { $0.spoken.count > $1.spoken.count }
        var result = text
        for rule in sorted {
            let escaped = NSRegularExpression.escapedPattern(for: rule.spoken)
            let pattern = "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            // Replacement strings can contain "$" and backslashes, so apply by range.
            let matches = regex.matches(in: result, range: range)
            for match in matches.reversed() {
                guard let swiftRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: rule.written)
            }
        }
        return result
    }
}
