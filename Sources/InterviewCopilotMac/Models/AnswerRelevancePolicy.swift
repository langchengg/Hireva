import Foundation

enum AnswerRelevanceIntent: String, CaseIterable, Codable, Hashable, Identifiable {
    case tellMeAboutYourself = "tell_me_about_yourself"
    case projectWalkthrough = "project_walkthrough"
    case technicalChallenge = "technical_challenge"
    case errorHandling = "error_handling"
    case modelComparison = "model_comparison"
    case improvementPlan = "improvement_plan"
    case whyRole = "why_role"
    case skillComfort = "skill_comfort"
    case candidateQuestions = "candidate_questions"
    case diffusionPolicy = "diffusion_policy"
    case generic

    var id: String { rawValue }
}

enum AnswerRelevancePolicy {
    static func normalizedQuestionText(for text: String) -> String {
        QuestionIntentPromptPolicy.normalizedQuestionText(for: text)
    }

    static func intent(for questionText: String) -> AnswerRelevanceIntent {
        QuestionIntentPromptPolicy.intent(for: questionText)
    }

    static func promptSnapshot(
        question: DetectedQuestion,
        context: RetrievedContext,
        transcriptContext: String,
        cvSummary: String,
        jdSummary: String,
        stage: AnswerPromptStage
    ) -> AnswerPromptSnapshot {
        PromptContextBuilder.promptSnapshot(
            question: question,
            context: context,
            transcriptContext: transcriptContext,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: stage
        )
    }

    static func generationRequestSnapshot(
        question: DetectedQuestion,
        generationID: String,
        triggerPath: GenerationTriggerPath,
        source: AudioSourceType?,
        speaker: SpeakerRole?,
        acceptedAt: Date,
        context: RetrievedContext,
        transcriptContext: String,
        cvSummary: String,
        jdSummary: String,
        stage: AnswerPromptStage
    ) -> GenerationRequestSnapshot {
        PromptContextBuilder.generationRequestSnapshot(
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            source: source,
            speaker: speaker,
            acceptedAt: acceptedAt,
            context: context,
            transcriptContext: transcriptContext,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: stage
        )
    }

    static func filterContext(_ context: RetrievedContext, intent: AnswerRelevanceIntent) -> RetrievedContext {
        QuestionIntentPromptPolicy.filterContext(context, intent: intent)
    }

    static func fallbackAnswer(for question: DetectedQuestion) -> IntentFallbackAnswer {
        QuestionIntentPromptPolicy.fallbackAnswer(for: question)
    }

    static func estimateTokens(_ text: String) -> Int {
        PromptContextBuilder.estimateTokens(text)
    }
}
