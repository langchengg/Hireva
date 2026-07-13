import Foundation

protocol ContextRetrievalService {
    func retrieveContext(question: String, intent: QuestionIntent, maxCVWords: Int, maxJDWords: Int) async throws -> RetrievedContext
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int, maxJDWords: Int) async throws -> (context: RetrievedContext, trace: RetrievalTrace)
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int, maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace)
}

extension ContextRetrievalService {
    func retrieveContext(question: String, intent: QuestionIntent, maxCVWords: Int = 1_500, maxJDWords: Int = 1_000) async throws -> RetrievedContext {
        try await retrieveContextWithTrace(question: question, intent: intent, maxCVWords: maxCVWords, maxJDWords: maxJDWords, strategy: nil).context
    }
    
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int = 1_500, maxJDWords: Int = 1_000) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try await retrieveContextWithTrace(question: question, intent: intent, maxCVWords: maxCVWords, maxJDWords: maxJDWords, strategy: nil)
    }
}
