import Foundation
import Testing
@testable import Hireva

@Suite("Parakeet Python sidecar diagnostics")
struct ParakeetPythonSidecarTests {
    @Test
    func healthAlwaysReturnsStructuredJSONWithoutImportTraceback() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent("scripts/parakeet_asr_sidecar.py")
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--health"]
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutText = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let lines = stdoutText.split(separator: "\n")
        #expect(lines.count == 1)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(stdoutText.utf8)) as? [String: Any]
        )
        #expect(payload["source"] as? String == "local_parakeet_asr" || payload["type"] as? String == "error")
        #expect(!stderrText.contains("Traceback"))

        if payload["status"] as? String == "ok" {
            #expect(process.terminationStatus == 0)
            #expect(payload["runtime"] as? String == "sherpa_onnx")
        } else {
            #expect(process.terminationStatus != 0)
            #expect(payload["type"] as? String == "error")
            #expect(!stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
