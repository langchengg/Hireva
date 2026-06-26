import Foundation

enum QuestionTextUtilities {
    static func collapse(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func regexReplace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

/// Normalizes common Apple Speech / system-audio transcription variants before
/// question splitting, duplicate suppression, intent routing, or alignment.
enum ASRCanonicalizer {
    static func canonicalizeTerms(_ text: String) -> String {
        var canonical = QuestionTextUtilities.collapse(text)
        canonical = replaceMuJoCoVariants(in: canonical)
        canonical = replaceVLAVariants(in: canonical)
        canonical = replaceLeoRoverVariants(in: canonical)
        canonical = replaceYOLOv8Variants(in: canonical)
        canonical = replaceModelVariants(in: canonical)
        canonical = replaceSimToRealVariants(in: canonical)
        canonical = replaceMitigationTailVariants(in: canonical)
        canonical = QuestionTextUtilities.regexReplace(#"\bfrom\s+n\s+to\s+end\b"#, in: canonical, with: "from end to end")
        canonical = QuestionTextUtilities.regexReplace(#"\bfrom\s+end\s+to\s+end\b"#, in: canonical, with: "from end to end")
        return QuestionTextUtilities.collapse(canonical)
    }

    private static func replaceMuJoCoVariants(in text: String) -> String {
        var result = text
        result = QuestionTextUtilities.regexReplace(#"\bmuji\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmooji\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmugi\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmu\s+g\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmouko\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmoko\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmoco\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmuko\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmuja\s+cove\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmujo\s+cove\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmuja\s+co\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmu\s+jo\s+co\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmojave\b"#, in: result, with: "MuJoCo")
        result = QuestionTextUtilities.regexReplace(#"\bmujoco\b"#, in: result, with: "MuJoCo")
        return result
    }

    private static func replaceVLAVariants(in text: String) -> String {
        var result = text
        result = QuestionTextUtilities.regexReplace(#"\bv\s*l\s*a\s+project\b"#, in: result, with: "VLA project")
        result = QuestionTextUtilities.regexReplace(#"\bv\s+l\s+a\s+project\b"#, in: result, with: "VLA project")
        result = QuestionTextUtilities.regexReplace(#"\bvilla\s+project\b"#, in: result, with: "VLA project")
        result = QuestionTextUtilities.regexReplace(#"\bvila\s+project\b"#, in: result, with: "VLA project")
        result = QuestionTextUtilities.regexReplace(#"\bv\s*l\s*a\b"#, in: result, with: "VLA")
        result = QuestionTextUtilities.regexReplace(#"\bv\s+l\s+a\b"#, in: result, with: "VLA")
        return result
    }

    private static func replaceLeoRoverVariants(in text: String) -> String {
        var result = text
        result = QuestionTextUtilities.regexReplace(#"\bleader\s+rover\b"#, in: result, with: "LeoRover")
        result = QuestionTextUtilities.regexReplace(#"\bleah\s+rover\b"#, in: result, with: "LeoRover")
        result = QuestionTextUtilities.regexReplace(#"\bleo\s+rover\b"#, in: result, with: "LeoRover")
        result = QuestionTextUtilities.regexReplace(#"\blayover\b"#, in: result, with: "LeoRover")
        result = QuestionTextUtilities.regexReplace(#"\blero\b"#, in: result, with: "LeoRover")
        return result
    }

    private static func replaceYOLOv8Variants(in text: String) -> String {
        var result = text
        result = QuestionTextUtilities.regexReplace(#"\byellow\s+of\s+aid\b"#, in: result, with: "YOLOv8")
        result = QuestionTextUtilities.regexReplace(#"\byellow\s+aid\b"#, in: result, with: "YOLOv8")
        result = QuestionTextUtilities.regexReplace(#"\byo\s+love\s+eight\b"#, in: result, with: "YOLOv8")
        result = QuestionTextUtilities.regexReplace(#"\byolo\s+eight\b"#, in: result, with: "YOLOv8")
        result = QuestionTextUtilities.regexReplace(#"\byolo\s+8\b"#, in: result, with: "YOLOv8")
        result = QuestionTextUtilities.regexReplace(#"\byolo\s+v\s*8\b"#, in: result, with: "YOLOv8")
        result = QuestionTextUtilities.regexReplace(#"\bYOLO\s*v8\b"#, in: result, with: "YOLOv8")
        return result
    }

    private static func replaceModelVariants(in text: String) -> String {
        var result = text
        result = QuestionTextUtilities.regexReplace(#"\bauto\s+rig\s+progressive\b"#, in: result, with: "autoregressive")
        result = QuestionTextUtilities.regexReplace(#"\bauto[-\s]+regressive\b"#, in: result, with: "autoregressive")
        result = QuestionTextUtilities.regexReplace(#"\bflow\s*matching\b"#, in: result, with: "flow-matching")
        result = QuestionTextUtilities.regexReplace(#"\bflow[-\s]+matching\b"#, in: result, with: "flow-matching")
        result = QuestionTextUtilities.regexReplace(#"\bdiffusion[-\s]+based\s+policy\b"#, in: result, with: "diffusion policy")
        return result
    }

    private static func replaceSimToRealVariants(in text: String) -> String {
        var result = text
        result = QuestionTextUtilities.regexReplace(#"\bseem[-\s]+to[-\s]+real\b"#, in: result, with: "sim-to-real")
        result = QuestionTextUtilities.regexReplace(#"\bseem\s+real\b"#, in: result, with: "sim-to-real")
        result = QuestionTextUtilities.regexReplace(#"\bsim\s+real\b"#, in: result, with: "sim-to-real")
        result = QuestionTextUtilities.regexReplace(#"\bsim[-\s]+to[-\s]+real\b"#, in: result, with: "sim-to-real")
        return result
    }

    private static func replaceMitigationTailVariants(in text: String) -> String {
        var result = text
        result = QuestionTextUtilities.regexReplace(#"\band\s+how\s+did\s+mitigate\b"#, in: result, with: "and how did you mitigate")
        result = QuestionTextUtilities.regexReplace(#"\bhow\s+did\s+mitigate\b"#, in: result, with: "how did you mitigate")
        result = QuestionTextUtilities.regexReplace(#"\band\s+how\s+would\s+mitigate\b"#, in: result, with: "and how would you mitigate")
        result = QuestionTextUtilities.regexReplace(#"\bhow\s+would\s+mitigate\b"#, in: result, with: "how would you mitigate")
        return result
    }
}

enum QuestionCanonicalizer {
    static func canonicalize(_ text: String) -> String {
        var canonical = ASRCanonicalizer.canonicalizeTerms(text)
        canonical = truncateRepeatedFragilePipelineTail(canonical)
        canonical = removeDanglingQuestionTail(canonical)

        let lower = canonical.lowercased()
        if isDecoderComparisonCanonicalCandidate(lower) {
            return "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?"
        }

        if isPerceptionDebuggingCanonicalCandidate(lower) {
            return "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?"
        }

        if lower == "what was the biggest technical trade-off you made in your robotics projects" ||
            lower == "what was the biggest technical tradeoff you made in your robotics projects" ||
            lower == "what was the biggest technical trade off you made in your robotics projects" {
            return "What was the biggest technical trade-off you made in your robotics projects?"
        }

        if (lower.contains("what questions would you ask us") &&
            (lower.contains("about the team") || lower.contains("team or the role") || lower.contains("before accepting an offer"))) ||
            lower.contains("what would you ask the team") ||
            lower.contains("before accepting an offer") {
            return "What questions would you ask us about the team or the role before accepting an offer?"
        }

        if lower == "when you moved from a clean demo to real robot execution which part of the pipeline was most fragile" ||
            lower == "when you move from a clean demo to real robot execution which part of the pipeline was most fragile" {
            return "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?"
        }

        if lower == "could you explain your leorover" ||
            lower == "can you explain your leorover" ||
            lower == "could you walk me through your leorover" ||
            lower == "can you walk me through your leorover" {
            canonical += " project"
        }
        return canonical
    }

    static func removeDanglingQuestionTail(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lower = cleaned.lowercased()
        let danglingTails = [
            " when you moved from",
            " when you move from",
            " when you moved",
            " when you move",
            " when you",
            " why do you want",
            " why do you",
            " how would you diagnose a seem",
            " how would you diagnose",
            " how would you",
            " what did you learn",
            " what did you",
            " what questions would you ask us about the",
            " what questions would you ask",
            " what",
            " how",
            " if",
            " also if",
            " could you",
            " can you",
            " would you",
            " tell me about",
            " do you",
            " about the",
            " why"
        ]
        var removed = true
        while removed {
            removed = false
            for tail in danglingTails where lower.hasSuffix(tail) {
                cleaned.removeLast(tail.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                lower = cleaned.lowercased()
                removed = true
                break
            }
        }
        return cleaned
    }

    static func truncateRepeatedFragilePipelineTail(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        guard lower.hasPrefix("when you moved from") || lower.hasPrefix("when you move from") else {
            return cleaned
        }

        let completion = "which part of the pipeline was most fragile"
        guard let completionRange = lower.range(of: completion) else {
            return cleaned
        }

        let tail = String(lower[completionRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tail.isEmpty ||
              tail.hasPrefix("when you moved") ||
              tail.hasPrefix("when you move") else {
            return cleaned
        }

        return String(cleaned[..<completionRange.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDecoderComparisonCanonicalCandidate(_ lower: String) -> Bool {
        let modelTerms = ["autoregressive", "diffusion", "flow-matching"].filter { lower.contains($0) }.count
        let hasTruncatedFlowMatchingTail = lower.contains("what did you learn from comparing") &&
            lower.contains("autoregressive") &&
            lower.contains("diffusion") &&
            lower.range(of: #"\bflow\b"#, options: .regularExpression) != nil
        let mentionsLearningComparison = lower.contains("what did you learn") ||
            lower.contains("comparing") ||
            lower.contains("compared")
        let mentionsVLA = lower.contains("mujoco") ||
            lower.contains("vla") ||
            lower.contains("franka")
        return (mentionsLearningComparison && mentionsVLA && modelTerms >= 2) || hasTruncatedFlowMatchingTail
    }

    private static func isPerceptionDebuggingCanonicalCandidate(_ lower: String) -> Bool {
        let mentionsDetector = lower.contains("yolov8") ||
            lower.contains("detector") ||
            lower.contains("detection") ||
            lower.contains("prediction")
        let mentionsDebug = lower.contains("debug") ||
            lower.contains("confident but wrong") ||
            lower.contains("wrong prediction") ||
            lower.contains("false positive")
        return mentionsDetector && mentionsDebug
    }
}

enum SemanticDuplicateKeyBuilder {
    static func key(for text: String) -> String {
        var key = QuestionCanonicalizer.canonicalize(text).lowercased()
        key = QuestionTextUtilities.regexReplace(#"\bauto\s+rig\s+progressive\b"#, in: key, with: "autoregressive")
        key = QuestionTextUtilities.regexReplace(#"\bauto[-\s]+regressive\b"#, in: key, with: "autoregressive")
        key = QuestionTextUtilities.regexReplace(#"\bflow\s*matching\b"#, in: key, with: "flow-matching")
        key = QuestionTextUtilities.regexReplace(#"\bflow[-\s]+matching\b"#, in: key, with: "flow-matching")
        key = QuestionTextUtilities.regexReplace(#"\bmuji\b|\bmooji\b|\bmugi\b|\bmu\s+g\b|\bmouko\b|\bmoko\b|\bmoco\b|\bmuko\b|\bmuja\s+cove\b|\bmujo\s+cove\b|\bmuja\s+co\b|\bmu\s+jo\s+co\b|\bmojave\b|\bmujoco\b"#, in: key, with: "mujoco")
        key = QuestionTextUtilities.regexReplace(#"\bvilla\s+project\b|\bvila\s+project\b|\bv\s*l\s*a\s+project\b|\bv\s+l\s+a\s+project\b|\bv\s*l\s*a\b|\bv\s+l\s+a\b"#, in: key, with: "vla")
        key = QuestionTextUtilities.regexReplace(#"\byo\s+love\s+eight\b|\byolo\s+eight\b|\byolo\s+8\b|\byolo\s+v\s*8\b|\byolov8\b"#, in: key, with: "yolov8")
        key = QuestionTextUtilities.regexReplace(#"\blayover\b|\bleader\s+rover\b|\bleah\s+rover\b|\bleo\s+rover\b|\blero\b"#, in: key, with: "leorover")
        key = QuestionTextUtilities.regexReplace(#"\bseem[-\s]+to[-\s]+real\b|\bseem\s+real\b|\bsim\s+real\b|\bsim[-\s]+to[-\s]+real\b"#, in: key, with: "sim-to-real")
        key = QuestionTextUtilities.regexReplace(#"\bdiffusion[-\s]+based\s+policy\b"#, in: key, with: "diffusion policy")
        key = QuestionTextUtilities.regexReplace(#"\bdiffusion[-\s]+based\b"#, in: key, with: "diffusion")

        let isLeoRover = key.contains("leorover")
        let isProjectWalkthrough = key.contains("walk me through") ||
            key.contains("explain your") ||
            key.contains("from end to end") ||
            key.hasSuffix("leorover project")
        let isTechnicalFollowUp = key.contains("fragile") ||
            key.contains("hardest") ||
            key.contains("pipeline") && (key.contains("which part") || key.contains("most fragile")) ||
            key.contains("noisy") ||
            key.contains("localisation") ||
            key.contains("localization")
        if isLeoRover && isProjectWalkthrough && !isTechnicalFollowUp {
            return "project walkthrough leorover"
        }

        return key
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func areDuplicates(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        if left == right {
            return true
        }
        guard !left.isEmpty, !right.isEmpty else {
            return false
        }
        let shorter = left.count <= right.count ? left : right
        let longer = left.count > right.count ? left : right
        guard longer.contains(shorter) else {
            return false
        }
        let shorterWords = shorter.split(separator: " ").count
        let longerWords = longer.split(separator: " ").count
        guard shorterWords > 0 else { return false }
        return Double(longerWords) / Double(shorterWords) <= 1.8
    }

    static func shouldPrefer(_ candidate: String, over existing: String) -> Bool {
        let candidateWords = QuestionCanonicalizer.canonicalize(candidate).split(whereSeparator: \.isWhitespace).count
        let existingWords = QuestionCanonicalizer.canonicalize(existing).split(whereSeparator: \.isWhitespace).count
        return candidateWords > existingWords
    }

    private static func normalized(_ text: String) -> String {
        key(for: text).trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;: "))
    }
}
