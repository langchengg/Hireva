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
        incompleteAnswerReason(answer) == nil
    }

    static func incompleteAnswerReason(_ answer: String) -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return "too short" }

        let lower = trimmed.lowercased()
        let lowerWithoutTrailingPunctuation = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;: "))
        let incompleteExactPhrases = [
            "if i had one more month to improve",
            "if i had another month to improve"
        ]
        if incompleteExactPhrases.contains(lowerWithoutTrailingPunctuation) {
            return "ends before naming the improvement target"
        }

        let incompleteWords = ["more", "because", "such as", "including", "whether", "while"]
        for word in incompleteWords {
            if lower.hasSuffix(word) ||
               lower.hasSuffix(word + ".") ||
               lower.hasSuffix(word + ",") ||
               lower.hasSuffix(word + ":") ||
               lower.hasSuffix(word + "...") {
                return "ends with incomplete word '\(word)'"
            }
        }

        if let lastChar = trimmed.last {
            if ",:".contains(lastChar) {
                return "ends with punctuation '\(lastChar)'"
            }
        }

        let words = lower.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count >= 2 {
            let lastTwo = words.suffix(2).joined(separator: " ")
            let incompleteTails = [
                "tend to",
                "be more",
                "such as",
                "including to",
                "more stable",
                "how they",
                "how it",
                "how we",
                "how the",
                "what the",
                "whether the",
                "why the",
                "if the"
            ]
            if incompleteTails.contains(lastTwo) {
                return "ends with incomplete clause '\(lastTwo)'"
            }
        }

        guard let lastChar = trimmed.last, ".?!".contains(lastChar) else {
            return "missing terminal punctuation"
        }

        return nil
    }

    static func usefulInterviewerQuestionCount(in answer: String) -> Int {
        let questionMarkCount = answer.reduce(into: 0) { count, character in
            if character == "?" { count += 1 }
        }
        let words = normalize(answer)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let clauseOpeners: Set<String> = ["what", "how", "which", "who", "where", "when"]
        let distinctClauseCount = words.reduce(into: 0) { count, word in
            if clauseOpeners.contains(word) { count += 1 }
        }
        return questionMarkCount > 0 ? questionMarkCount : distinctClauseCount
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
        if QuestionCompletenessGate.isIncompleteFragment(questionText) {
            return AnswerAlignmentResult(
                score: 0,
                verdict: .mismatched,
                questionIntent: questionIntent,
                answerIntent: answerIntent,
                matchedThemes: [],
                missingThemes: [],
                wrongAnswerIndicators: ["incomplete question fragment"],
                reason: "Rejected alignment for incomplete question fragment."
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
                          questionIntent == .decoderComparison ||
                          questionIntent == .perceptionDebugging ||
                          questionIntent == .technicalTradeoff ||
                          questionIntent == .datasetAdaptation ||
                          questionIntent == .simToRealDebugging ||
                          questionIntent == .projectComparison ||
                          questionIntent == .systemIntegrationDebugging ||
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

        if questionIntent == .decoderComparison {
            let hasProjectGrounding = containsAny(normalizedAnswer, ["mujoco", "vla", "franka"])
            let hasAllDecoderFamilies = containsAny(normalizedAnswer, ["autoregressive", "auto regressive"]) &&
                normalizedAnswer.contains("diffusion") &&
                containsAny(normalizedAnswer, ["flow-matching", "flow matching"])
            let hasDiffusionRate = containsAny(
                normalizedAnswer,
                ["7/10", "7 out of 10", "seven out of ten"]
            )
            let hasWeakerDecoderRate = containsAny(
                normalizedAnswer,
                ["1/10", "1 out of 10", "one out of ten"]
            )
            if !hasProjectGrounding || !hasAllDecoderFamilies || !hasDiffusionRate || !hasWeakerDecoderRate {
                verdict = .mismatched
                finalReason += " Rejected decoder-comparison answer without MuJoCo/VLA grounding, all three decoder families, and the 7/10 vs 1/10 result."
            }
            if wrong.contains("unsupported flow-matching comparable result") {
                verdict = .mismatched
                finalReason += " Rejected unsupported claim that flow-matching had comparable quality."
            }
        }

        if questionIntent == .systemIntegrationDebugging {
            let hasConcreteProject: Bool
            if isRobotDecisionInformationQuestion(normalizedQuestion) {
                hasConcreteProject = containsAny(normalizedAnswer, ["object identity", "target object", "target", "object pose", "target pose", "location", "position"]) &&
                    containsAny(normalizedAnswer, ["navigation", "where to move", "move", "reachability", "reachable", "grasp", "manipulation", "action"])
            } else if isVisualDetectionToPhysicalActionQuestion(normalizedQuestion) {
                hasConcreteProject = containsAny(normalizedAnswer, ["yolov8", "yolo", "visual detection", "object detection", "detections", "detector"]) &&
                    containsAny(normalizedAnswer, ["target pose", "target poses", "object pose", "localisation", "localization", "navigation", "manipulation", "grasp"])
            } else if isPerceptionControlReliabilityQuestion(normalizedQuestion) {
                hasConcreteProject = containsAny(normalizedAnswer, ["perception", "visual", "detection", "camera"]) &&
                    containsAny(normalizedAnswer, ["control", "controller", "action", "motion", "navigation", "manipulation"])
            } else if isRobotSystemArchitectureQuestion(normalizedQuestion) {
                hasConcreteProject = containsAny(normalizedAnswer, ["yolov8", "yolo", "detection", "detector"]) &&
                    containsAny(normalizedAnswer, ["ros2", "target pose", "target poses", "localisation", "localization", "navigation"])
            } else {
                hasConcreteProject = containsAny(normalizedAnswer, ["leorover", "leo rover"]) &&
                    normalizedAnswer.contains("ros2")
            }
            let hasIntegrationWork = containsAny(normalizedAnswer, ["perception", "navigation", "manipulation", "handoff", "module", "pipeline"])
            let hasStarEvidence = containsAny(normalizedAnswer, ["situation", "task", "action", "result", "reproduced", "isolated", "added validation", "validation", "validated", "before acting", "handoff", "recovery"])
            if !hasConcreteProject || !hasIntegrationWork || !hasStarEvidence {
                verdict = .mismatched
                finalReason += " Rejected system-integration answer without concrete perception-to-action, robot-state, or recovery evidence."
            }
        }

        if questionIntent == .technicalChallenge,
           isRealWorldExecutionChallengeQuestion(normalizedQuestion) {
            let hasRealWorldGrounding = containsAny(normalizedAnswer, ["real-world", "real world", "physical robot", "real robot"])
            let hasDifficultyContrast = containsAny(normalizedAnswer, ["simulation", "demo", "clean"]) &&
                containsAny(normalizedAnswer, ["harder", "unpredictable", "less predictable", "noisy", "noise", "drift", "calibration", "timing", "integration"])
            let asksMitigation = containsAny(normalizedQuestion, ["mitigate", "mitigated", "mitigation", "how did you address"])
            let hasMitigation = !asksMitigation ||
                containsAny(normalizedAnswer, ["mitigated", "mitigation", "validation", "validated", "filter", "handoff", "recovery", "retry", "reposition"])

            if !hasRealWorldGrounding || !hasDifficultyContrast || !hasMitigation {
                verdict = .mismatched
                finalReason += " Rejected real-world execution answer without explicit real-world/physical-robot grounding, simulation contrast, and requested mitigation."
            }
        }

        if questionIntent == .improvementPlan,
           normalizedQuestion.contains("leorover"),
           containsWrongLeoRoverImprovementGrounding(normalizedAnswer) {
            verdict = .mismatched
            finalReason += " Rejected wrong project grounding for LeoRover improvement answer."
        }

        if questionIntent == .interviewerQuestions {
            let visibleInterviewerAnswer = sayFirst.isEmpty ? answerText : sayFirst
            if usefulInterviewerQuestionCount(in: visibleInterviewerAnswer) < 2 {
                verdict = .mismatched
                finalReason += " Rejected interviewer-questions answer without at least two distinct useful questions."
            }
            if isEngineeringTeamFitQuestion(normalizedQuestion),
               !containsAny(normalizedAnswer, ["data", "simulation", "infrastructure", "workflow", "workflows"]) {
                verdict = .mismatched
                finalReason += " Rejected engineering-team fit answer without data, simulation, infrastructure, or workflow coverage."
            }
        }

        if questionIntent == .projectComparison {
            let hasVLAPlatform = containsAny(normalizedAnswer, ["vla", "mujoco", "franka", "simulation"])
            let hasVLALearningDetail = containsAny(normalizedAnswer, [
                "droid",
                "decoder",
                "autoregressive",
                "diffusion",
                "flow-matching",
                "vla policy",
                "visuomotor",
                "learning",
                "policy",
                "simulation",
                "simulation evaluation"
            ])
            let hasLeoStack = containsAny(normalizedAnswer, ["leorover", "leo rover", "ros2", "yolov8"])
            let hasLeoExecutionDetail = containsAny(normalizedAnswer, [
                "navigation", "manipulation", "localisation", "localization", "recovery", "real-world", "real world", "real robot", "real-robot"
            ])
            let hasConcreteVLA = containsAny(normalizedAnswer, [
                "mujoco", "franka", "droid", "decoder", "autoregressive", "diffusion", "flow-matching", "visuomotor", "policy", "learning-policy"
            ])
            let hasConcreteLeo = containsAny(normalizedAnswer, [
                "ros2", "yolov8", "navigation", "manipulation", "localisation", "localization", "recovery", "perception-to-action"
            ])
            let hasConcreteContrast = containsAny(normalizedAnswer, ["simulation", "mujoco"]) &&
                containsAny(normalizedAnswer, ["real robot", "real-robot", "real-world", "real world", "physical hardware"])
            if !hasVLAPlatform || !hasVLALearningDetail || !hasLeoStack || !hasLeoExecutionDetail || !hasConcreteVLA || !hasConcreteLeo || !hasConcreteContrast {
                verdict = .mismatched
                finalReason += " Rejected project-comparison answer without concrete VLA learning/simulation and LeoRover real-robot integration details."
            }
        }

        if !sayFirst.isEmpty {
            let trimmedSayFirst = sayFirst.trimmingCharacters(in: .whitespacesAndNewlines)
            if let incompleteReason = incompleteAnswerReason(trimmedSayFirst) {
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

            if let visibleIssue = projectComparisonVisibleSayFirstIssue(
                normalizedQuestion: normalizedQuestion,
                normalizedSayFirst: normalize(trimmedSayFirst),
                questionIntent: questionIntent
            ) {
                verdict = .mismatched
                finalReason += " Rejected project-comparison sayFirst: \(visibleIssue)."
            }

            if let visibleIssue = realWorldExecutionVisibleSayFirstIssue(
                normalizedQuestion: normalizedQuestion,
                normalizedSayFirst: normalize(trimmedSayFirst),
                questionIntent: questionIntent
            ) {
                verdict = .mismatched
                finalReason += " Rejected real-world execution sayFirst: \(visibleIssue)."
            }

            if let visibleIssue = engineeringTeamFitVisibleSayFirstIssue(
                normalizedQuestion: normalizedQuestion,
                normalizedSayFirst: normalize(trimmedSayFirst),
                questionIntent: questionIntent
            ) {
                verdict = .mismatched
                finalReason += " Rejected engineering-team fit sayFirst: \(visibleIssue)."
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
        if question.contains("about yourself") ||
            question.contains("introduce yourself") ||
            question.contains("robotics background") ||
            question.contains("brought you into robotics") {
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

        if isDecoderComparisonQuestion(question) {
            return Profile(
                themes: [
                    Theme(name: "MuJoCo / VLA / Franka setup", alternatives: ["mujoco", "vla", "franka"]),
                    Theme(name: "autoregressive decoder", alternatives: ["autoregressive", "auto regressive"]),
                    Theme(name: "diffusion decoder", alternatives: ["diffusion"]),
                    Theme(name: "flow-matching decoder", alternatives: ["flow-matching", "flow matching"]),
                    Theme(name: "success or performance comparison", alternatives: ["7/10", "seven out of ten", "1/10", "one out of ten", "performed best", "weaker", "success"]),
                    Theme(name: "lesson about trajectory generation", alternatives: ["learned", "lesson", "architecture choice", "trajectory", "continuous action", "action sequence", "action generation"])
                ],
                wrongIndicators: roleMotivationIndicators() + [
                    Theme(name: "unsupported flow-matching comparable result", alternatives: ["flow-matching offered faster sampling with comparable quality", "flow matching offered faster sampling with comparable quality", "comparable quality"])
                ]
            )
        }

        if isPerceptionDebuggingQuestion(question) {
            return Profile(
                themes: [
                    Theme(name: "YOLOv8 / detector", alternatives: ["yolov8", "yolo", "detector", "detection"]),
                    Theme(name: "wrong confident prediction", alternatives: ["wrong prediction", "confident but wrong", "false positive", "class confusion"]),
                    Theme(name: "inspect frames/logs", alternatives: ["inspect", "frame", "frames", "logs", "reproduce"]),
                    Theme(name: "boxes/classes/confidence", alternatives: ["bounding box", "bounding boxes", "classes", "class", "confidence"]),
                    Theme(name: "calibration/lighting/occlusion", alternatives: ["calibration", "lighting", "glare", "occlusion", "motion blur"]),
                    Theme(name: "spatial/temporal consistency", alternatives: ["spatial", "temporal", "depth", "localisation", "localization", "consistency"]),
                    Theme(name: "validate/recover before retraining", alternatives: ["recovery", "recover", "validation", "validate", "before retraining", "before deciding whether retraining", "retrain only"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("technical trade-off") ||
            question.contains("technical tradeoff") ||
            question.contains("trade off") && question.contains("robotics") {
            return Profile(
                themes: [
                    Theme(name: "trade-off", alternatives: ["trade-off", "tradeoff", "trade off"]),
                    Theme(name: "robustness / reliability", alternatives: ["robustness", "robust", "reliability", "reliable"]),
                    Theme(name: "latency / complexity", alternatives: ["latency", "complexity", "complex"]),
                    Theme(name: "concrete robotics project", alternatives: ["leorover", "vla", "mujoco", "robotics project", "real robot"]),
                    Theme(name: "decision made", alternatives: ["chose", "choice", "decision", "prioritized", "prioritised", "practical filtering", "recovery"]),
                    Theme(name: "lesson learned", alternatives: ["learned", "lesson", "mattered", "reliable execution"])
                ],
                wrongIndicators: roleMotivationIndicators() + [
                    Theme(name: "unrelated data pipeline answer", alternatives: ["data pipeline", "10,000 records", "10000 records", "database pipeline", "etl"])
                ]
            )
        }

        if question.contains("droid") && (question.contains("mujoco") || question.contains("franka") || question.contains("trajector")) {
            return Profile(
                themes: [
                    Theme(name: "DROID demonstrations", alternatives: ["droid", "demonstrations", "real-robot trajectories", "real robot trajectories"]),
                    Theme(name: "MuJoCo / Franka simulation", alternatives: ["mujoco", "franka", "simulator", "simulation"]),
                    Theme(name: "mapping actions/observations", alternatives: ["mapped", "mapping", "actions", "observations", "simulator format"]),
                    Theme(name: "coordinate/timing consistency", alternatives: ["coordinate", "timing", "frames", "consistency"]),
                    Theme(name: "validation", alternatives: ["validated", "validation", "matched the manipulation objective", "before training", "before evaluation"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("sim-to-real") ||
            question.contains("sim to real") ||
            question.contains("policy works in mujoco") ||
            question.contains("fails on a real robot") {
            return Profile(
                themes: [
                    Theme(name: "compare sim and real", alternatives: ["compare", "sim and real", "simulator and real", "mujoco", "real-robot", "real robot"]),
                    Theme(name: "observations/actions/timing", alternatives: ["observations", "action scaling", "actions", "timing", "latency"]),
                    Theme(name: "calibration/dynamics", alternatives: ["calibration", "contact dynamics", "dynamics mismatch"]),
                    Theme(name: "failure inspection", alternatives: ["failure videos", "inspect", "failure", "logs"]),
                    Theme(name: "isolate root cause", alternatives: ["isolate", "perception", "control", "distribution shift", "before changing", "before retraining"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("difference between") && question.contains("vla") && question.contains("leorover") {
            return Profile(
                themes: [
                    Theme(name: "VLA project", alternatives: ["vla", "learning-policy", "policy", "action decoder", "action decoders"]),
                    Theme(name: "MuJoCo / Franka evaluation", alternatives: ["mujoco", "franka", "simulation evaluation"]),
                    Theme(name: "LeoRover project", alternatives: ["leorover", "real-robot", "real robot", "real-world", "real world"]),
                    Theme(name: "ROS2 / YOLOv8 / navigation", alternatives: ["ros2", "yolov8", "perception", "navigation", "localisation", "localization"]),
                    Theme(name: "core difference", alternatives: ["difference", "while", "versus", "whereas", "learning-policy evaluation", "system integration", "simulation", "real-world", "real world"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if isRobotDecisionInformationQuestion(question) {
            return Profile(
                themes: [
                    Theme(name: "object identity / target", alternatives: ["object identity", "target object", "target", "object"]),
                    Theme(name: "pose / position / location", alternatives: ["pose", "position", "location", "target pose", "object pose"]),
                    Theme(name: "spatial relationship / distance", alternatives: ["spatial", "distance", "frame", "robot state", "world frame"]),
                    Theme(name: "reachability", alternatives: ["reachability", "reachable", "feasible"]),
                    Theme(name: "navigation target", alternatives: ["navigation", "where to move", "move"]),
                    Theme(name: "grasp / action decision", alternatives: ["grasp", "manipulation", "action", "before acting"])
                ],
                wrongIndicators: roleMotivationIndicators() + [
                    Theme(name: "generic interview coaching", alternatives: ["answer this directly", "concrete example from experience", "outcome or lesson learned"])
                ]
            )
        }

        if isVisualDetectionToPhysicalActionQuestion(question) {
            return Profile(
                themes: [
                    Theme(name: "visual / object detection", alternatives: ["visual detection", "visual detections", "object detection", "detections", "yolov8", "detector"]),
                    Theme(name: "target / object", alternatives: ["target object", "target", "object"]),
                    Theme(name: "pose / localisation", alternatives: ["target pose", "object pose", "localisation", "localization", "position", "location"]),
                    Theme(name: "navigation / movement", alternatives: ["navigation", "navigate", "move"]),
                    Theme(name: "manipulation / grasp", alternatives: ["manipulation", "grasp", "pick"]),
                    Theme(name: "action/control pipeline", alternatives: ["physical action", "actions", "control", "pipeline", "ros2"]),
                    Theme(name: "validation / recovery", alternatives: ["validation", "validated", "recovery", "retry", "before acting"])
                ],
                wrongIndicators: roleMotivationIndicators() + [
                    Theme(name: "generic interview coaching", alternatives: ["answer this directly", "concrete example from experience", "outcome or lesson learned"])
                ]
            )
        }

        if isPerceptionControlReliabilityQuestion(question) {
            return Profile(
                themes: [
                    Theme(name: "perception signal", alternatives: ["perception", "visual", "detection", "camera"]),
                    Theme(name: "control/action execution", alternatives: ["control", "controller", "action", "motion", "navigation", "manipulation"]),
                    Theme(name: "target state", alternatives: ["target pose", "action goal", "robot state", "pose", "state estimate"]),
                    Theme(name: "validation/timing", alternatives: ["validation", "validated", "confidence", "timing", "latency", "before moving", "before acting"]),
                    Theme(name: "reliability challenge", alternatives: ["reliable", "reliability", "difficult", "calibration", "noisy", "frame transform"])
                ],
                wrongIndicators: roleMotivationIndicators() + [
                    Theme(name: "generic interview coaching", alternatives: ["answer this directly", "concrete example from experience", "outcome or lesson learned"])
                ]
            )
        }

        if isRobotPerceptionToNavigationQuestion(question) {
            return Profile(
                themes: [
                    Theme(name: "YOLOv8 / detection", alternatives: ["yolov8", "yolo", "detection", "detector"]),
                    Theme(name: "target object / pose", alternatives: ["target object", "target pose", "target poses", "object detections", "detections"]),
                    Theme(name: "localisation / localization", alternatives: ["localisation", "localization", "localise", "localize"]),
                    Theme(name: "navigation", alternatives: ["navigation", "navigate"]),
                    Theme(name: "pipeline / validation", alternatives: ["pipeline", "ros2", "validated", "validation", "robot state"])
                ],
                wrongIndicators: roleMotivationIndicators() + [
                    Theme(name: "unrelated VLA/DROID answer", alternatives: ["droid", "mujoco", "franka", "diffusion decoder"])
                ]
            )
        }

        if isRobotSystemArchitectureQuestion(question) {
            return Profile(
                themes: [
                    Theme(name: "YOLOv8 / detection", alternatives: ["yolov8", "yolo", "detection", "detector"]),
                    Theme(name: "localisation / localization", alternatives: ["localisation", "localization", "localise", "localize", "target pose", "target poses"]),
                    Theme(name: "navigation", alternatives: ["navigation", "navigate"]),
                    Theme(name: "manipulation", alternatives: ["manipulation", "manipulator", "grasp", "pick"]),
                    Theme(name: "recovery behavior", alternatives: ["recovery", "recover", "retry", "fallback"]),
                    Theme(name: "module handoff / validation", alternatives: ["handoff", "handoffs", "validated", "validation", "robot state", "ros2"])
                ],
                wrongIndicators: roleMotivationIndicators() + [
                    Theme(name: "interviewer-questions answer", alternatives: ["questions i would ask", "ask the engineering team", "success criteria"]),
                    Theme(name: "unrelated VLA/DROID answer", alternatives: ["droid", "mujoco", "franka", "diffusion decoder"])
                ]
            )
        }

        if question.contains("system integration problem") ||
            question.contains("debug a system integration") {
            return Profile(
                themes: [
                    Theme(name: "system integration", alternatives: ["system integration", "work together", "full system", "module boundaries"]),
                    Theme(name: "module logs/timestamps", alternatives: ["logs", "timestamps", "module logs"]),
                    Theme(name: "reproduce/isolate", alternatives: ["reproduced", "reproduce", "isolated", "isolate"]),
                    Theme(name: "perception/navigation/manipulation handoff", alternatives: ["perception", "navigation", "manipulation", "handoff", "handoffs"]),
                    Theme(name: "recovery/reliability", alternatives: ["recovery", "validation", "reliable", "reliably"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("another month") || question.contains("change first") || question.contains("improve first") {
            return Profile(
                themes: [
                    Theme(name: "LeoRover grounding", alternatives: ["leorover", "leo rover"]),
                    Theme(name: "improve evaluation", alternatives: ["improve the evaluation", "strengthen the evaluation", "make the evaluation", "evaluation pipeline"]),
                    Theme(name: "more objects / positions / failure cases", alternatives: ["more objects", "initial positions", "failure cases"]),
                    Theme(name: "robust perception", alternatives: ["robust perception", "perception robustness"]),
                    Theme(name: "confidence / spatial consistency", alternatives: ["confidence", "spatial consistency", "calibration", "latency"]),
                    Theme(name: "closed-loop recovery", alternatives: ["closed-loop", "closed loop", "recovery", "missed detections", "failed grasps"])
                ],
                wrongIndicators: [
                    Theme(name: "wrong project grounding", alternatives: [
                        "semantic-geometric",
                        "semantic geometric",
                        "re-ranker",
                        "reranker",
                        "vlm grasping",
                        "target-conditioned",
                        "target conditioned",
                        "grasp scorer",
                        "thesis"
                    ])
                ]
            )
        }

        if question.contains("leorover") || question.contains("leo rover") || question.contains("walk me through") {
            return Profile(
                themes: [
                    Theme(name: "LeoRover / rover project", alternatives: ["leorover", "leo rover", "rover project"]),
                    Theme(name: "autonomous object retrieval robot", alternatives: ["autonomous object retrieval", "object retrieval robot", "object retrieval"]),
                    Theme(name: "ROS2", alternatives: ["ros2", "rose two"]),
                    Theme(name: "YOLOv8 / perception", alternatives: ["yolov8", "yolo", "perception", "object detection"]),
                    Theme(name: "navigation / localisation", alternatives: ["navigation", "navigate", "localisation", "localization"]),
                    Theme(name: "manipulation / pick-up", alternatives: ["manipulation", "manipulator", "pick up", "pick-up", "pickup"]),
                    Theme(name: "real robot execution", alternatives: ["real robot", "physical robot", "real-world", "real world", "deployment"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("hardest technical challenge") ||
            question.contains("hardest challenge") ||
            question.contains("pipeline was most fragile") ||
            question.contains("most fragile") ||
            question.contains("real robot execution") ||
            question.contains("real-world execution") ||
            question.contains("real world execution") ||
            question.contains("clean demo") ||
            question.contains("clean simulation") {
            return Profile(
                themes: [
                    Theme(name: "module integration", alternatives: ["module integration", "integrating modules", "modules work", "coordination between perception", "coordination between"]),
                    Theme(name: "sensor / perception noise", alternatives: ["sensor noise", "noisy perception", "noisy detections", "noisy inputs", "perception"]),
                    Theme(name: "localisation / drift / calibration", alternatives: ["localisation instability", "localization instability", "localisation was not stable", "localization was not stable", "camera", "imu", "drift", "calibration", "recalibrate"]),
                    Theme(name: "timing mismatch", alternatives: ["timing mismatch", "timing mismatches", "timing between"]),
                    Theme(name: "real robot unpredictability", alternatives: ["real robot", "real-world", "real world", "unpredictable", "less predictable", "simulation vs real world", "clean demo", "clean simulation"]),
                    Theme(name: "navigation / manipulation coordination", alternatives: ["navigation", "manipulation", "handoff", "handoffs", "filtering", "stabilized", "stabilised"]),
                    Theme(name: "mitigation / recovery", alternatives: ["mitigated", "mitigation", "validation", "recovery", "retrying", "repositioning", "before acting"])
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
                    Theme(name: "continuous action distribution", alternatives: ["continuous action", "action distribution", "action sequence", "action sequences", "action trajectory", "whole action trajectory", "trajectory distribution", "full trajectory", "continuous manipulation"]),
                    Theme(name: "robustness / stability", alternatives: ["robust", "robustness", "stable", "stability", "jitter", "instability"]),
                    Theme(name: "7/10 success", alternatives: ["seven out of ten", "7 out of 10", "7/10", "higher success rate", "higher success rates"]),
                    Theme(name: "autoregressive / flow-matching comparison", alternatives: ["autoregressive", "auto regressive", "flow matching", "flow-matching", "compounding error", "compound errors", "accumulate errors", "error accumulation", "step-by-step", "step by step"])
                ],
                wrongIndicators: roleMotivationIndicators()
            )
        }

        if question.contains("questions for us") ||
            question.contains("questions for you") ||
            question.contains("what questions would you ask us") ||
            question.contains("what would you ask the engineering team") ||
            (question.contains("ask the engineering team") && question.contains("good fit")) ||
            question.contains("before accepting an offer") {
            return Profile(
                themes: [
                    Theme(name: "success criteria", alternatives: ["success criteria", "what success looks like", "what would success", "first three months", "first 3 months"]),
                    Theme(name: "deployment challenges", alternatives: ["deployment challenges", "deploy", "real-world deployment", "reliable real-world"]),
                    Theme(name: "team structure", alternatives: ["team structure", "team is structured", "robotics team is structured", "responsibilities are split", "perception", "autonomy", "product engineering"]),
                    Theme(name: "data/simulation infrastructure", alternatives: ["data", "simulation", "infrastructure"]),
                    Theme(name: "ownership", alternatives: ["ownership", "own", "responsibilities", "ownership expectations", "production workflows"])
                ],
                wrongIndicators: [
                    Theme(name: "self-introduction answer", alternatives: ["i am currently studying", "msc robotics", "computer science background", "my background"]),
                    Theme(name: "project walkthrough answer", alternatives: ["object retrieval robot", "ros2 pipeline"]),
                    Theme(name: "vague meta-answer", alternatives: ["yes, i'd love to ask a question", "yes i would love to ask a question", "i'd love to ask a question"])
                ]
            )
        }

        if question.contains("why do you want") || question.contains("join our team") || question.contains("this role") {
            return Profile(
                themes: [
                    Theme(name: "role / team interest", alternatives: ["drawn to", "interested in your team", "interested in this role", "role connects", "join your team", "join the team", "want this role", "want to join"]),
                    Theme(name: "mission / company direction", alternatives: ["mission", "company direction", "product direction", "your focus", "your work"]),
                    Theme(name: "robotics / AI / perception", alternatives: ["robotics", " ai ", "embodied ai", "perception", "vla", "foundation models"]),
                    Theme(name: "real-world deployment", alternatives: ["real robot", "real-world robotics", "real world robotics", "deployment", "deployed", "practical robotics", "practical", "real environments"]),
                    Theme(name: "logistics / warehouse domain", alternatives: ["logistics", "warehouse"]),
                    Theme(name: "experience alignment", alternatives: ["aligns perfectly", "aligns with", "matches my work", "connects with my work", "my experience"]),
                    Theme(name: "contribution / growth", alternatives: ["contribute", "help build", "build world", "grow with the team", "engineering growth", "engineering ability", "growth"])
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
            questionIntent == .decoderComparison ||
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
                "step-by-step",
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

    private static func projectComparisonVisibleSayFirstIssue(
        normalizedQuestion: String,
        normalizedSayFirst: String,
        questionIntent: AnswerRelevanceIntent
    ) -> String? {
        guard questionIntent == .projectComparison,
              normalizedQuestion.contains("vla"),
              normalizedQuestion.contains("leorover") || normalizedQuestion.contains("leo rover") else {
            return nil
        }

        var missing: [String] = []
        if !normalizedSayFirst.contains("vla") {
            missing.append("VLA")
        }
        if !containsAny(normalizedSayFirst, ["leorover", "leo rover"]) {
            missing.append("LeoRover")
        }
        if !containsAny(normalizedSayFirst, ["mujoco", "franka", "simulation"]) {
            missing.append("simulation/MuJoCo/Franka side")
        }
        if !containsAny(normalizedSayFirst, ["ros2", "yolov8", "navigation", "manipulation", "localisation", "localization"]) {
            missing.append("LeoRover stack detail")
        }
        if !containsAny(normalizedSayFirst, ["real robot", "real-robot", "real-world", "real world", "physical hardware"]) {
            missing.append("real-robot execution side")
        }
        if !containsAny(normalizedSayFirst, ["difference", "while", "whereas", "versus", "compared", "contrast"]) {
            missing.append("explicit contrast")
        }

        guard !missing.isEmpty else { return nil }
        return "visible answer missing \(missing.joined(separator: ", "))."
    }

    private static func realWorldExecutionVisibleSayFirstIssue(
        normalizedQuestion: String,
        normalizedSayFirst: String,
        questionIntent: AnswerRelevanceIntent
    ) -> String? {
        guard questionIntent == .technicalChallenge,
              isRealWorldExecutionChallengeQuestion(normalizedQuestion) else {
            return nil
        }

        var missing: [String] = []
        if !containsAny(normalizedSayFirst, ["real-world", "real world", "physical robot", "real robot"]) {
            missing.append("real-world/physical-robot grounding")
        }
        if !containsAny(normalizedSayFirst, ["simulation", "demo", "clean"]) {
            missing.append("simulation/demo contrast")
        }
        if !containsAny(normalizedSayFirst, ["lighting", "calibration", "noise", "noisy", "occlusion", "latency", "timing", "drift", "integration"]) {
            missing.append("real execution difficulty")
        }
        if !containsAny(normalizedSayFirst, ["recovery", "robust", "reliable", "failure", "retry", "reposition", "validation", "validated", "filter"]) {
            missing.append("recovery or robustness")
        }

        guard !missing.isEmpty else { return nil }
        return "visible answer missing \(missing.joined(separator: ", "))."
    }

    private static func engineeringTeamFitVisibleSayFirstIssue(
        normalizedQuestion: String,
        normalizedSayFirst: String,
        questionIntent: AnswerRelevanceIntent
    ) -> String? {
        guard questionIntent == .interviewerQuestions,
              isEngineeringTeamFitQuestion(normalizedQuestion) else {
            return nil
        }
        guard !containsAny(normalizedSayFirst, ["data", "simulation", "infrastructure", "workflow", "workflows"]) else {
            return nil
        }
        return "visible answer missing data/simulation/infrastructure/workflow coverage."
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func containsWrongLeoRoverImprovementGrounding(_ text: String) -> Bool {
        containsAny(text, [
            "semantic-geometric",
            "semantic geometric",
            "re-ranker",
            "reranker",
            "vlm grasping",
            "target-conditioned",
            "target conditioned",
            "grasp scorer",
            "thesis"
        ])
    }

    private static func projectOrChallengeIndicators() -> [Theme] {
        [
            Theme(name: "project/challenge answer", alternatives: ["leorover", "hardest technical challenge", "noisy perception", "target localisation"])
        ]
    }

    private static func normalize(_ text: String) -> String {
        " " + ASRCanonicalizer.canonicalizeTerms(text)
            .lowercased()
            .replacingOccurrences(of: "c++", with: "c plus plus")
            .replacingOccurrences(of: "ros 2", with: "ros2")
            .replacingOccurrences(of: "flow matching", with: "flow-matching")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }

    private static func inferredAnswerIntent(for answer: String) -> AnswerRelevanceIntent {
        if answer.contains("what would success") ||
            answer.contains("first three months") ||
            answer.contains("first 3 months") ||
            answer.contains("team is structured") ||
            answer.contains("deployment challenges") ||
            answer.contains("production workflows") {
            return .interviewerQuestions
        }
        if answer.contains("droid") &&
            (answer.contains("mujoco") || answer.contains("franka") || answer.contains("demonstration") || answer.contains("trajectory")) {
            return .datasetAdaptation
        }
        if answer.contains("sim-to-real") ||
            answer.contains("sim and real") ||
            answer.contains("simulator and real") ||
            answer.contains("contact dynamics") ||
            answer.contains("dynamics mismatch") ||
            answer.contains("distribution shift") {
            return .simToRealDebugging
        }
        if answer.contains("vla") &&
            answer.contains("leorover") &&
            (answer.contains("difference") ||
                answer.contains("while") ||
                answer.contains("versus") ||
                answer.contains("whereas") ||
                (answer.contains("simulation") && containsAny(answer, ["real-world", "real world", "real robot", "real-robot"]))) {
            return .projectComparison
        }
        if (answer.contains("leorover project") || answer.contains("autonomous object retrieval robot")) &&
            containsAny(answer, ["ros2", "yolov8", "navigation", "localisation", "localization", "manipulation"]) {
            return .projectWalkthrough
        }
        if answer.contains("mujoco") &&
            (answer.contains("vla") || answer.contains("franka")) &&
            answer.contains("diffusion") &&
            answer.contains("autoregressive") &&
            (answer.contains("flow-matching") || answer.contains("flow matching")) {
            return .decoderComparison
        }
        if isRobotSystemArchitectureQuestion(answer) {
            return .systemIntegrationDebugging
        }
        if isVisualDetectionToPhysicalActionQuestion(answer) ||
            isRobotDecisionInformationQuestion(answer) ||
            isPerceptionControlReliabilityQuestion(answer) {
            return .systemIntegrationDebugging
        }
        if (answer.contains("yolov8") || answer.contains("detector")) &&
            (answer.contains("wrong prediction") || answer.contains("false positive") || answer.contains("confident but wrong") || answer.contains("debug")) {
            return .perceptionDebugging
        }
        if (answer.contains("trade-off") || answer.contains("tradeoff") || answer.contains("trade off")) &&
            (answer.contains("robustness") || answer.contains("latency") || answer.contains("complexity") || answer.contains("reliability")) {
            return .technicalTradeoff
        }
        if (answer.contains("system integration") || answer.contains("work together") || answer.contains("module boundaries") || answer.contains("handoff")) &&
            (answer.contains("logs") || answer.contains("timestamps") || answer.contains("reproduced") || answer.contains("isolated") || answer.contains("recovery")) {
            return .systemIntegrationDebugging
        }
        if answer.contains("i’d like to ask") || answer.contains("i would ask") || answer.contains("how your team") || answer.contains("success criteria") {
            return .candidateQuestions
        }
        if answer.contains("diffusion") || answer.contains("autoregressive") || answer.contains("flow matching") {
            return .modelComparison
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
        if answer.contains("leorover") || answer.contains("yolov8") || answer.contains("object retrieval robot") || answer.contains("object retrieval") {
            return .projectWalkthrough
        }
        if answer.contains("want this role") ||
            answer.contains("interested in this role") ||
            answer.contains("drawn to") ||
            answer.contains("mission") ||
            answer.contains("aligns with") ||
            answer.contains("aligns perfectly") ||
            answer.contains("join") && answer.contains("team") ||
            answer.contains("help build") && (answer.contains("robot") || answer.contains("logistics") || answer.contains("team")) {
            return .whyRole
        }
        if answer.contains("python") || answer.contains("c plus plus") || answer.contains("ros2") || answer.contains("rose two") {
            return .skillComfort
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
            (questionIntent == .modelComparison && answerIntent == .diffusionPolicy) ||
            (questionIntent == .decoderComparison && answerIntent == .modelComparison) ||
            (questionIntent == .modelComparison && answerIntent == .decoderComparison) ||
            (questionIntent == .candidateQuestions && answerIntent == .interviewerQuestions) ||
            (questionIntent == .interviewerQuestions && answerIntent == .candidateQuestions)
        if questionIntent != .generic, answerIntent != .generic, !intentsMatch {
            parts.append("Answer intent \(answerIntent.rawValue) differs from question intent \(questionIntent.rawValue).")
        }
        if !wrongIndicators.isEmpty {
            parts.append("Wrong-answer indicators: \(wrongIndicators.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    private static func isDecoderComparisonQuestion(_ question: String) -> Bool {
        let modelTerms = ["autoregressive", "diffusion", "flow-matching"].filter { question.contains($0) }.count
        return modelTerms >= 2 &&
            (question.contains("mujoco") || question.contains("vla") || question.contains("franka") || question.contains("decoder")) &&
            (question.contains("what did you learn") || question.contains("comparing") || question.contains("compared"))
    }

    private static func isPerceptionDebuggingQuestion(_ question: String) -> Bool {
        let mentionsDetector = question.contains("yolov8") ||
            question.contains("detector") ||
            question.contains("prediction")
        let mentionsDebugging = question.contains("debug") ||
            question.contains("confident but wrong") ||
            question.contains("wrong prediction") ||
            question.contains("false positive")
        return mentionsDetector && mentionsDebugging
    }

    private static func isRobotSystemArchitectureQuestion(_ question: String) -> Bool {
        let mentionsDetector = question.contains("yolov8") ||
            question.contains("detector") ||
            question.contains("detection")
        let mentionsSystemFlow = question.contains("connect") ||
            question.contains("connected") ||
            question.contains("pipeline") ||
            question.contains("system")
        let downstreamModules = [
            "localization",
            "localisation",
            "navigation",
            "manipulation",
            "recovery"
        ].filter { question.contains($0) }.count
        return mentionsDetector && mentionsSystemFlow && downstreamModules >= 3
    }

    private static func isVisualDetectionToPhysicalActionQuestion(_ question: String) -> Bool {
        let mentionsVisualDetection = question.contains("visual detection") ||
            question.contains("visual detections") ||
            question.contains("object detection") ||
            question.contains("detections")
        let asksTransformation = question.contains("transformed") ||
            question.contains("transform") ||
            question.contains("turn") ||
            question.contains("converted") ||
            question.contains("map")
        let mentionsPhysicalAction = question.contains("physical action") ||
            question.contains("physical actions") ||
            question.contains("real world") ||
            question.contains("real-world") ||
            question.contains("robot")
        return mentionsVisualDetection && asksTransformation && mentionsPhysicalAction
    }

    private static func isRobotDecisionInformationQuestion(_ question: String) -> Bool {
        let asksInformation = question.contains("what information") ||
            question.contains("information did the robot need") ||
            question.contains("robot need before")
        let mentionsMove = question.contains("where to move") ||
            question.contains("move") ||
            question.contains("navigation target")
        let mentionsGrasp = question.contains("what to grasp") ||
            question.contains("grasp") ||
            question.contains("pick")
        return asksInformation && mentionsMove && mentionsGrasp
    }

    private static func isPerceptionControlReliabilityQuestion(_ question: String) -> Bool {
        let mentionsPerception = question.contains("perception") ||
            question.contains("visual") ||
            question.contains("detection")
        let mentionsControl = question.contains("control") ||
            question.contains("controller") ||
            question.contains("action")
        let asksReliability = question.contains("difficult") ||
            question.contains("reliable") ||
            question.contains("reliability") ||
            question.contains("why was")
        return mentionsPerception && mentionsControl && asksReliability
    }

    private static func isRealWorldExecutionChallengeQuestion(_ question: String) -> Bool {
        containsAny(question, [
            "real-world execution",
            "real world execution",
            "real robot execution",
            "clean simulation",
            "demo environment",
            "clean demo"
        ])
    }

    private static func isEngineeringTeamFitQuestion(_ question: String) -> Bool {
        question.contains("what would you ask the engineering team") ||
            (question.contains("ask the engineering team") && question.contains("good fit"))
    }

    private static func isRobotPerceptionToNavigationQuestion(_ question: String) -> Bool {
        let mentionsDetector = question.contains("yolov8") ||
            question.contains("detector") ||
            question.contains("detection") ||
            question.contains("object detection")
        let mentionsTargetSelection = question.contains("identify") ||
            question.contains("target object") ||
            question.contains("target pose") ||
            question.contains("target poses") ||
            question.contains("object before")
        let mentionsDownstreamMotion = (
            question.contains("localization") ||
            question.contains("localisation")
        ) && question.contains("navigation")
        return mentionsDetector && mentionsTargetSelection && mentionsDownstreamMotion
    }
}
