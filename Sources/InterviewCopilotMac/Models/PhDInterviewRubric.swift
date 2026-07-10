import Foundation

enum PhDQuestionIntent: String, Codable, CaseIterable {
    case preMScBackground = "pre_msc_background"
    case llmVlmExperience = "llm_vlm_experience"
    case publicationPlan = "publication_plan"
    case skillFit = "skill_fit"
    case tactileRole = "tactile_role"
    case tactileExperience = "tactile_experience"
    case realRobotExperience = "real_robot_experience"
    case robotArchitecture = "robot_architecture"
    case rosControl = "ros_control"
}

struct PhDInterviewRubric: Equatable {
    let intent: PhDQuestionIntent
    let expectedAnswerTopics: [[String]]
    let minimumTopicMatches: Int
    let mustAvoid: [String]
    let honestyConstraints: [String]
}

struct PhDAnswerQualityResult: Equatable {
    let intent: PhDQuestionIntent?
    let passed: Bool
    let matchedTopicGroups: Int
    let missingTopicGroups: [String]
    let violations: [String]
    let firstPerson: Bool
    let genericTemplate: Bool
}

/// De-identified evaluation rubric for the representative PhD dialogue turns.
/// It contains topic constraints, not complete candidate answers.
enum PhDInterviewRubricPolicy {
    static func intent(for question: String) -> PhDQuestionIntent? {
        let lower = normalize(question)
        if lower.contains("tactile"), lower.contains("experience") || lower.contains("from your reading") {
            return .tactileExperience
        }
        if lower.contains("tactile"), lower.contains("role") || lower.contains("play in") {
            return .tactileRole
        }
        if lower.contains("llm") || lower.contains("vlm") {
            return .llmVlmExperience
        }
        if lower.contains("publish") || lower.contains("publication") {
            return .publicationPlan
        }
        if lower.contains("skill set") || lower.contains("experience fit this project") {
            return .skillFit
        }
        if (lower.contains("using ros") || lower.contains("use ros")) && lower.contains("python") {
            return .rosControl
        }
        if lower.contains("which robot") || lower.contains("what architecture") || lower.contains("which platform") {
            return .robotArchitecture
        }
        if lower.contains("controlled a real robot") || lower.contains("control the real robot") {
            return .realRobotExperience
        }
        if lower.contains("prior to your msc") ||
            lower.contains("before manchester") ||
            lower.contains("before your msc") ||
            lower.contains("what was your background") {
            return .preMScBackground
        }
        return nil
    }

    static func rubric(for question: String) -> PhDInterviewRubric? {
        guard let intent = intent(for: question) else { return nil }
        switch intent {
        case .preMScBackground:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["computer science"], ["deep learning", "nlp"], ["before my msc", "prior to my msc", "before manchester"]],
                minimumTopicMatches: 2,
                mustAvoid: ["extensive robotics experience before", "years of robotics before"],
                honestyConstraints: ["Distinguish pre-MSc background from later robotics work."]
            )
        case .llmVlmExperience:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["newer", "new to"], ["nlp", "deep learning"], ["msc", "current"]],
                minimumTopicMatches: 3,
                mustAvoid: ["years of vlm", "extensive vlm experience"],
                honestyConstraints: ["State that LLM/VLM robotics experience is recent."]
            )
        case .publicationPlan:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["possible", "could", "if"], ["dissertation", "benchmark"], ["results", "supervisor", "align"]],
                minimumTopicMatches: 2,
                mustAvoid: ["will definitely publish", "publication is guaranteed", "already published"],
                honestyConstraints: ["Describe publication as conditional, not guaranteed."]
            )
        case .skillFit:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["perception", "visual grounding"], ["manipulation", "grasp"], ["ros2", "real robot"], ["tactile", "world action", "world-action", "growth area"]],
                minimumTopicMatches: 3,
                mustAvoid: ["i am hardworking", "i would answer this directly"],
                honestyConstraints: ["Treat tactile/world-action modelling as a growth area."]
            )
        case .tactileRole:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["contact"], ["force"], ["slip"], ["pressure"], ["adapt", "closed loop", "closed-loop"], ["vision alone"]],
                minimumTopicMatches: 4,
                mustAvoid: [],
                honestyConstraints: ["Explain sensing after contact and closed-loop adaptation."]
            )
        case .tactileExperience:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["reading"], ["not hands on", "not hands-on", "rather than hands on"], ["learn", "develop"], ["perception", "manipulation", "ros2"]],
                minimumTopicMatches: 3,
                mustAvoid: ["extensive hands-on", "years of tactile hardware"],
                honestyConstraints: ["Do not claim hands-on tactile hardware experience."]
            )
        case .realRobotExperience:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["real robot", "robot arm"], ["controlled", "control"], ["current dissertation", "distinct", "physical testing"]],
                minimumTopicMatches: 2,
                mustAvoid: [],
                honestyConstraints: ["Keep prior robot work distinct from the current dissertation."]
            )
        case .robotArchitecture:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["robot arm"], ["ros2"], ["perception", "manipulation", "architecture"]],
                minimumTopicMatches: 3,
                mustAvoid: ["raspberry"],
                honestyConstraints: ["Do not turn an uncertain ASR platform name into a factual claim."]
            )
        case .rosControl:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["ros2"], ["python api", "python apis", "python library"], ["framework", "pipeline", "rather than replacing"]],
                minimumTopicMatches: 3,
                mustAvoid: [],
                honestyConstraints: ["Distinguish ROS2 orchestration from lower-level Python APIs."]
            )
        }
    }

    static func evaluate(question: String, answer: String) -> PhDAnswerQualityResult {
        guard let rubric = rubric(for: question) else {
            let generic = QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer)
            return PhDAnswerQualityResult(
                intent: nil,
                passed: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !generic,
                matchedTopicGroups: 0,
                missingTopicGroups: [],
                violations: [],
                firstPerson: containsFirstPerson(answer),
                genericTemplate: generic
            )
        }

        let lowerAnswer = normalize(answer)
        let matches = rubric.expectedAnswerTopics.map { alternatives in
            alternatives.contains { lowerAnswer.contains(normalize($0)) }
        }
        let missing = zip(rubric.expectedAnswerTopics, matches).compactMap { topics, matched in
            matched ? nil : topics.joined(separator: "/")
        }
        let violations = rubric.mustAvoid.filter { containsUnnegatedClaim(normalize($0), in: lowerAnswer) }
        let firstPerson = containsFirstPerson(answer)
        let generic = QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer)
        let matchCount = matches.filter { $0 }.count
        return PhDAnswerQualityResult(
            intent: rubric.intent,
            passed: matchCount >= rubric.minimumTopicMatches && violations.isEmpty && firstPerson && !generic,
            matchedTopicGroups: matchCount,
            missingTopicGroups: missing,
            violations: violations,
            firstPerson: firstPerson,
            genericTemplate: generic
        )
    }

    static func promptGuidance(for question: String) -> String {
        guard let rubric = rubric(for: question) else { return "" }
        let topics = rubric.expectedAnswerTopics.map { $0.joined(separator: " or ") }.joined(separator: "; ")
        let avoid = rubric.mustAvoid.isEmpty ? "Do not overclaim experience." : "Avoid unsupported claims such as: \(rubric.mustAvoid.joined(separator: "; "))."
        return """
        PhD answer evidence rubric:
        - Cover the relevant evidence areas: \(topics).
        - \(rubric.honestyConstraints.joined(separator: " "))
        - \(avoid)
        """
    }

    private static func containsFirstPerson(_ text: String) -> Bool {
        let normalized = " \(normalize(text)) "
        return normalized.contains(" i ") || normalized.contains(" my ")
    }

    private static func containsUnnegatedClaim(_ claim: String, in answer: String) -> Bool {
        let answerWords = answer.split(separator: " ").map(String.init)
        let claimWords = claim.split(separator: " ").map(String.init)
        guard !claimWords.isEmpty, answerWords.count >= claimWords.count else { return false }
        for start in 0...(answerWords.count - claimWords.count) {
            guard Array(answerWords[start..<(start + claimWords.count)]) == claimWords else { continue }
            let contextStart = max(0, start - 4)
            let prefix = answerWords[contextStart..<start]
            if !prefix.contains(where: { ["not", "no", "never", "without"].contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        ASRCanonicalizer.canonicalizeTerms(text)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
