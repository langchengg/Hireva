import Foundation

struct TextChunk {
    var content: String
    var keywords: [String]
}

enum TextChunker {
    static func chunks(from text: String, maxWords: Int = 120) -> [TextChunk] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let seeds = paragraphs.isEmpty ? [normalized] : paragraphs
        var output: [TextChunk] = []

        for seed in seeds {
            let words = seed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }

            if words.count <= maxWords {
                output.append(TextChunk(content: seed, keywords: keywords(in: seed)))
            } else {
                var start = 0
                while start < words.count {
                    let end = min(start + maxWords, words.count)
                    let content = words[start..<end].joined(separator: " ")
                    output.append(TextChunk(content: content, keywords: keywords(in: content)))
                    start = end
                }
            }
        }

        return output
    }

    static func keywords(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "are", "was", "were",
            "you", "your", "our", "will", "have", "has", "had", "about", "into", "can",
            "able", "using", "use", "used", "role", "work", "team", "job", "description"
        ]

        let tokens = tokenize(text)
        let counted = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
        return counted
            .filter { key, _ in key.count > 2 && !stopWords.contains(key) }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(24)
            .map(\.key)
    }

    static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
