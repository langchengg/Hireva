import Foundation

/// Deterministic, domain-neutral intent and retrieval policy. Candidate and
/// opportunity facts enter through chunks selected from the active snapshot.
enum QuestionIntentPromptPolicy {
    static func normalizedQuestionText(for text: String) -> String {
        normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func intent(for questionText: String) -> AnswerRelevanceIntent {
        IntentRouter.answerIntent(for: questionText)
    }

    static func filterContext(_ context: RetrievedContext, intent: AnswerRelevanceIntent) -> RetrievedContext {
        let candidateKeywords = keywords(for: intent, candidate: true)
        let opportunityKeywords = keywords(for: intent, candidate: false)
        return RetrievedContext(
            cvChunks: pick(context.cvChunks, keywords: candidateKeywords, limit: intent == .projectComparison ? 4 : 3),
            jobDescriptionChunks: pick(context.jobDescriptionChunks, keywords: opportunityKeywords, limit: 2),
            additionalNotesChunks: Array(context.additionalNotesChunks.prefix(1))
        )
    }

    static func fallbackAnswer(for question: DetectedQuestion) -> IntentFallbackAnswer {
        ProjectGroundedFallbackPolicy.fallbackAnswer(for: question)
    }

    static func answerShape(for intent: AnswerRelevanceIntent) -> String {
        switch intent {
        case .tellMeAboutYourself: return "background -> relevant evidence -> current direction -> target relevance"
        case .projectWalkthrough: return "goal -> personal role -> actions -> result or learning"
        case .technicalChallenge: return "challenge -> cause -> action -> result"
        case .errorHandling, .perceptionDebugging: return "failure -> diagnosis -> mitigation -> validation"
        case .modelComparison, .decoderComparison, .diffusionPolicy: return "alternatives -> evaluation criteria -> evidence -> trade-off"
        case .technicalTradeoff: return "trade-off -> decision -> consequence -> learning"
        case .datasetAdaptation: return "source -> transformation -> validation -> limitation"
        case .simToRealDebugging: return "environment difference -> isolated cause -> mitigation -> verification"
        case .projectComparison: return "first project -> second project -> concrete contrast -> shared learning"
        case .systemIntegrationDebugging: return "system boundary -> observed failure -> diagnosis -> reliability improvement"
        case .improvementPlan: return "priority -> evidence -> next actions -> success measure"
        case .whyRole: return "target need -> supported candidate evidence -> motivation"
        case .skillComfort: return "supported experience -> scope -> limitation or next step"
        case .candidateQuestions, .interviewerQuestions: return "concise questions about success, constraints, team, and evaluation"
        case .generic: return "direct answer -> supported example -> result or limitation"
        }
    }

    private static func keywords(for intent: AnswerRelevanceIntent, candidate: Bool) -> [String] {
        switch intent {
        case .tellMeAboutYourself: return candidate ? ["education", "experience", "background", "project", "skill", "goal"] : ["role", "team", "responsibility"]
        case .projectWalkthrough, .projectComparison: return candidate ? ["project", "built", "developed", "implemented", "result", "learning"] : ["responsibility", "requirement"]
        case .technicalChallenge, .errorHandling, .perceptionDebugging, .systemIntegrationDebugging, .simToRealDebugging:
            return candidate ? ["challenge", "failure", "debug", "recovery", "validation", "reliability", "integration"] : ["reliability", "quality", "operation"]
        case .modelComparison, .decoderComparison, .diffusionPolicy, .technicalTradeoff:
            return candidate ? ["compare", "evaluation", "trade-off", "metric", "experiment", "decision"] : ["evaluation", "performance", "constraint"]
        case .datasetAdaptation: return candidate ? ["data", "dataset", "migration", "mapping", "validation"] : ["data", "platform", "requirement"]
        case .improvementPlan: return candidate ? ["gap", "improve", "learning", "next"] : ["priority", "success", "requirement"]
        case .whyRole: return candidate ? ["experience", "project", "skill", "goal"] : ["role", "team", "responsibility", "required", "preferred"]
        case .skillComfort: return candidate ? ["skill", "tool", "used", "experience"] : ["required", "preferred", "skill"]
        case .candidateQuestions, .interviewerQuestions: return candidate ? [] : ["success", "team", "constraint", "evaluation", "ownership"]
        case .generic: return []
        }
    }

    private static func pick(_ chunks: [DocumentChunk], keywords: [String], limit: Int) -> [DocumentChunk] {
        guard !chunks.isEmpty else { return [] }
        guard !keywords.isEmpty else { return Array(chunks.prefix(limit)) }
        let matches = chunks.filter { chunk in
            let content = normalize((chunk.sectionTitle ?? "") + " " + chunk.content)
            return keywords.contains { content.contains($0) }
        }
        return Array((matches.isEmpty ? chunks : matches).prefix(limit))
    }

    private static func normalize(_ text: String) -> String {
        " " + text.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }
}
