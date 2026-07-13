import Foundation

struct JobDescription: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
}
