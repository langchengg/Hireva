import Foundation

enum AppPaths {
    static let appName = HirevaProductIdentity.applicationSupportDirectoryName

    static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var databaseURL: URL {
        applicationSupportDirectory.appendingPathComponent(HirevaProductIdentity.databaseFilename)
    }

    static var runtimeTranscriptTraceURL: URL {
        applicationSupportDirectory.appendingPathComponent("runtime_transcript_trace.jsonl")
    }

    static func runtimeTranscriptTraceURL(for databaseURL: URL?) -> URL {
        guard let databaseURL else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Hireva-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("runtime_transcript_trace.jsonl")
        }
        return databaseURL.deletingLastPathComponent()
            .appendingPathComponent("runtime_transcript_trace.jsonl")
    }

    static var exportsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    static var attachmentsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }

    static func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: exportsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attachmentsDirectory,
            withIntermediateDirectories: true
        )
    }
}
