import Foundation

enum QuestionTextUtilities {
    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func regexReplace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

/// Universal ASR cleanup only. Candidate-specific vocabulary is preserved as
/// transcribed and may later be resolved against the active profile evidence.
enum ASRCanonicalizer {
    static func canonicalizeTerms(_ text: String) -> String {
        var result = QuestionTextUtilities.collapse(text)
        let replacements: [(String, String)] = [
            (#"\bc\s+plus\s+plus\b"#, "C++"),
            (#"\bs\s*q\s*l\b"#, "SQL"),
            (#"\ba\s*p\s*i\b"#, "API"),
            (#"\bsim\s+to\s+real\b"#, "sim-to-real"),
            (#"\bend\s+to\s+end\b"#, "end-to-end"),
            (#"\bfrom\s+n\s+to\s+end\b"#, "from end to end")
        ]
        for (pattern, replacement) in replacements {
            result = QuestionTextUtilities.regexReplace(pattern, in: result, with: replacement)
        }
        return QuestionTextUtilities.collapse(result)
    }
}

enum QuestionCanonicalizer {
    static func canonicalize(_ text: String) -> String {
        let cleaned = removeDanglingQuestionTail(ASRCanonicalizer.canonicalizeTerms(text))
        return QuestionTextUtilities.collapse(cleaned)
    }

    static func removeDanglingQuestionTail(_ text: String) -> String {
        var result = QuestionTextUtilities.collapse(text)
        let dangling = [
            #"\s+(?:and|or|but|because|including|such as)\s*[?.!,]*$"#,
            #"\s+(?:what|how|why|whether)\s+(?:the|it|they|you|we)\s*[?.!,]*$"#
        ]
        for pattern in dangling {
            result = QuestionTextUtilities.regexReplace(pattern, in: result, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func truncateRepeatedFragilePipelineTail(_ text: String) -> String {
        let collapsed = QuestionTextUtilities.collapse(text)
        let sentences = collapsed.components(separatedBy: CharacterSet(charactersIn: "?!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard sentences.count > 1 else { return collapsed }
        var seen = Set<String>()
        let unique = sentences.filter { sentence in
            let key = SemanticDuplicateKeyBuilder.key(for: sentence)
            return !key.isEmpty && seen.insert(key).inserted
        }
        return unique.joined(separator: "? ") + (collapsed.hasSuffix("?") ? "?" : "")
    }
}

enum SemanticDuplicateKeyBuilder {
    static func key(for text: String) -> String {
        let stopWords: Set<String> = [
            "a", "an", "the", "please", "could", "would", "can", "you", "your", "tell", "explain", "describe", "about"
        ]
        return TextChunker.tokenize(QuestionCanonicalizer.canonicalize(text))
            .filter { !stopWords.contains($0) }
            .joined(separator: " ")
    }

    static func areDuplicates(_ lhs: String, _ rhs: String) -> Bool {
        let left = Set(key(for: lhs).split(separator: " ").map(String.init))
        let right = Set(key(for: rhs).split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let overlap = left.intersection(right).count
        return Double(overlap) / Double(max(left.count, right.count)) >= 0.85
    }

    static func shouldPrefer(_ candidate: String, over existing: String) -> Bool {
        let candidateWords = QuestionCanonicalizer.canonicalize(candidate).split(whereSeparator: \.isWhitespace).count
        let existingWords = QuestionCanonicalizer.canonicalize(existing).split(whereSeparator: \.isWhitespace).count
        return candidateWords > existingWords
    }
}
