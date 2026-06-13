// Provider request model derived from a frozen generation context.
// This contains prompt text and safe diagnostics only. It must never include raw
// API keys or own provider streaming/cancellation.

import Foundation

/// Typed provider-call input derived from `GenerationExecutionContext`.
///
/// Safe diagnostics are explicitly redacted so settings or diagnostics views can
/// inspect request metadata without leaking provider secrets.
struct GenerationProviderRequest: Equatable {
    let prompt: String
    let model: String
    let providerID: String
    let streamingEnabled: Bool
    let promptPrimaryQuestion: String
    let safeDiagnostics: [String: String]

    init(context: GenerationExecutionContext, streamingEnabled: Bool) {
        self.init(
            promptSnapshot: context.promptSnapshot,
            providerID: context.providerID,
            model: context.providerModel,
            generationID: context.generationID,
            detectedQuestionID: context.detectedQuestionID,
            triggerPath: context.triggerPath,
            streamingEnabled: streamingEnabled
        )
    }

    init(
        promptSnapshot: AnswerPromptSnapshot,
        providerID: String,
        model: String,
        generationID: String,
        detectedQuestionID: String,
        triggerPath: GenerationTriggerPath,
        streamingEnabled: Bool
    ) {
        self.prompt = promptSnapshot.prompt
        self.model = Self.redactSecrets(model)
        self.providerID = Self.redactSecrets(providerID)
        self.streamingEnabled = streamingEnabled
        self.promptPrimaryQuestion = promptSnapshot.promptPrimaryQuestion
        self.safeDiagnostics = [
            "detectedQuestionID": Self.redactSecrets(detectedQuestionID),
            "generationID": Self.redactSecrets(generationID),
            "providerID": Self.redactSecrets(providerID),
            "model": Self.redactSecrets(model),
            "promptPrimaryQuestion": Self.redactSecrets(promptSnapshot.promptPrimaryQuestion),
            "questionIntent": promptSnapshot.questionIntent.rawValue,
            "triggerPath": triggerPath.rawValue,
            "streamingEnabled": streamingEnabled ? "true" : "false"
        ]
    }

    private static func redactSecrets(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"sk-[A-Za-z0-9_\-]{20,}"#,
                with: "[REDACTED_API_KEY]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(api[_ -]?key\s*[:=]\s*)[A-Za-z0-9_\-]{12,}"#,
                with: "$1[REDACTED_API_KEY]",
                options: .regularExpression
            )
    }
}
