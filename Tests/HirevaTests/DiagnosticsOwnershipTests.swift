import Combine
import Foundation
import Testing
@testable import Hireva

@Suite("Diagnostics ownership", .serialized)
@MainActor
struct DiagnosticsOwnershipTests {
    @Test
    func pcmAggregatesDoNotPublishOrCreatePerBufferRecords() {
        let state = DiagnosticsState(traceLogURL: unusedTraceURL())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        state.record(.audioStarted(sessionID: "synthetic-session", timestamp: now), context: .init(), mode: .off)
        var notifications = 0
        let observation = state.objectWillChange.sink { notifications += 1 }
        for offset in 1...100 {
            state.record(.audioBufferReceived(sessionID: "synthetic-session", frameCount: 960, timestamp: now.addingTimeInterval(Double(offset) * 0.02)), context: .init(), mode: .off)
        }
        #expect(state.runtime.audioBufferCount == 100)
        #expect(state.runtime.lastAudioBufferAt == now.addingTimeInterval(2))
        #expect(state.recentEvents.map(\.name) == ["audioStarted"])
        #expect(notifications == 0)
        #expect(!FileManager.default.fileExists(atPath: state.traceLogURL.path))
        withExtendedLifetime(observation) {}
    }

    @Test
    func samplingKeepsAllAggregateEventsAndUnsampledFinalControlRecords() {
        let state = DiagnosticsState(traceLogURL: unusedTraceURL())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        state.record(.generationStarted(sessionID: "synthetic-session", questionID: "q", generationID: "g", question: "Explain bounded retries.", timestamp: now), context: .init(), mode: .off)
        state.record(.persistenceRejected(sessionID: "synthetic-session", questionID: "q", generationID: "g", question: "Explain bounded retries.", reason: "consent_revoked", timestamp: now), context: .init(), mode: .off)
        for offset in 0..<100 {
            state.record(.asrPartial(sessionID: "synthetic-session", text: "Synthetic partial", recognitionTaskID: "asr", eventSequence: offset, sourceStartUTF16: 0, sourceEndUTF16: 17, isFinal: false, timestamp: now.addingTimeInterval(Double(offset) * 0.001)), context: .init(), mode: .off)
        }
        state.record(.asrFinal(sessionID: "synthetic-session", text: "Synthetic final", recognitionTaskID: "asr", eventSequence: 100, sourceStartUTF16: 0, sourceEndUTF16: 15, isFinal: true, timestamp: now.addingTimeInterval(0.1)), context: .init(), mode: .off)
        state.record(.generationCompleted(sessionID: "synthetic-session", questionID: "q", generationID: "g", question: "Explain bounded retries.", timestamp: now.addingTimeInterval(0.1)), context: .init(), mode: .off)
        #expect(state.runtime.partialTranscriptCount == 100)
        #expect(state.runtime.finalTranscriptCount == 1)
        #expect(state.runtime.lastGenerationRejectedReason.isEmpty)
        #expect(state.recentEvents.filter { $0.name == "asrPartial" }.count == 1)
        #expect(state.recentEvents.contains { $0.name == "asrFinal" && $0.recognitionIsFinal })
        #expect(state.recentEvents.contains { $0.name == "generationStarted" })
        #expect(state.recentEvents.contains { $0.name == "generationCompleted" })
        #expect(state.recentEvents.contains { $0.name == "persistenceRejected" })
    }

    @Test
    func recentTraceIsBoundedWithoutChangingAggregateTotals() {
        let state = DiagnosticsState(traceLogURL: unusedTraceURL())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in 0..<60 {
            state.record(.asrFinal(sessionID: "synthetic-session", text: "Synthetic final", recognitionTaskID: "asr", eventSequence: offset, sourceStartUTF16: 0, sourceEndUTF16: 15, isFinal: true, timestamp: now.addingTimeInterval(Double(offset))), context: .init(), mode: .off)
        }
        #expect(state.runtime.finalTranscriptCount == 60)
        #expect(state.recentEvents.count == 40)
        #expect(state.recentEvents.first?.recognitionEventSequence == 20)
        #expect(state.recentEvents.last?.recognitionEventSequence == 59)
        state.markAudioStopped()
        #expect(state.runtime.audioIsRunning == false)
        state.reset(clearEvents: false)
        #expect(state.runtime == .empty)
        #expect(state.recentEvents.count == 40)
        state.reset(clearEvents: true)
        #expect(state.recentEvents.isEmpty)
    }

    @Test
    func samplingIdentitiesStayBoundedWithinOneContinuousSession() {
        let state = DiagnosticsState(traceLogURL: unusedTraceURL())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<100 {
            let timestamp = now.addingTimeInterval(Double(index) * 2)
            state.record(.visibleCurrentSuggestionUpdated(sessionID: "synthetic-session", questionID: "q\(index)", generationID: "g\(index)", question: "", timestamp: timestamp), context: .init(), mode: .off)
            state.record(.lifecycle(eventName: "answer.ui.rendered", sessionID: "synthetic-session", questionID: "q\(index)", generationID: "g\(index)", text: "", currentState: "", reason: "", cancelled: false, skipped: false, timestamp: timestamp), context: .init(), mode: .off)
        }
        #expect(state.sampledIdentityCount <= 40)
        #expect(state.sampledIdentityEvictionCount == 160)
        #expect(state.recentEvents.count == 40)
        #expect(!FileManager.default.fileExists(atPath: state.traceLogURL.path))
    }

    @Test
    func residentSamplingKeepsOneSecondWindowsWithoutSamplingTerminalOrErrorEvents() {
        let state = DiagnosticsState(traceLogURL: unusedTraceURL())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sampled: [(Date) -> TranscriptRuntimeEvent] = [
            { .asrPartial(sessionID: "s", text: "", recognitionTaskID: "asr", eventSequence: 1, sourceStartUTF16: 0, sourceEndUTF16: 0, isFinal: false, timestamp: $0) },
            { .partialAnswerRejectedIncomplete(sessionID: "s", questionID: "q", generationID: "g", question: "", reason: "partial", timestamp: $0) },
            { .visibleCurrentSuggestionUpdated(sessionID: "s", questionID: "q", generationID: "g", question: "", timestamp: $0) },
            { .lifecycle(eventName: "transcript.partial", sessionID: "s", questionID: "q", generationID: "g", text: "", currentState: "", reason: "", cancelled: false, skipped: false, timestamp: $0) },
            { .lifecycle(eventName: "answer.ui.rendered", sessionID: "s", questionID: "q", generationID: "g", text: "", currentState: "", reason: "", cancelled: false, skipped: false, timestamp: $0) }
        ]
        for makeEvent in sampled {
            let before = state.recentEvents.count
            for offset in [0.0, 0.999, 1.0] {
                state.record(makeEvent(now.addingTimeInterval(offset)), context: .init(), mode: .off)
            }
            #expect(state.recentEvents.count == before + 2)
        }
        #expect(state.sampledIdentityCount == 5)
        #expect(state.sampledIdentityEvictionCount == 0)
        #expect(state.runtime.partialTranscriptCount == 3)
        let controls: [(Date) -> TranscriptRuntimeEvent] = [
            { .asrFinal(sessionID: "s", text: "", recognitionTaskID: "asr", eventSequence: 2, sourceStartUTF16: 0, sourceEndUTF16: 0, isFinal: true, timestamp: $0) },
            { .generationCompleted(sessionID: "s", questionID: "q", generationID: "g", question: "", timestamp: $0) },
            { .generationTimedOut(sessionID: "s", questionID: "q", generationID: "g", question: "", timestamp: $0) },
            { .lifecycle(eventName: "asr.error", sessionID: "s", questionID: "q", generationID: "g", text: "", currentState: "", reason: "synthetic", cancelled: false, skipped: false, timestamp: $0) }
        ]
        for makeEvent in controls {
            let before = state.recentEvents.count
            state.record(makeEvent(now), context: .init(), mode: .off)
            state.record(makeEvent(now.addingTimeInterval(0.001)), context: .init(), mode: .off)
            #expect(state.recentEvents.count == before + 2)
        }
        #expect(state.sampledIdentityCount == 5)
    }

    @Test
    func samplingCapacityEvictsOldestIdentityAndExplicitResetsClearCounters() throws {
        let state = DiagnosticsState(traceLogURL: unusedTraceURL())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func record(_ generation: String, _ offset: TimeInterval) {
            state.record(.visibleCurrentSuggestionUpdated(sessionID: "s", questionID: "q", generationID: generation, question: "", timestamp: now.addingTimeInterval(offset)), context: .init(), mode: .off)
        }
        for index in 0..<40 { record(String(format: "g%03d", index), 0) }
        record("g039", 0.5)
        #expect(state.sampledIdentityEvictionCount == 0)
        record("g040", 0.5)
        #expect(state.sampledIdentityCount == 40)
        #expect(state.sampledIdentityEvictionCount == 1)
        record("g039", 0.75)
        #expect(state.recentEvents.last?.generationID == "g040")
        record("g000", 0.75)
        #expect(state.recentEvents.last?.generationID == "g000")
        #expect(state.sampledIdentityCount == 40)
        #expect(state.sampledIdentityEvictionCount == 2)
        state.reset(clearEvents: false)
        #expect(state.sampledIdentityCount == 40 && state.sampledIdentityEvictionCount == 2)
        state.reset(clearEvents: true)
        #expect(state.sampledIdentityCount == 0 && state.sampledIdentityEvictionCount == 0)
        record("g000", 0)
        #expect(state.sampledIdentityCount == 1)
        try state.clearTrace()
        #expect(state.sampledIdentityCount == 0 && state.sampledIdentityEvictionCount == 0)
    }

    @Test
    func metadataExportAndClearPreservePrivacyAndResetSampling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaDiagnosticsOwnership-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeTranscriptTraceStore()
        let state = DiagnosticsState(traceLogURL: root.appendingPathComponent("trace.jsonl"), traceStore: store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let event = TranscriptRuntimeEvent.asrPartial(sessionID: "synthetic-session", text: "SYNTHETIC-TRACE-PRIVACY-CANARY", recognitionTaskID: "asr", eventSequence: 0, sourceStartUTF16: 0, sourceEndUTF16: 30, isFinal: false, timestamp: now)
        state.record(event, context: .init(transcriptText: "SYNTHETIC-TRACE-PRIVACY-CANARY", visibleQuestionText: "Synthetic question"), mode: .fullText)
        store.waitForPendingOperations()
        #expect(state.exportText(mode: .fullText).contains("SYNTHETIC-TRACE-PRIVACY-CANARY"))
        #expect(!state.exportText(mode: .metadataOnly).contains("SYNTHETIC-TRACE-PRIVACY-CANARY"))
        #expect(state.exportText(mode: .off).isEmpty)
        try state.clearTrace()
        #expect(state.recentEvents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: state.traceLogURL.path))
        // Same timestamp/key must be accepted after the explicit trace clear.
        state.record(event, context: .init(), mode: .metadataOnly)
        store.waitForPendingOperations()
        #expect(state.recentEvents.count == 1)
        #expect(state.recentEvents[0].text.isEmpty)
        #expect(!(try String(contentsOf: state.traceLogURL)).contains("SYNTHETIC-TRACE-PRIVACY-CANARY"))
    }

    @Test
    func appCompatibilityUsesOneOwnerWithoutRepublishingDiagnosticsToProductState() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "DiagnosticsOwnership")
        let app = environment.appState
        let state = app.diagnosticsState
        var appNotifications = 0
        var diagnosticNotifications = 0
        let appObservation = app.objectWillChange.sink { appNotifications += 1 }
        let diagnosticObservation = state.objectWillChange.sink { diagnosticNotifications += 1 }
        app.updateDiagnostics { $0.lastError = "Synthetic diagnostic error" }
        #expect(app.diagnostics == state.developer)
        #expect(state.developer.lastError == "Synthetic diagnostic error")
        #expect(diagnosticNotifications == 1)
        #expect(appNotifications == 0)
        app.transcriptRuntimeDiagnostics.audioIsRunning = true
        #expect(state.runtime.audioIsRunning)
        app.runtimeTranscriptTraceLogURL = unusedTraceURL()
        #expect(app.runtimeTranscriptTraceLogURL == state.traceLogURL)
        withExtendedLifetime((appObservation, diagnosticObservation)) {}
        try await environment.shutdown()
    }

    @Test
    func latestRetrievalTraceUsesDiagnosticOwnerForAppAndDirectUpdates() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "RetrievalTraceOwnership")
        let app = environment.appState
        let state = app.diagnosticsState
        let traces = ["Synthetic automatic retrieval", "Synthetic manual retrieval"].map { query in
            syntheticRetrievalTrace(query: query)
        }
        var ownerValues: [RetrievalTrace?] = []
        let observation = state.objectWillChange.sink {
            ownerValues.append(state.developer.lastRetrievalTrace)
        }
        defer { observation.cancel() }

        // Live and Manual both publish accepted retrieval through this App entry.
        app.lastRetrievalTrace = traces[0]
        #expect(state.developer.lastRetrievalTrace == traces[0])
        #expect(ownerValues == [traces[0]])

        state.updateDeveloper { $0.lastRetrievalTrace = traces[1] }
        #expect(app.lastRetrievalTrace == traces[1])
        #expect(ownerValues == [traces[0], traces[1]])

        app.lastRetrievalTrace = nil
        #expect(state.developer.lastRetrievalTrace == nil)
        #expect(ownerValues == [traces[0], traces[1], nil])
        observation.cancel()
        try await environment.shutdown()
    }

    @Test(arguments: [false, true])
    func retrievalTracePublicationKeepsReentrantReplacementAndSameValueAudit(replaceTrace: Bool) async throws {
        let environment = try await HirevaTestEnvironment(prefix: "RetrievalTraceReentry")
        let state = environment.appState.diagnosticsState
        let trace = syntheticRetrievalTrace(query: "Synthetic admitted retrieval")
        var changes: [RetrievalTrace?] = []
        var reentered = false
        let traceObservation = state.retrievalTraceChanges.sink { changes.append($0) }
        let ownerObservation = state.objectWillChange.sink {
            guard !reentered else { return }
            reentered = true
            if replaceTrace {
                state.updateDeveloper { $0.lastRetrievalTrace = nil }
            } else {
                state.updateDeveloper { $0.lastError = "Synthetic metadata at trace publication" }
            }
        }
        defer { traceObservation.cancel(); ownerObservation.cancel() }

        state.setRetrievalTrace(trace)
        let expectedPrefix: [RetrievalTrace?] = replaceTrace ? [nil] : [trace]
        #expect(reentered)
        #expect(state.developer.lastRetrievalTrace == (replaceTrace ? nil : trace))
        #expect(changes == expectedPrefix)

        state.updateDeveloper { $0.lastError = "Synthetic unrelated metadata update" }
        #expect(changes == expectedPrefix)
        state.setRetrievalTrace(trace)
        state.setRetrievalTrace(trace)
        #expect(changes == expectedPrefix + [trace, trace])
        #expect(state.developer.lastRetrievalTrace == trace)

        traceObservation.cancel(); ownerObservation.cancel()
        try await environment.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func taskSummaryUsesOneCommittedDiagnosticValueAndOnlyItsAppRelay() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "TaskSummaryOwnership")
        let app = environment.appState
        let state = app.diagnosticsState
        var appValues: [String] = []
        var ownerValues: [String] = []
        var committed = true
        var appNotifications = 0
        var diagnosticNotifications = 0
        let appUpdates = app.activeTaskSummaryUpdates.sink { value in
            appValues.append(value)
            committed = committed && app.activeTaskSummary == value && state.activeTaskSummary == value
        }
        let ownerUpdates = state.activeTaskSummaryUpdates.sink { value in
            ownerValues.append(value)
            committed = committed && app.activeTaskSummary == value && state.activeTaskSummary == value
        }
        let appObservation = app.objectWillChange.sink { appNotifications += 1 }
        let ownerObservation = state.objectWillChange.sink { diagnosticNotifications += 1 }
        app.activeTaskSummary = "Synthetic App summary"
        state.activeTaskSummary = "Synthetic owner summary"
        app.activeTaskSummary = "Synthetic owner summary"
        #expect(committed && appValues == ["Idle", "Synthetic App summary", "Synthetic owner summary", "Synthetic owner summary"])
        #expect(ownerValues == appValues && appNotifications == 3 && diagnosticNotifications == 3)
        // Unrelated diagnostic snapshots retain the existing non-product relay.
        app.updateDiagnostics { $0.lastError = "Synthetic unrelated diagnostic" }
        #expect(appNotifications == 3 && diagnosticNotifications == 4)
        appUpdates.cancel(); ownerUpdates.cancel(); appObservation.cancel(); ownerObservation.cancel()
        try await environment.shutdown()
    }

    private func syntheticRetrievalTrace(query: String) -> RetrievalTrace {
        RetrievalTrace(id: UUID(), query: query, intent: "technical",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rankedCVChunks: [], rankedJDChunks: [],
            includedCVChunks: [], includedJDChunks: [],
            excludedCVChunks: [], excludedJDChunks: [],
            cvWordsUsed: 0, jdWordsUsed: 0, cvWordBudget: 300, jdWordBudget: 180,
            retrievalLatencyMS: 12, emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false)
    }

    private func unusedTraceURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HirevaDiagnosticsUnused-\(UUID().uuidString).jsonl")
    }
}
