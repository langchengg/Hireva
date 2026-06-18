import Foundation

/// Routes accepted questions into transcript-level and answer-level intents.
enum IntentRouter {
    static func answerIntent(for questionText: String) -> AnswerRelevanceIntent {
        let text = normalize(questionText)
        if isDecoderComparisonQuestion(text) {
            return .decoderComparison
        }
        if isPerceptionDebuggingQuestion(text) {
            return .perceptionDebugging
        }
        if text.contains("biggest technical trade-off") ||
            text.contains("biggest technical tradeoff") ||
            text.contains("technical trade-off") ||
            text.contains("technical tradeoff") ||
            text.contains("trade off") && text.contains("robotics") {
            return .technicalTradeoff
        }
        if text.contains("what questions would you ask us") ||
            text.contains("what would you ask the team") ||
            text.contains("what would you ask the engineering team") ||
            text.contains("ask the engineering team") && text.contains("good fit") ||
            text.contains("before accepting an offer") {
            return .interviewerQuestions
        }
        if text.contains("droid") && (text.contains("mujoco") || text.contains("franka") || text.contains("trajector")) {
            return .datasetAdaptation
        }
        if text.contains("sim-to-real") ||
            text.contains("sim to real") ||
            text.contains("policy works in mujoco") ||
            text.contains("fails on a real robot") {
            return .simToRealDebugging
        }
        if text.contains("difference between") && text.contains("vla") && text.contains("leorover") {
            return .projectComparison
        }
        if text.contains("system integration problem") ||
            text.contains("debug a system integration") {
            return .systemIntegrationDebugging
        }
        if text.contains("diffusion") && (text.contains("autoregressive") || text.contains("auto regressive")) {
            return .modelComparison
        }
        if text.contains("diffusion") && text.contains("robotic manipulation") {
            return .diffusionPolicy
        }
        if text.contains("action decoder") || text.contains("policy") || text.contains("flow matching") || text.contains("flow-matching") {
            return .modelComparison
        }
        if text.contains("diffusion decoder") ||
            text.contains("diffusion-based policy") ||
            text.contains("diffusion policy") ||
            text.contains("mujoco") ||
            text.contains("mu jo co") ||
            text.contains("autoregressive") ||
            text.contains("flow matching") {
            return .modelComparison
        }
        if text.contains("hardest technical challenge") ||
            text.contains("hardest challenge") ||
            text.contains("pipeline was most fragile") ||
            text.contains("most fragile") ||
            text.contains("clean demo") ||
            text.contains("real robot execution") {
            return .technicalChallenge
        }
        if text.contains("about yourself") || text.contains("brought you into robotics") || text.contains("introduce yourself") {
            return .tellMeAboutYourself
        }
        if text.contains("noisy detections") || text.contains("localisation errors") || text.contains("localization errors") {
            return .errorHandling
        }
        if text.contains("another month") || text.contains("change first") || text.contains("improve first") {
            return .improvementPlan
        }
        if text.contains("leorover") || text.contains("leo rover") || text.contains("walk me through") {
            return .projectWalkthrough
        }
        if text.contains("python") || text.contains("c plus plus") || text.contains("ros2") || text.contains("rose two") {
            return .skillComfort
        }
        if text.contains("questions for us") || text.contains("questions for you") || text.contains("do you have any questions") {
            return .candidateQuestions
        }
        if text.contains("why do you want") || text.contains("join our team") || text.contains("this role") {
            return .whyRole
        }
        return .generic
    }

    static func transcriptClassification(for questionText: String) -> (intent: QuestionIntent, strategy: AnswerStrategy, confidence: Double) {
        let lower = QuestionCanonicalizer.canonicalize(questionText).lowercased()
        if isDecoderComparisonQuestion(normalize(lower)) ||
            isPerceptionDebuggingQuestion(normalize(lower)) ||
            lower.contains("biggest technical trade-off") ||
            lower.contains("biggest technical tradeoff") ||
            lower.contains("technical trade off") ||
            lower.contains("diffusion") ||
            lower.contains("autoregressive") ||
            lower.contains("auto regressive") ||
            lower.contains("flow-matching") ||
            lower.contains("flow matching") ||
            lower.contains("mujoco") ||
            lower.contains("mouko") ||
            lower.contains("droid") ||
            lower.contains("sim-to-real") ||
            lower.contains("continuous action") ||
            lower.contains("fragile") ||
            lower.contains("clean demo") ||
            lower.contains("real robot execution") ||
            lower.contains("localisation") ||
            lower.contains("localization") ||
            lower.contains("timing") ||
            lower.contains("integration") ||
            lower.contains("pipeline") {
            return (.technical, .technicalExplanation, 0.93)
        }
        if lower.contains("technical") || lower.contains("detections") || lower.contains("python") || lower.contains("ros") || lower.contains("c++") {
            return (.technical, .technicalExplanation, 0.92)
        }
        if lower.contains("walk me through") ||
            lower.contains("project") ||
            lower.contains("leorover") ||
            lower.contains("leo rover") {
            return (.projectDeepDive, .projectWalkthrough, 0.92)
        }
        if lower.contains("what questions would you ask us") ||
            lower.contains("what would you ask the team") ||
            lower.contains("what would you ask the engineering team") ||
            lower.contains("ask the engineering team") && lower.contains("good fit") ||
            lower.contains("before accepting an offer") {
            return (.companyFit, .directAnswer, 0.9)
        }
        if lower.contains("why do you want") ||
            lower.contains("join our team") ||
            lower.contains("questions for us") ||
            lower.contains("role") {
            return (.companyFit, .directAnswer, 0.9)
        }
        if lower.contains("tell me a little bit about yourself") || lower.contains("hardest") || lower.contains("challenge") {
            return (.behavioral, .starStory, 0.9)
        }
        return (.unclear, .directAnswer, 0.86)
    }

    static func normalize(_ text: String) -> String {
        " " + ASRCanonicalizer.canonicalizeTerms(text)
            .lowercased()
            .replacingOccurrences(of: "c++", with: "c plus plus")
            .replacingOccurrences(of: "ros 2", with: "ros2")
            .replacingOccurrences(of: "flow matching", with: "flow-matching")
            .replacingOccurrences(of: "diffusion-based policy", with: "diffusion policy")
            .replacingOccurrences(of: "diffusion based policy", with: "diffusion policy")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }

    static func isDecoderComparisonQuestion(_ text: String) -> Bool {
        let modelTerms = ["autoregressive", "diffusion", "flow-matching"].filter { text.contains($0) }.count
        let mentionsDecoderComparison = text.contains("comparing") ||
            text.contains("compared") ||
            text.contains("what did you learn")
        let mentionsVLAContext = text.contains("mujoco") ||
            text.contains("vla") ||
            text.contains("franka") ||
            text.contains("flow-matching")
        return mentionsDecoderComparison && mentionsVLAContext && modelTerms >= 2
    }

    static func isPerceptionDebuggingQuestion(_ text: String) -> Bool {
        let mentionsDetector = text.contains("yolov8") ||
            text.contains("detector") ||
            text.contains("detection") ||
            text.contains("prediction")
        let mentionsDebugging = text.contains("debug") ||
            text.contains("wrong prediction") ||
            text.contains("confident but wrong") ||
            text.contains("false positive")
        return mentionsDetector && mentionsDebugging
    }
}
