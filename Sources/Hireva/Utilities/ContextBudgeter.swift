import Foundation

enum ContextBudgeter {
    static func limitWords(_ text: String, maxWords: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWords else { return text }
        return words.prefix(maxWords).joined(separator: " ")
    }

    static func limitChunks(_ chunks: [DocumentChunk], maxWords: Int) -> [DocumentChunk] {
        var remaining = maxWords
        var output: [DocumentChunk] = []

        for chunk in chunks {
            guard remaining > 0 else { break }
            let words = chunk.content.split(whereSeparator: \.isWhitespace)
            if words.count <= remaining {
                output.append(chunk)
                remaining -= words.count
            } else {
                var trimmed = chunk
                trimmed.content = words.prefix(remaining).joined(separator: " ")
                output.append(trimmed)
                remaining = 0
            }
        }

        return output
    }
}
