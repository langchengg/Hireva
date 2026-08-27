import Foundation

enum PhDQuestionIntent: String, Codable, CaseIterable {
    // Serialized case names are retained for compatibility with existing
    // diagnostics. Routing and rubric content below are domain-neutral.
    case preMScBackground = "pre_msc_background"
    case llmVlmExperience = "llm_vlm_experience"
    case publicationPlan = "publication_plan"
    case skillFit = "skill_fit"
    case tactileRole = "tactile_role"
    case tactileSlipResponse = "tactile_slip_response"
    case tactileExperience = "tactile_experience"
    case tactileLearningPlan = "tactile_learning_plan"
    case realRobotExperience = "real_robot_experience"
    case robotArchitecture = "robot_architecture"
    case rosControl = "ros_control"
    case graspResearch = "grasp_research"
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

/// Compatibility rubric for answer-shape diagnostics. Question routing uses
/// generic interview forms; candidate facts and opportunity requirements must
/// come from the active context snapshot.
enum PhDInterviewRubricPolicy {
    static func intent(for question: String) -> PhDQuestionIntent? {
        let lower = normalize(question)
        if isLearningPlanQuestion(lower) { return .tactileLearningPlan }
        if isConflictingSignalResponseQuestion(lower) { return .tactileSlipResponse }
        if containsAny(lower, ["what role does", "what function does", "how does this capability help"]) { return .tactileRole }
        if containsAny(lower, ["is there a plan to", "do you plan to", "what is the delivery plan"]) { return .publicationPlan }
        if containsAny(lower, ["skill set", "experience fit", "prepare you for", "relevant to this role"]) { return .skillFit }
        if isSystemArchitectureQuestion(lower) { return .robotArchitecture }
        if isEvidenceScopeQuestion(lower) { return .tactileExperience }
        if isFrameworkBoundaryQuestion(lower) { return .rosControl }
        if isPhysicalSystemExperienceQuestion(lower) { return .realRobotExperience }
        if isBackgroundChronologyQuestion(lower) { return .preMScBackground }
        if isEvaluationPrioritiesQuestion(lower) { return .graspResearch }
        if isCapabilityExperienceQuestion(lower) { return .llmVlmExperience }
        return nil
    }

    static func rubric(for question: String) -> PhDInterviewRubric? {
        guard let intent = intent(for: question) else { return nil }
        switch intent {
        case .preMScBackground:
            return rubric(intent, [["before", "prior", "previous"], ["background", "degree", "experience"], ["transition", "motivated", "led to"]], 2,
                          honesty: "Keep the chronology explicit and use only profile evidence.")
        case .llmVlmExperience:
            return rubric(intent, [["experience", "used", "studied", "worked", "built"], ["project", "research", "work", "service", "system"], ["limit", "new", "learning", "gap", "foundation"]], 2,
                          honesty: "Do not imply duration or expertise not present in candidate evidence.")
        case .publicationPlan:
            return rubric(intent, [["could", "possible", "conditional", "if", "subject to"], ["results", "evaluation", "evidence", "criteria"], ["stakeholder", "review", "scope", "approval"]], 2,
                          avoid: ["is guaranteed", "will definitely"],
                          honesty: "Describe future outcomes as conditional on evidence and review.")
        case .skillFit:
            return rubric(intent, [["evidence", "project", "experience"], ["relevant", "fit", "transfer"], ["gap", "develop", "learn"]], 2,
                          honesty: "Separate supported strengths from development areas.")
        case .tactileRole:
            return rubric(intent, [["role", "function", "feedback"], ["input", "signal", "data", "contact", "force"], ["outcome", "adapt", "decision", "control"], ["limit", "when", "insufficient", "alone"]], 3,
                          honesty: "General knowledge must not be presented as personal implementation experience.")
        case .tactileSlipResponse:
            return rubric(intent, [["signal", "input", "report", "condition"], ["adjust", "adapt", "recover", "retry", "abort", "stop"], ["validate", "confirm", "verify", "monitor", "check"], ["safe", "limit", "fallback", "guard"]], 4,
                          honesty: "Distinguish a proposed method from completed work.")
        case .tactileExperience:
            return rubric(intent, [["experience", "worked", "implemented", "used"], ["evidence", "project", "reading", "documented"], ["limit", "gap", "not yet", "hands on", "scope"]], 2,
                          honesty: "State hands-on scope exactly as recorded in the profile.")
        case .tactileLearningPlan:
            return rubric(intent, [["learn", "develop", "training", "study"], ["experiment", "prototype", "baseline", "calibrate"], ["measure", "validate", "evaluate", "data acquisition", "process"], ["timeline", "milestone", "first", "then", "phase"]], 3,
                          honesty: "Present future work as a plan, not a completed achievement.")
        case .realRobotExperience:
            return rubric(intent, [["platform", "system", "hardware", "physical"], ["role", "implemented", "worked", "controlled", "operated"], ["test", "failure", "validation", "physical"], ["limit", "scope", "team", "boundary"]], 3,
                          honesty: "Use only candidate evidence for systems and personal ownership.")
        case .robotArchitecture:
            return rubric(intent, [["component", "module", "service", "architecture"], ["interface", "message", "handoff", "pipeline"], ["control", "processing", "execution", "decision", "perception", "manipulation"], ["validation", "failure", "recovery", "test"]], 2,
                          honesty: "Do not invent infrastructure, latency, or deployment details.")
        case .rosControl:
            return rubric(intent, [["component", "system", "framework", "runtime"], ["service", "message", "interface", "api", "library", "protocol"], ["control", "coordinate", "execute", "command", "pipeline"], ["debug", "test", "logging", "trace"]], 3,
                          honesty: "Mention a framework or integration technology only when candidate evidence supports it.")
        case .graspResearch:
            return rubric(intent, [["failure", "error", "risk", "problem"], ["method", "approach", "design", "analysis"], ["evaluate", "validate", "test", "metric"], ["limitation", "future", "next", "would", "prioritize", "prioritise"]], 3,
                          honesty: "Do not invent metrics, completed validation, or personal contribution.")
        }
    }

    static func evaluate(question: String, answer: String) -> PhDAnswerQualityResult {
        guard let rubric = rubric(for: question) else {
            return PhDAnswerQualityResult(intent: nil, passed: false, matchedTopicGroups: 0, missingTopicGroups: [], violations: [], firstPerson: false, genericTemplate: false)
        }
        let lower = normalize(answer)
        let matched = rubric.expectedAnswerTopics.filter { group in group.contains { lower.contains($0) } }
        let missing = rubric.expectedAnswerTopics.filter { group in !group.contains { lower.contains($0) } }.map { $0.joined(separator: "/") }
        let violations = rubric.mustAvoid.filter { lower.contains($0) }
        let firstPerson = containsAny(" " + lower + " ", [" i ", " my ", " we ", " our "])
        let generic = QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer)
        return PhDAnswerQualityResult(
            intent: rubric.intent,
            passed: matched.count >= rubric.minimumTopicMatches && violations.isEmpty && firstPerson && !generic,
            matchedTopicGroups: matched.count,
            missingTopicGroups: missing,
            violations: violations,
            firstPerson: firstPerson,
            genericTemplate: generic
        )
    }

    static func promptGuidance(for question: String) -> String {
        guard let rubric = rubric(for: question) else { return "" }
        let topics = rubric.expectedAnswerTopics.map { $0.joined(separator: "/") }.joined(separator: "; ")
        return "Answer-quality criteria: \(topics). Honesty: \(rubric.honestyConstraints.joined(separator: " ")) Personal claims require selected candidate evidence."
    }

    private static func rubric(
        _ intent: PhDQuestionIntent,
        _ topics: [[String]],
        _ minimum: Int,
        avoid: [String] = [],
        honesty: String
    ) -> PhDInterviewRubric {
        PhDInterviewRubric(intent: intent, expectedAnswerTopics: topics, minimumTopicMatches: minimum, mustAvoid: avoid, honestyConstraints: [honesty])
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: " ")
    }

    private static func isLearningPlanQuestion(_ text: String) -> Bool {
        containsAny(text, ["learning plan", "close that skills gap", "close the skills gap", "close the gap", "how would you learn", "how would you develop"]) &&
            containsAny(text, ["how", "plan", "first", "month", "milestone", "develop"])
    }

    private static func isConflictingSignalResponseQuestion(_ text: String) -> Bool {
        let asksForResponse = containsAny(text, ["how should", "how would", "what would you do", "respond", "recover"])
        let namesFailure = containsAny(text, ["failure", "conflict", "unstable", "incorrect", "wrong", "unexpected"])
        let namesConflictingObservations = containsAny(text, ["predicts", "expects"]) && containsAny(text, ["reports", "observes", "measures"])
        return asksForResponse && (namesFailure || namesConflictingObservations)
    }

    private static func isSystemArchitectureQuestion(_ text: String) -> Bool {
        containsAny(text, ["architecture", "components", "modules"]) &&
            containsAny(text, ["describe", "explain", "used", "use", "from", "through", "controlled"])
    }

    private static func isFrameworkBoundaryQuestion(_ text: String) -> Bool {
        containsAny(text, ["framework", "library", "api", "protocol", "runtime"]) &&
            containsAny(text, ["using", "used", "directly", "versus", "rather than", "or were you"])
    }

    private static func isPhysicalSystemExperienceQuestion(_ text: String) -> Bool {
        containsAny(text, ["physical system", "hardware system", "production system", "operated a", "controlled a"]) &&
            containsAny(text, ["experience", "before", "operated", "controlled", "worked"])
    }

    private static func isBackgroundChronologyQuestion(_ text: String) -> Bool {
        containsAny(text, ["before", "prior to", "previous", "earlier"]) &&
            containsAny(text, ["background", "experience", "work", "projects", "prepared"])
    }

    private static func isEvaluationPrioritiesQuestion(_ text: String) -> Bool {
        let prioritisesRisk = containsAny(text, ["failure case", "failure mode", "evaluation risk", "validation risk"]) &&
            containsAny(text, ["prioritise", "prioritize", "evaluate", "validate", "test", "contribution", "method"])
        let asksForContributionEvidence = containsAny(text, ["strongest evidence", "evidence that"]) &&
            containsAny(text, ["contribution", "method", "approach", "work"])
        return prioritisesRisk || asksForContributionEvidence
    }

    private static func isEvidenceScopeQuestion(_ text: String) -> Bool {
        containsAny(text, ["experience", "worked", "hands on", "used"]) &&
            containsAny(text, ["reading", "theory", "documented", "directly", "in practice"])
    }

    private static func isCapabilityExperienceQuestion(_ text: String) -> Bool {
        containsAny(text, ["experience with", "projects with", "worked with", "used", "new to you"]) &&
            containsAny(text, ["experience", "project", "worked", "used", "new"])
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }
}
