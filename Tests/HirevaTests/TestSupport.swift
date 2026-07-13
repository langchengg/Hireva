import Foundation
@testable import Hireva

enum TestSupport {
    static var realAppDatabaseTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["REAL_APP_DB_TESTS"] == "1"
    }

    static func makeTemporaryDatabase(prefix: String = "HirevaTests") throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
