import Foundation

struct RecapReport: Identifiable, Hashable, Codable {
    var id: String
    var sessionID: String
    var markdown: String
    var modelName: String
    var promptVersion: String
    var providerKind: LLMProviderKind? = nil
    var providerName: String? = nil
    var providerBaseURL: String? = nil
    var latencyMS: Int? = nil
    var isLocal: Bool = false
    var createdAt: Date
}
