import Foundation

protocol ContextRetrievalService {
    func retrieveContext(question: String, intent: QuestionIntent, maxCVWords: Int, maxJDWords: Int) throws -> RetrievedContext
}
