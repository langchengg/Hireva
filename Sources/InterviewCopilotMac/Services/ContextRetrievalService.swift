import Foundation

protocol ContextRetrievalService {
    func retrieveContext(question: String, intent: QuestionIntent, maxCVWords: Int, maxJDWords: Int) throws -> RetrievedContext
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int, maxJDWords: Int) throws -> (context: RetrievedContext, trace: RetrievalTrace)
}

extension ContextRetrievalService {
    func retrieveContext(question: String, intent: QuestionIntent, maxCVWords: Int = 1_500, maxJDWords: Int = 1_000) throws -> RetrievedContext {
        try retrieveContextWithTrace(question: question, intent: intent, maxCVWords: maxCVWords, maxJDWords: maxJDWords).context
    }
}
