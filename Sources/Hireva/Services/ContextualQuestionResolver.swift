import Foundation

/// Immutable provenance for the last question that passed the runtime guard.
/// A short follow-up may use this reference only while the session and frozen
/// context snapshot still match.
struct AcceptedQuestionContextReference: Equatable {
    let questionID: String
    let sessionID: String
    let contextSnapshotID: String?
    let questionText: String
}

struct ContextualQuestionResolution: Equatable {
    let rawText: String
    let resolvedQuestion: String
    let referencedQuestionID: String
    let contextSnapshotID: String
    let candidate: AcceptedQuestionCandidate
}

/// Resolves a deliberately narrow family of otherwise unsafe short follow-ups.
/// The ordinary runtime guard remains authoritative for both the source question
/// and the resolved result; this type never makes a vague question acceptable on
/// its own.
enum ContextualQuestionResolver {
    static func resolve(
        rawText: String,
        isFinal: Bool,
        currentSessionID: String,
        currentContextSnapshotID: String?,
        previous: AcceptedQuestionContextReference?
    ) -> ContextualQuestionResolution? {
        guard isFinal,
              QuestionRuntimeAcceptanceGuard.normalizedComparisonKey(rawText) == "why",
              let currentContextSnapshotID,
              !currentContextSnapshotID.isEmpty,
              let previous,
              !previous.questionID.isEmpty,
              previous.sessionID == currentSessionID,
              previous.contextSnapshotID == currentContextSnapshotID,
              QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: previous.questionText).accepted
        else {
            return nil
        }

        let previousQuestion = QuestionTextUtilities.collapse(previous.questionText)
        guard let evaluationReference = evaluationReference(from: previousQuestion) else {
            return nil
        }

        let resolved = "Why did \(evaluationReference) matter?"
        let acceptance = QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: resolved)
        guard let candidate = acceptance.candidate else { return nil }

        return ContextualQuestionResolution(
            rawText: rawText,
            resolvedQuestion: candidate.text,
            referencedQuestionID: previous.questionID,
            contextSnapshotID: currentContextSnapshotID,
            candidate: candidate
        )
    }

    /// Convert only explicit evaluation-method questions. A bare "Why?" after
    /// a design, opinion, or multi-part question remains rejected because its
    /// referent cannot be determined from the question text alone.
    private static func evaluationReference(from question: String) -> String? {
        let trimmed = question.trimmingCharacters(in: CharacterSet(charactersIn: " .?!"))
        let patterns: [(pattern: String, prefix: String)] = [
            (
                #"^how did you evaluate (?:your|the) (?:work|approach|project|system) against (.+)$"#,
                "your evaluation against"
            ),
            (
                #"^how did you (?:test|validate|measure|benchmark) (.+)$"#,
                "that evaluation of"
            ),
        ]

        for item in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: item.pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            let source = trimmed as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            guard let match = regex.firstMatch(in: trimmed, range: fullRange),
                  match.numberOfRanges == 2,
                  match.range(at: 0) == fullRange,
                  match.range(at: 1).location != NSNotFound
            else {
                continue
            }
            let scope = source.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard scope.split(whereSeparator: \.isWhitespace).count >= 3 else {
                continue
            }
            return "\(item.prefix) \(scope)"
        }
        return nil
    }
}
