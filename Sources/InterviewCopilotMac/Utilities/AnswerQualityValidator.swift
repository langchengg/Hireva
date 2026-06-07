import Foundation

public struct AnswerQualityValidator {
    
    /// Validates all visible suggestion card fields: say_first, key_points, follow_up_ready, caution
    public static func isValid(
        sayFirst: String,
        keyPoints: [String],
        followUpReady: [String],
        caution: String?
    ) -> Bool {
        if !isValidField(sayFirst, isSayFirst: true) { return false }
        for kp in keyPoints {
            if !isValidField(kp, isSayFirst: false) { return false }
        }
        for fu in followUpReady {
            if !isValidField(fu, isSayFirst: false) { return false }
        }
        if let caution = caution {
            if !isValidField(caution, isSayFirst: false) { return false }
        }
        return true
    }
    
    /// Checks a single text field for output-quality violations
    public static func isValidField(_ text: String, isSayFirst: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        
        // 1. Block any LaTeX commands or stray structural formatting braces
        if trimmed.contains("\\") || trimmed.contains("{") || trimmed.contains("}") || trimmed.contains("\\documentclass") || trimmed.contains("\\usepackage") {
            return false
        }
        
        // 2. Block RAG/preamble structural markers
        if trimmed.contains("[") || trimmed.contains("]") || trimmed.contains("CV:") || trimmed.contains("JD:") {
            return false
        }
        
        // 3. For say_first, enforce first-person spoken tone and block instruction verbs
        if isSayFirst {
            let lower = trimmed.lowercased()
            
            // Check for leading instruction verbs
            let instructionVerbs = [
                "highlight", "emphasize", "use ", "use:", "mention", "focus on", "state ", "describe ", "explain ", "outline ", "refer to", "demonstrate"
            ]
            for verb in instructionVerbs {
                if lower.hasPrefix(verb) {
                    return false
                }
            }
            
            // Verify it has some first-person aspect (e.g. contains "i", "my", "me", "our", "we")
            // Or does not sound purely like instructions. To be safe, we check if it has first-person pronouns
            let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let firstPersonPronouns: Set<String> = ["i", "my", "me", "im", "we", "our", "us"]
            let hasFirstPerson = tokens.contains { firstPersonPronouns.contains($0) }
            if !hasFirstPerson {
                return false
            }
            
            // Must not be too long (more than 90 words is too long for say_first)
            if tokens.count > 90 {
                return false
            }
        }
        
        return true
    }
    
    /// Locally cleans LaTeX commands, curly braces, and instruction prefixes immediately
    public static func localCleanupAnswer(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return cleaned }
        
        // Strip isolated LaTeX backslash commands recursively
        var loopCount = 0
        var macroCleaned = true
        while macroCleaned && loopCount < 10 {
            macroCleaned = false
            loopCount += 1
            if let regex = try? NSRegularExpression(pattern: "\\\\[a-zA-Z]+\\s*\\{([^\\{\\}]*)\\}", options: []) {
                let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                let matches = regex.matches(in: cleaned, options: [], range: range)
                if !matches.isEmpty {
                    cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "$1")
                    macroCleaned = true
                }
            }
        }
        
        // Remove braces
        cleaned = cleaned.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\\", with: "")
        
        // Strip raw CV/JD tags if any
        cleaned = cleaned.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        
        // Fix leading instruction verbs by converting to first person or stripping them
        let lower = cleaned.lowercased()
        
        if lower.hasPrefix("highlight alignment") {
            let index = cleaned.index(cleaned.startIndex, offsetBy: 19)
            cleaned = "I align" + cleaned[index...]
        } else if lower.hasPrefix("highlight ") {
            let index = cleaned.index(cleaned.startIndex, offsetBy: 10)
            cleaned = "I " + cleaned[index...]
        } else if lower.hasPrefix("emphasize ") {
            let index = cleaned.index(cleaned.startIndex, offsetBy: 10)
            cleaned = "I emphasize " + cleaned[index...]
        } else if lower.hasPrefix("use ") {
            let index = cleaned.index(cleaned.startIndex, offsetBy: 4)
            cleaned = "I can use " + cleaned[index...]
        } else if lower.hasPrefix("mention ") {
            let index = cleaned.index(cleaned.startIndex, offsetBy: 8)
            cleaned = "I should mention " + cleaned[index...]
        } else if lower.hasPrefix("focus on ") {
            let index = cleaned.index(cleaned.startIndex, offsetBy: 9)
            cleaned = "I will focus on " + cleaned[index...]
        }
        
        // Emphasizing -> and emphasize
        cleaned = cleaned.replacingOccurrences(of: "emphasizing", with: "and I emphasize", options: .caseInsensitive)
        
        // Final trim
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
