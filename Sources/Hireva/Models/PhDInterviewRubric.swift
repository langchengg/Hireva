import Foundation

enum PhDQuestionIntent: String, Codable, CaseIterable {
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

/// Optional academic/robotics domain rubric. It contains domain answer-quality
/// criteria only; candidate facts must be supplied and validated by the active
/// context snapshot.
enum PhDInterviewRubricPolicy {
    static func intent(for question: String) -> PhDQuestionIntent? {
        let lower = normalize(question)
        if lower.contains("tactile") && containsAny(lower, ["slip", "slipping", "unstable contact"]) { return .tactileSlipResponse }
        if lower.contains("tactile") && containsAny(lower, ["learning plan", "close the gap", "first six months", "develop experience"]) { return .tactileLearningPlan }
        if lower.contains("tactile") && containsAny(lower, ["experience", "hands on", "worked directly"]) { return .tactileExperience }
        if lower.contains("tactile") && containsAny(lower, ["role", "contact", "force", "pressure"]) { return .tactileRole }
        if containsAny(lower, ["llm", "vlm", "language model", "vision-language"]) { return .llmVlmExperience }
        if containsAny(lower, ["publish", "publication", "paper plan"]) { return .publicationPlan }
        if containsAny(lower, ["skill set", "experience fit", "prepare you for this project"]) { return .skillFit }
        if containsAny(lower, ["robot architecture", "control architecture", "which platform", "which robot"]) { return .robotArchitecture }
        if lower.contains("ros") && containsAny(lower, ["control", "architecture", "python", "c++"]) { return .rosControl }
        if containsAny(lower, ["real robot experience", "controlled a real robot", "physical robot experience"]) { return .realRobotExperience }
        if containsAny(lower, ["before your msc", "prior to your msc", "before the master", "before starting the", "previous academic background"]) &&
            containsAny(lower, ["msc", "master", "programme", "program", "background"]) { return .preMScBackground }
        if lower.contains("what did you do before") && containsAny(lower, ["background", "projects", "experience"]) { return .preMScBackground }
        if (lower.contains("grasp") && containsAny(lower, ["research", "evaluation", "failure case", "contribution"])) ||
            (lower.contains("failure case") && containsAny(lower, ["real robot", "physical system", "deployment"])) { return .graspResearch }
        return nil
    }

    static func rubric(for question: String) -> PhDInterviewRubric? {
        guard let intent = intent(for: question) else { return nil }
        switch intent {
        case .preMScBackground:
            return rubric(intent, [["before", "prior", "previous"], ["background", "degree", "experience"], ["transition", "motivated", "led to"]], 2,
                          honesty: "Keep the chronology explicit and use only profile evidence.")
        case .llmVlmExperience:
            return rubric(intent, [["experience", "used", "studied"], ["project", "research", "work"], ["limit", "new", "learning", "gap"]], 2,
                          honesty: "Do not imply duration or expertise not present in candidate evidence.")
        case .publicationPlan:
            return rubric(intent, [["could", "possible", "conditional", "if"], ["results", "evaluation", "evidence"], ["supervisor", "venue", "scope"]], 2,
                          avoid: ["publication is guaranteed", "will definitely publish"],
                          honesty: "Describe publication as conditional on evidence and supervision.")
        case .skillFit:
            return rubric(intent, [["evidence", "project", "experience"], ["relevant", "fit", "transfer"], ["gap", "develop", "learn"]], 2,
                          honesty: "Separate supported strengths from development areas.")
        case .tactileRole:
            return rubric(intent, [["contact"], ["force", "pressure"], ["slip"], ["feedback", "closed loop", "adapt"]], 3,
                          honesty: "Domain knowledge must not be presented as personal implementation experience.")
        case .tactileSlipResponse:
            return rubric(intent, [["slip", "contact"], ["force", "pressure", "signal"], ["adjust", "adapt", "regrasp", "recover"], ["validate", "threshold", "feedback", "confirm"]], 4,
                          honesty: "Distinguish a proposed method from completed work.")
        case .tactileExperience:
            return rubric(intent, [["experience", "worked", "implemented"], ["evidence", "project", "reading"], ["limit", "gap", "not yet"]], 2,
                          honesty: "State hands-on scope exactly as recorded in the profile.")
        case .tactileLearningPlan:
            return rubric(intent, [["learn", "develop", "training", "study"], ["experiment", "prototype", "baseline", "calibrate"], ["measure", "validate", "evaluate", "data acquisition"], ["timeline", "milestone", "first", "six months"]], 2,
                          honesty: "Present future work as a plan, not a completed achievement.")
        case .realRobotExperience:
            return rubric(intent, [["platform", "system", "hardware", "real robot", "robot arm"], ["role", "implemented", "worked", "controlled"], ["test", "failure", "validation", "physical"], ["limit", "scope", "team"]], 3,
                          honesty: "Use only candidate evidence for platforms and personal ownership.")
        case .robotArchitecture:
            return rubric(intent, [["component", "module", "node", "platform", "robot", "architecture"], ["interface", "message", "handoff", "pipeline"], ["control", "planning", "execution", "perception", "manipulation"], ["validation", "failure", "recovery", "test"]], 2,
                          honesty: "Do not invent hardware, latency, or deployment details.")
        case .rosControl:
            return rubric(intent, [["node", "component", "system", "framework"], ["topic", "service", "message", "interface", "api", "library"], ["control", "coordinate", "execute", "command", "pipeline"], ["debug", "test", "logging"]], 3,
                          honesty: "Mention ROS usage only when candidate evidence supports it.")
        case .graspResearch:
            return rubric(intent, [["failure", "grounding", "collision", "problem"], ["method", "re-ranking", "reranking", "approach"], ["evaluate", "validate", "test", "metric"], ["limitation", "future", "next", "would"]], 3,
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

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }
}
