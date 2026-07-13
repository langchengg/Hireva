import Foundation

struct StreamingSuggestionSections: Equatable, Hashable {
    var strategy: String = ""
    var sayFirst: String = ""
    var keyPoints: [String] = []
    var followUpReady: [String] = []
    var caution: String = ""

    var hasVisibleContent: Bool {
        !sayFirst.isEmpty || !keyPoints.isEmpty || !followUpReady.isEmpty || !caution.isEmpty
    }

    var characterCount: Int {
        strategy.count
            + sayFirst.count
            + keyPoints.reduce(0) { $0 + $1.count }
            + followUpReady.reduce(0) { $0 + $1.count }
            + caution.count
    }
}

struct StreamingSuggestionSectionParser {
    private enum Section {
        case strategy
        case sayFirst
        case keyPoints
        case followUpReady
        case caution
    }

    private var buffer = ""
    private(set) var snapshot = StreamingSuggestionSections()

    mutating func append(_ token: String) -> StreamingSuggestionSections {
        buffer += token
        snapshot = Self.parse(buffer)
        return snapshot
    }

    static func parse(_ text: String) -> StreamingSuggestionSections {
        var parsed = StreamingSuggestionSections()
        var currentSection: Section?
        var sayFirstLines: [String] = []
        var cautionLines: [String] = []
        var strategyLines: [String] = []

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let header = sectionHeader(from: line) {
                currentSection = header
                let remainder = inlineHeaderRemainder(from: line)
                if !remainder.isEmpty {
                    append(remainder, to: currentSection, parsed: &parsed, strategyLines: &strategyLines, sayFirstLines: &sayFirstLines, cautionLines: &cautionLines)
                }
                continue
            }

            append(line, to: currentSection, parsed: &parsed, strategyLines: &strategyLines, sayFirstLines: &sayFirstLines, cautionLines: &cautionLines)
        }

        parsed.strategy = strategyLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        parsed.sayFirst = sayFirstLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        parsed.caution = cautionLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return parsed
    }

    private static func sectionHeader(from line: String) -> Section? {
        let normalized = line
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .uppercased()

        switch normalized {
        case "STRATEGY": return .strategy
        case "SAY_FIRST", "SAYFIRST": return .sayFirst
        case "KEY_POINTS", "KEYPOINTS", "KEY_POINT": return .keyPoints
        case "FOLLOW_UP_READY", "FOLLOWUP_READY", "FOLLOW_UPS", "FOLLOW_UP": return .followUpReady
        case "CAUTION": return .caution
        default: return nil
        }
    }

    private static func inlineHeaderRemainder(from line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(
        _ line: String,
        to section: Section?,
        parsed: inout StreamingSuggestionSections,
        strategyLines: inout [String],
        sayFirstLines: inout [String],
        cautionLines: inout [String]
    ) {
        guard let section else { return }
        switch section {
        case .strategy:
            strategyLines.append(cleanInlineText(line))
        case .sayFirst:
            sayFirstLines.append(cleanInlineText(line))
        case .keyPoints:
            let point = cleanBullet(line)
            if !point.isEmpty {
                parsed.keyPoints.append(point)
            }
        case .followUpReady:
            let point = cleanBullet(line)
            if !point.isEmpty {
                parsed.followUpReady.append(point)
            }
        case .caution:
            cautionLines.append(cleanInlineText(line))
        }
    }

    private static func cleanBullet(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["-", "*", "•"] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if let dotRange = cleaned.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
            cleaned.removeSubrange(dotRange)
        }
        return cleanInlineText(cleaned)
    }

    private static func cleanInlineText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"^["']|["']$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
