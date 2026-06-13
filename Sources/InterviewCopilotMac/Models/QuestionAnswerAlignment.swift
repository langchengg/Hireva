// Validates that a visible answer belongs to the current detected question.
// Alignment checks are intentionally conservative for clear technical questions
// because a fluent but wrong answer is worse than a local fallback during an
// interview.

import Foundation

/// UI/diagnostic binding status between the current question and suggestion.
enum QABindingStatus: String, CaseIterable, Codable, Hashable {
    case matched
    case mismatched
    case missingSuggestion
    case missingQuestion
    case staleDiscarded
}

/// Snapshot of the current question-answer binding used by UI diagnostics and
/// tests to catch stale-generation overwrites.
struct QABindingSnapshot: Equatable {
    var currentQuestionID: String?
    var currentQuestionText: String
    var currentSuggestionID: String?
    var currentSuggestionDetectedQuestionID: String?
    var currentSuggestionQuestionText: String
    var activeGenerationID: String?
    var activeGenerationQuestionID: String?
    var bindingStatus: QABindingStatus
    var lastAlignmentError: String

    static let empty = QABindingSnapshot(
        currentQuestionID: nil,
        currentQuestionText: "",
        currentSuggestionID: nil,
        currentSuggestionDetectedQuestionID: nil,
        currentSuggestionQuestionText: "",
        activeGenerationID: nil,
        activeGenerationQuestionID: nil,
        bindingStatus: .missingSuggestion,
        lastAlignmentError: ""
    )
}

/// Coarse semantic alignment verdict between a question and generated answer.
enum AnswerAlignmentVerdict: String, CaseIterable, Codable, Hashable {
    case aligned
    case weaklyAligned
    case mismatched
    case unknown
}

/// Full alignment result with themes used for diagnostics and persistence.
struct AnswerAlignmentResult: Equatable {
    var score: Double
    var verdict: AnswerAlignmentVerdict
    var questionIntent: AnswerRelevanceIntent
    var answerIntent: AnswerRelevanceIntent
    var matchedThemes: [String]
    var missingThemes: [String]
    var wrongAnswerIndicators: [String]
    var reason: String
}

/// Persisted/debuggable alignment row for generated suggestions.
struct SuggestionAlignmentRecord: Identifiable, Equatable {
    var id: String
    var detectedQuestionID: String?
    var questionText: String
    var sayFirstPreview: String
    var alignmentScore: Double
    var alignmentVerdict: AnswerAlignmentVerdict
    var answerIntent: AnswerRelevanceIntent
    var expectedThemesMatched: [String]
    var suspectedMismatchReason: String
}

/// Heuristic evaluator for answer relevance and completeness.
///
/// This is not a ranking model. It is a safety guard before UI display and DB
/// persistence, with stricter handling for technical/model-comparison questions
/// where `unknown` should not be accepted as good enough.
enum QuestionAnswerAlignmentEvaluator {
    static func isAnswerComplete(_ answer: String) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }

        let lower = trimmed.lowercased()

        let incompleteWords = ["more", "because", "such as", "including"]
        for word in incompleteWords {
            if lower.hasSuffix(word) ||
               lower.hasSuffix(word + ".") ||
               lower.hasSuffix(word + ",") ||
               lower.hasSuffix(word + ":") ||
               lower.hasSuffix(word + "...") {
                return false
            }
        }

        if let lastChar = trimmed.last {
            if ",:".contains(lastChar) {
                return false
            }
        }

        let words = lower.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count >= 2 {
            let lastTwo = words.suffix(2).joined(separator: " ")
            if ["tend to", "be more", "such as", "including to", "more stable"].contains(lastTwo) {
                return false
            }
        }

        return true
    }

    /// Scores whether the generated answer directly addresses the question.
    ///
    /// `sayFirst` is checked independently because it can become visible before
    /// Stage B completes. If Stage B is still running, weak evidence should not
    /// be over-promoted to aligned.
    static func evaluate(
        questionText: String,
        answerText: String,
        sayFirst: String = "",
        stageBCompleted: Bool = true
    ) -> AnswerAlignmentResult {
        let normalizedQuestion = normalize(questionText)
        let normalizedAnswer = normalize(answerText)
        let questionIntent = AnswerRelevancePolicy.intent(for: questionText)
        let answerIntent = inferredAnswerIntent(for: normalizedAnswer)
        guard !normalizedQuestion.isEmpty, !normalizedAnswer.isEmpty else {
            return AnswerAlignmentResult(
                score: 0,
                verdict: .unknown,
                questionIntent: questionIntent,
                answerIntent: answerIntent,
                matchedThemes: [],
                missingThemes: [],
                wrongAnswerIndicators: [],
                reason: "Question or answer text is empty."
            )
        }

        let profile = profile(for: normalizedQuestion)
        let matched = profile.themes.filter { theme in
            theme.alternatives.contains { normalizedAnswer.contains($0) }
        }.map(\.name)
        let missing = profile.themes.filter { theme in
            !theme.alternatives.contains { normalizedAnswer.contains($0) }
        }.map(\.name)
        let wrong = profile.wrongIndicators.filter { indicator in
            indicator.alternatives.contains { normalizedAnswer.contains($0) }
        }.map(\.name)

        let score = profile.themes.isEmpty ? 0.0 : Double(matched.count) / Double(profile.themes.count)
        var verdict: AnswerAlignmentVerdict
        if !wrong.isEmpty && score < 0.35 {
            verdict = .mismatched
        } else if score >= 0.45 {
            verdict = .aligned
        } else if score >= 0.20 {
            verdict = .weaklyAligned
        } else if !wrong.isEmpty {
            verdict = .mismatched
        } else {
            verdict = .unknown
        }

        var finalReason = ""
        let isTechnical = questionIntent == .technicalChallenge ||
                          questionIntent == .modelComparison ||
                          questionIntent == .diffusionPolicy ||
                          questionIntent == .errorHandling ||
                          questionIntent == .skillComfort

        if isTechnical && verdict == .unknown {
            // Clear technical questions should either match expected themes or
            // fall back. Accepting "unknown" here reintroduces the no-answer or
            // wrong-answer behavior seen in real runtime testing.
            verdict = .mismatched
            finalReason += " Rejected unknown verdict for clear technical question."
        }

        if !sayFirst.isEmpty {
            let trimmedSayFirst = sayFirst.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerSayFirst = trimmedSayFirst.lowercased()
            var isIncomplete = false
            var incompleteReason = ""

            if trimmedSayFirst.count < 15 || trimmedSayFirst.split(whereSeparator: \.isWhitespace).count < 4 {
                isIncomplete = true
                incompleteReason = "too short (\(trimmedSayFirst.count) chars)"
            } else {
                let incompleteWords = ["more", "because", "such as", "including"]
                for word in incompleteWords {
                    if lowerSayFirst.hasSuffix(word) ||
                       lowerSayFirst.hasSuffix(word + ".") ||
                       lowerSayFirst.hasSuffix(word + ",") ||
                       lowerSayFirst.hasSuffix(word + ":") ||
                       lowerSayFirst.hasSuffix(word + "...") {
                        isIncomplete = true
                        incompleteReason = "ends with incomplete word '\(word)'"
                    }
                }
                if let lastChar = trimmedSayFirst.last, ",:".contains(lastChar) {
                    isIncomplete = true
                    incompleteReason = "ends with punctuation '\(lastChar)'"
                }
                let words = lowerSayFirst.split(whereSeparator: \.isWhitespace).map(String.init)
                if words.count >= 2 {
                    let lastTwo = words.suffix(2).joined(separator: " ")
                    if ["tend to", "be more", "such as", "including to", "more stable"].contains(lastTwo) {
                        isIncomplete = true
                        incompleteReason = "ends with incomplete clause '\(lastTwo)'"
                    }
                }
            }

            if isIncomplete {
                verdict = .mismatched
                finalReason += " Rejected incomplete sayFirst: \(incompleteReason)."
            }

            if let visibleIssue = modelComparisonVisibleSayFirstIssue(
                normalizedQuestion: normalizedQuestion,
                normalizedSayFirst: normalize(trimmedSayFirst),
                questionIntent: questionIntent
            ) {
                verdict = .mismatched
                finalReason += " Rejected generic model-comparison sayFirst: \(visibleIssue)."
            }
        }

        if !stageBCompleted {
            if verdict == .weaklyAligned {
                verdict = .unknown
                finalReason += " Set weak alignment to unknown because Stage B is still running."
            }
        }

        let evaluatedReason = reason(
            matchedCount: matched.count,
            totalCount: profile.themes.count,
            wrongIndicators: wrong,
            questionIntent: questionIntent,
            answerIntent: answerIntent
        )
        finalReason = finalReason.isEmpty ? evaluatedReason : evaluatedReason + " " + finalReason

        return AnswerAlignmentResult(
            score: score,
            verdict: verdict,
            questionIntent: questionIntent,
            answerIntent: answerIntent,
            matchedThemes: matched,
            missingThemes: missing,
            wrongAnswerIndicators: wrong,
            reason: finalReason
        )
    }

    private struct Theme {
        var name: String
        var alternatives: [String]
    }

    private struct Profile {
        var themes: [Theme]
        var wrongIndicators: [Theme]
    }

    private static func profile(for question: String) -> Profile {
        if question.contains("about yourself") || question.contains("brought you into robotics") {
            return Profile(
                themes: [
                    Theme(name: "MSc Robotics", alternatives: ["msc robotics", "robotics at the university"]),
                    Theme(name: "University of Manchester", alternatives: ["university of manchester", "manchester"]),
                    Theme(name: "computer science background", alternatives: ["computer science"]),
                    Theme(name: "robotics interest", alternatives: ["robotics interest", "interested in robotics", "brought me into robotics"]),
                    Theme(name: "perception / manipulation / AI", alternatives: ["perception", "manipulation", " ai ", "artificial intelligence"])
                ],
                wrongIndicators: projectOrChallengeIndicators()
            )
        }

        if question.contains("leorover") || question.contains("leo rover") || question.contains("walk me through") {
            return Profile(
                themes: [
                    Theme(name: "autonomous object retrieval robot", alternatives: ["autonomous object retrieval", "object retrieval robot"]),
                    Theme(name: "ROS2", alternatives: ["ros2", "rose two"]),
                    Theme(name: "YOLOv8", alternatives: ["yolov8", "yolo"]),
                    Theme(name: "navigation", alternatives: ["navigation", "navigate"]),
                    Theme(name: "manipulation", alternatives: ["manipulation", "manipulator"]),
                    Theme(name: "target localisation", alternatives: ["target localisation", "target localization", "localisation", "localization"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("hardest technical challenge") ||
            question.contains("hardest challenge") ||
            question.contains("pipeline was most fragile") ||
            question.contains("most fragile") ||
            question.contains("real robot execution") ||
            question.contains("clean demo") {
            return Profile(
                themes: [
                    Theme(name: "module integration", alternatives: ["module integration", "integrating modules", "modules work"]),
                    Theme(name: "noisy perception", alternatives: ["noisy perception", "noisy detections"]),
                    Theme(name: "localisation instability", alternatives: ["localisation instability", "localization instability", "localisation was not stable", "localization was not stable"]),
                    Theme(name: "timing mismatch", alternatives: ["timing mismatch", "timing between"]),
                    Theme(name: "real robot unpredictability", alternatives: ["real robot", "unpredictable", "less predictable"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("noisy detections") || question.contains("localisation errors") || question.contains("localization errors") {
            return Profile(
                themes: [
                    Theme(name: "filtering", alternatives: ["filtering", "filtered"]),
                    Theme(name: "repeated observations", alternatives: ["repeated observations", "multiple observations"]),
                    Theme(name: "stability threshold", alternatives: ["stable enough", "stability threshold", "target was stable"]),
                    Theme(name: "recovery behaviour", alternatives: ["recovery behaviour", "recover"]),
                    Theme(name: "retry / reposition", alternatives: ["retry", "reposition", "adjust"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("diffusion decoder") ||
            question.contains("diffusion-based policy") ||
            question.contains("diffusion policy") ||
            question.contains("autoregressive policy") ||
            question.contains("mujoco") ||
            question.contains("mu jo co") ||
            (question.contains("diffusion") && question.contains("robotic manipulation")) {
            return Profile(
                themes: [
                    Theme(name: "smoother actions", alternatives: ["smoother actions", "smooth actions", "smoother", "jerky motions"]),
                    Theme(name: "continuous action distribution", alternatives: ["continuous action", "action distribution", "action sequence", "action sequences", "trajectory distribution", "full trajectory", "continuous manipulation"]),
                    Theme(name: "robustness", alternatives: ["robust", "robustness"]),
                    Theme(name: "7/10 success", alternatives: ["seven out of ten", "7 out of 10", "7/10", "higher success rate", "higher success rates"]),
                    Theme(name: "autoregressive / flow-matching comparison", alternatives: ["autoregressive", "flow matching", "flow-matching", "compounding error", "compound errors", "step-by-step", "step by step"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("another month") || question.contains("change first") {
            return Profile(
                themes: [
                    Theme(name: "improve evaluation", alternatives: ["improve the evaluation", "evaluation pipeline"]),
                    Theme(name: "more objects / positions / failure cases", alternatives: ["more objects", "initial positions", "failure cases"]),
                    Theme(name: "robust perception", alternatives: ["robust perception", "perception robustness"]),
                    Theme(name: "visual grounding", alternatives: ["visual grounding"]),
                    Theme(name: "grasp reranking", alternatives: ["reranking", "grasp candidates"])
                ],
                wrongIndicators: projectOrChallengeIndicators()
            )
        }

        if question.contains("why do you want") || question.contains("join our team") || question.contains("this role") {
            return Profile(
                themes: [
                    Theme(name: "role alignment", alternatives: ["role connects", "role alignment", "lines up", "want this role"]),
                    Theme(name: "robotics / AI / perception", alternatives: ["robotics", " ai ", "perception"]),
                    Theme(name: "real robot deployment", alternatives: ["real robot", "deployment", "deployed"]),
                    Theme(name: "engineering growth", alternatives: ["engineering growth", "engineering ability", "growth"]),
                    Theme(name: "deployed systems", alternatives: ["deployed systems", "deployed robotic systems"])
                ],
                wrongIndicators: [
                    Theme(name: "technical challenge answer", alternatives: ["hardest technical challenge", "noisy localisation", "noisy localization", "timing mismatch", "module integration"]),
                    Theme(name: "self introduction answer", alternatives: ["i am studying", "msc robotics at the university", "computer science background"])
                ]
            )
        }

        if question.contains("python") || question.contains("c++") || question.contains("ros2") || question.contains("rose two") {
            return Profile(
                themes: [
                    Theme(name: "Python", alternatives: ["python"]),
                    Theme(name: "ROS2", alternatives: ["ros2", "rose two"]),
                    Theme(name: "robotics projects", alternatives: ["robotics projects", "robotics project"]),
                    Theme(name: "C++ improving", alternatives: ["c++", "c plus plus", "improving c"]),
                    Theme(name: "performance-critical robotics systems", alternatives: ["performance-critical", "performance critical", "robotics systems"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("questions for us") || question.contains("questions for you") {
            return Profile(
                themes: [
                    Theme(name: "asks about team / evaluation / deployment / success criteria", alternatives: ["ask how", "team", "evaluates", "evaluation", "deployment", "success criteria", "reliable real-world"])
                ],
                wrongIndicators: [
                    Theme(name: "self-introduction answer", alternatives: ["i am currently studying", "msc robotics", "computer science background", "my background"]),
                    Theme(name: "project walkthrough answer", alternatives: ["leorover", "object retrieval robot", "yolov8", "ros2 pipeline"])
                ]
            )
        }

        return Profile(themes: [], wrongIndicators: [])
    }

    private static func roleMotivationIndicators() -> [Theme] {
        [
            Theme(name: "role motivation answer", alternatives: ["i want this role", "join your team", "engineering growth", "deployed systems"])
        ]
    }

    private static func modelComparisonVisibleSayFirstIssue(
        normalizedQuestion: String,
        normalizedSayFirst: String,
        questionIntent: AnswerRelevanceIntent
    ) -> String? {
        let isModelComparisonQuestion = questionIntent == .modelComparison ||
            questionIntent == .diffusionPolicy ||
            (normalizedQuestion.contains("diffusion") &&
             (normalizedQuestion.contains("autoregressive") || normalizedQuestion.contains("auto regressive")))
        guard isModelComparisonQuestion else { return nil }

        let wordCount = normalizedSayFirst.split(whereSeparator: \.isWhitespace).count
        var missing: [String] = []
        if wordCount < 14 {
            missing.append("complete first-person explanation")
        }
        if !normalizedSayFirst.contains("diffusion") {
            missing.append("diffusion")
        }

        let comparesAutoregressive = containsAny(
            normalizedSayFirst,
            [
                "autoregressive",
                "auto regressive",
                "step by step",
                "one step at a time",
                "token by token"
            ]
        )
        if !comparesAutoregressive {
            missing.append("autoregressive comparison")
        }

        let explainsActionMechanism = containsAny(
            normalizedSayFirst,
            [
                "continuous action",
                "action distribution",
                "action sequence",
                "trajectory",
                "denois",
                "refin",
                "full action"
            ]
        )
        let explainsStabilityOutcome = containsAny(
            normalizedSayFirst,
            [
                "smooth",
                "stable",
                "stability",
                "robust",
                "error accumulation",
                "errors accumulate",
                "small errors",
                "reliable"
            ]
        )
        if !explainsActionMechanism {
            missing.append("continuous action or trajectory mechanism")
        }
        if !explainsStabilityOutcome {
            missing.append("stability or robustness outcome")
        }

        let genericPhrases = [
            "i generally work with",
            "i have experience with",
            "i can talk about",
            "i would explain"
        ]
        if genericPhrases.contains(where: { normalizedSayFirst.contains($0) }) {
            missing.append("specific technical comparison")
        }

        guard !missing.isEmpty else { return nil }
        return "visible answer missing \(missing.joined(separator: ", "))."
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func projectOrChallengeIndicators() -> [Theme] {
        [
            Theme(name: "project/challenge answer", alternatives: ["leorover", "hardest technical challenge", "noisy perception", "target localisation"])
        ]
    }

    private static func normalize(_ text: String) -> String {
        " " + text
            .lowercased()
            .replacingOccurrences(of: "c++", with: "c plus plus")
            .replacingOccurrences(of: "ros 2", with: "ros2")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }

    private static func inferredAnswerIntent(for answer: String) -> AnswerRelevanceIntent {
        if answer.contains("i’d like to ask") || answer.contains("i would ask") || answer.contains("how your team") || answer.contains("success criteria") {
            return .candidateQuestions
        }
        if answer.contains("diffusion") || answer.contains("autoregressive") || answer.contains("flow matching") {
            return .modelComparison
        }
        if answer.contains("python") || answer.contains("c plus plus") || answer.contains("ros2") || answer.contains("rose two") {
            return .skillComfort
        }
        if answer.contains("another month") || answer.contains("evaluation pipeline") || answer.contains("failure cases") || answer.contains("reranking") {
            return .improvementPlan
        }
        if answer.contains("noisy detections") || answer.contains("repeated observations") || answer.contains("recovery behaviour") || answer.contains("recovery behavior") {
            return .errorHandling
        }
        if answer.contains("hardest technical challenge") || answer.contains("module integration") || answer.contains("timing mismatch") {
            return .technicalChallenge
        }
        if answer.contains("leorover") || answer.contains("yolov8") || answer.contains("object retrieval robot") {
            return .projectWalkthrough
        }
        if answer.contains("want this role") || answer.contains("interested in this role") || answer.contains("join") && answer.contains("team") {
            return .whyRole
        }
        if answer.contains("msc robotics") || answer.contains("university of manchester") || answer.contains("computer science background") {
            return .tellMeAboutYourself
        }
        return .generic
    }

    private static func reason(
        matchedCount: Int,
        totalCount: Int,
        wrongIndicators: [String],
        questionIntent: AnswerRelevanceIntent,
        answerIntent: AnswerRelevanceIntent
    ) -> String {
        var parts = ["Matched \(matchedCount) of \(totalCount) expected themes."]
        let intentsMatch = questionIntent == answerIntent ||
            (questionIntent == .diffusionPolicy && answerIntent == .modelComparison) ||
            (questionIntent == .modelComparison && answerIntent == .diffusionPolicy)
        if questionIntent != .generic, answerIntent != .generic, !intentsMatch {
            parts.append("Answer intent \(answerIntent.rawValue) differs from question intent \(questionIntent.rawValue).")
        }
        if !wrongIndicators.isEmpty {
            parts.append("Wrong-answer indicators: \(wrongIndicators.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}
