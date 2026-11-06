import Foundation

enum ContextBudgeter {
    static func limitWords(_ text: String, maxWords: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWords else { return text }
        return words.prefix(maxWords).joined(separator: " ")
    }

    static func limitReferenceWords(_ text: String, maxWords: Int) -> String {
        guard text.split(whereSeparator: \.isWhitespace).count > maxWords else { return text }
        let notice = "[Reference excerpt: additional content and conditions may be omitted.]"
        var remaining = maxWords - notice.split(whereSeparator: \.isWhitespace).count
        guard remaining >= 0 else { return "" }
        var lines: [String] = []
        // shortcut: preserve supplied line blocks; unbroken oversized material needs a separately bounded source excerpt.
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != notice else { continue }
            let count = line.split(whereSeparator: \.isWhitespace).count
            guard count <= remaining else { break }
            lines.append(line)
            remaining -= count
        }
        return (lines + [notice]).joined(separator: "\n")
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
                trimmed.content = chunk.documentType == .additionalNotes
                    ? limitReferenceWords(chunk.content, maxWords: remaining)
                    : words.prefix(remaining).joined(separator: " ")
                trimmed.wordCount = trimmed.content.split(whereSeparator: \.isWhitespace).count
                if !trimmed.content.isEmpty { output.append(trimmed) }
                remaining = 0
            }
        }

        return output
    }
}
