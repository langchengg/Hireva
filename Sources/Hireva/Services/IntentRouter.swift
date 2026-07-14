import Foundation

/// Domain-neutral routing for accepted interview questions. Specific tools,
/// projects, organisations, and metrics remain data supplied by the selected
/// context snapshot rather than routing constants.
enum IntentRouter {
    static func answerIntent(for questionText: String) -> AnswerRelevanceIntent {
        let text = normalize(questionText)
        if containsAny(text, ["what questions would you ask", "what would you ask the", "before accepting an offer"]) {
            return .interviewerQuestions
        }
        if containsAny(text, ["questions for us", "questions for you", "do you have any questions"]) {
            return .candidateQuestions
        }
        if containsAny(text, ["about yourself", "introduce yourself", "walk me through your background"]) {
            return .tellMeAboutYourself
        }
        if containsAny(text, ["why do you want", "why this role", "join our team", "interested in this role"]) {
            return .whyRole
        }
        if isProjectComparisonQuestion(text) { return .projectComparison }
        if isDecoderComparisonQuestion(text) { return .decoderComparison }
        let modelFamilyCount = ["autoregressive", "diffusion", "flow matching", "flow-matching", "transformer", "regression", "classifier"]
            .filter { text.contains($0) }.count
        if modelFamilyCount >= 2 && containsAny(text, [
            "better", "worse", "perform", "compare", "trade-off", "tradeoff",
            "more stable", "less stable", "more reliable", "less reliable"
        ]) {
            return .modelComparison
        }
        if containsAny(text, ["sim-to-real", "sim to real", "simulation to production", "works in simulation", "fails in production"]) {
            return .simToRealDebugging
        }
        if isPerceptionDebuggingQuestion(text) { return .perceptionDebugging }
        if containsAny(text, ["control architecture", "system architecture", "technical architecture"]) {
            return .systemIntegrationDebugging
        }
        if text.contains("system integration") && containsAny(text, ["debug", "failure", "problem", "issue"]) {
            return .systemIntegrationDebugging
        }
        if containsAny(text, ["hardest technical challenge", "hardest challenge", "technically difficult", "most difficult", "most fragile"]) || isRealWorldExecutionQuestion(text) {
            return .technicalChallenge
        }
        if isSystemIntegrationFamilyQuestion(text) { return .systemIntegrationDebugging }
        if containsAny(text, ["dataset adaptation", "adapt the dataset", "migrate the data", "mapped the data", "data format"]) ||
            (containsAny(text, ["adapt", "mapped", "converted", "migrated"]) && containsAny(text, ["data", "dataset", "trajector", "records", "format"])) {
            return .datasetAdaptation
        }
        if containsAny(text, ["model comparison", "compare the models", "compared the approaches", "algorithm comparison"]) {
            return .modelComparison
        }
        if containsAny(text, ["technical trade-off", "technical tradeoff", "trade off", "trade-off"]) {
            return .technicalTradeoff
        }
        if containsAny(text, ["noisy", "error handling", "handled errors", "failure recovery", "recover from"]) {
            return .errorHandling
        }
        if containsAny(text, ["another month", "one more month", "change first", "improve first", "do differently"]) {
            return .improvementPlan
        }
        if containsAny(text, ["comfortable with", "experience with", "proficiency", "skill level", "how well do you know"]) {
            return .skillComfort
        }
        if containsAny(text, ["walk me through", "tell me about your project", "describe your project", "project did you work"]) ||
            (text.contains("project") && containsAny(text, ["explain your", "explain the", "describe your"])) {
            return .projectWalkthrough
        }
        return .generic
    }

    static func transcriptClassification(for questionText: String) -> (intent: QuestionIntent, strategy: AnswerStrategy, confidence: Double) {
        switch answerIntent(for: questionText) {
        case .tellMeAboutYourself, .errorHandling, .improvementPlan:
            return (.behavioral, .starStory, 0.9)
        case .technicalChallenge:
            if isSystemIntegrationFamilyQuestion(questionText) {
                return (.technical, .technicalExplanation, 0.92)
            }
            return (.behavioral, .starStory, 0.9)
        case .projectWalkthrough, .projectComparison:
            return (.projectDeepDive, .projectWalkthrough, 0.92)
        case .whyRole, .candidateQuestions, .interviewerQuestions:
            return (.companyFit, .directAnswer, 0.9)
        case .generic:
            return (.unclear, .directAnswer, 0.86)
        default:
            return (.technical, .technicalExplanation, 0.92)
        }
    }

    static func normalize(_ text: String) -> String {
        let collapsed = text.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return " " + collapsed
            .replacingOccurrences(of: "auto regressive", with: "autoregressive") + " "
    }

    static func isDecoderComparisonQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        let comparison = containsAny(normalized, ["compare", "comparing", "compared", "difference between", "what did you learn"])
        let families = ["autoregressive", "diffusion", "flow matching", "flow-matching", "classifier", "regression", "transformer"]
            .filter { normalized.contains($0) }.count
        return comparison && families >= 2
    }

    static func isPerceptionDebuggingQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, ["detector", "detection", "prediction", "classification", "perception"]) &&
            containsAny(normalized, ["debug", "wrong", "false positive", "false negative", "failure"])
    }

    static func isRobotSystemArchitectureQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, ["architecture", "pipeline", "system", "components", "modules"]) &&
            containsAny(normalized, ["connect", "handoff", "flow", "integrate", "coordinate"])
    }

    static func isSystemIntegrationFamilyQuestion(_ text: String) -> Bool {
        isRoboticsPipelineQuestion(text) || isDecisionRequirementsQuestion(text) ||
            isPerceptionControlReliabilityQuestion(text) || isRobotSystemArchitectureQuestion(text) ||
            isRobotPerceptionToNavigationQuestion(text) || isDebuggingReflectionQuestion(text) ||
            isEvaluationReliabilityQuestion(text) || isVisualDetectionToPhysicalActionQuestion(text)
    }

    static func isRoboticsPipelineQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, ["pipeline", "system", "end-to-end", "end to end", "module", "component"]) &&
            containsAny(normalized, ["action", "output", "control", "decision", "handoff", "execution"])
    }

    static func isDecisionRequirementsQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, ["what information", "what state", "what data", "what signal", "what input", "need to know", "needed before"]) &&
            containsAny(normalized, ["before", "decide", "choose", "move", "act", "execute"])
    }

    static func isRealWorldExecutionQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, ["real-world", "real world", "production", "deployment", "hardware", "field testing"]) &&
            containsAny(normalized, ["hard", "difficult", "challenge", "failure", "reliable", "uncertain", "debug"])
    }

    static func isDebuggingReflectionQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        let isReflection = containsAny(normalized, ["learn", "lesson", "takeaway", "teach", "taught", "do differently"])
        let isDebugging = containsAny(normalized, ["debug", "failure", "root cause", "logs", "incident", "testing"])
        let namesSystemBoundary = containsAny(normalized, [
            "system", "pipeline", "integration", "handoff", "interface", "module", "component",
            "architecture", "robot", "simulation", "deployment"
        ])
        return isReflection && isDebugging && namesSystemBoundary
    }

    static func isEvaluationReliabilityQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, [" metric ", "reliability", "validation", "failure case", "test methodology", "stale", "risk"]) &&
            containsAny(normalized, ["measure", "validate", "test", "prevent"])
    }

    static func isVisualDetectionToPhysicalActionQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, ["visual", "vision", "detection", "perception"]) &&
            containsAny(normalized, ["physical action", "action", "control", "move", "execute"]) &&
            containsAny(normalized, ["connect", "turn into", "convert", "transform", "handoff", "influence"])
    }

    static func isRobotDecisionInformationQuestion(_ text: String) -> Bool {
        isDecisionRequirementsQuestion(text)
    }

    static func isPerceptionControlReliabilityQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, ["perception", "localization", "localisation", "state estimate", "input"]) &&
            containsAny(normalized, ["control", "execution", "action", "manipulation", "output"]) &&
            containsAny(normalized, ["reliable", "handoff", "influence", "difficult", "failure"])
    }

    static func isRobotPerceptionToNavigationQuestion(_ text: String) -> Bool {
        let normalized = normalize(text)
        return containsAny(normalized, ["perception", "detection", "sensor", "input"]) &&
            containsAny(normalized, ["navigation", "planning", "decision", "action", "output"]) &&
            containsAny(normalized, ["connect", "influence", "feed", "handoff", "use"])
    }

    private static func isProjectComparisonQuestion(_ text: String) -> Bool {
        containsAny(text, ["compare the projects", "difference between the projects", "how were the projects different", "contrast the projects"]) ||
            (text.contains("difference between") && text.components(separatedBy: "project").count >= 3)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
