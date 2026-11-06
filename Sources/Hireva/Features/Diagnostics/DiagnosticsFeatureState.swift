import Combine
import Dispatch
import Foundation

/// Owns diagnostic snapshots and the sampled trace. Live transcript, question
/// and answer state are supplied as immutable display context, never retained
/// through an application container. PCM aggregates deliberately do not publish.
@MainActor
final class DiagnosticsState: ObservableObject {
    // One committed diagnostic value: a subscriber's newer summary cannot
    // be overwritten by an older App property wrapper's willSet tail.
    private let activeTaskSummarySource = CurrentValueSubject<String, Never>("Idle")
    var activeTaskSummary: String {
        get { activeTaskSummarySource.value }
        set { activeTaskSummarySource.send(newValue); objectWillChange.send() }
    }
    var activeTaskSummaryUpdates: AnyPublisher<String, Never> {
        activeTaskSummarySource.eraseToAnyPublisher()
    }

    typealias LatencyQuery = @MainActor @Sendable () async throws -> (overall: LatencyAverages, deepSeek: LatencyAverages)
    struct DisplayContext {
        var transcriptText: String = ""
        var visibleQuestionText: String = ""
    }

    // Both views come from one accepted database snapshot; publication is atomic.
    @Published private(set) var latencyAverages: (overall: LatencyAverages, deepSeek: LatencyAverages) = (.empty, .empty)
    var latencyAveragesOverall: LatencyAverages { latencyAverages.overall }
    var latencyAveragesDeepSeek: LatencyAverages { latencyAverages.deepSeek }
    var latencyQueryOverride: LatencyQuery?
    private let latencyQuery: LatencyQuery?
    private var latencyWork: (id: UUID, task: Task<Void, Never>)?
    private var retiringLatencyWork: [UUID: Task<Void, Never>] = [:]
    private var latencyAdmissionClosed = false
    #if DEBUG
    // Observes the actual existing diagnostic-work join. It owns no Task and
    // does not replace query/script/native/file operations.
    var shutdownWorkDidFinishForTesting: (@MainActor () -> Void)?
    #endif
    var pendingLatencyTaskCount: Int { (latencyWork == nil ? 0 : 1) + retiringLatencyWork.count }

    // The DEBUG callback script has a single retained handle. Busy requests
    // are rejected; cancellation revokes publication but keeps the handle until
    // the actual body exits. Continuous Speech belongs to the audio owner.
    #if DEBUG
    private var systemAudioDiagnosticWork: (id: UUID, task: Task<Void, Never>)?

    @discardableResult
    func requestSystemAudioDiagnostic(
        operation: @escaping @MainActor (UUID) async -> Void
    ) -> Task<Void, Never>? {
        guard !latencyAdmissionClosed, systemAudioDiagnosticWork == nil else { return nil }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.systemAudioDiagnosticWork?.id == id { self?.systemAudioDiagnosticWork = nil }
            }
            guard self?.isCurrentSystemAudioDiagnostic(id) == true else { return }
            await operation(id)
        }
        systemAudioDiagnosticWork = (id, task)
        return task
    }

    func isCurrentSystemAudioDiagnostic(_ id: UUID) -> Bool {
        guard !latencyAdmissionClosed, let work = systemAudioDiagnosticWork else { return false }
        return work.id == id && !work.task.isCancelled
    }
    #endif

    var pendingSystemAudioDiagnosticTaskCount: Int {
        #if DEBUG
        return systemAudioDiagnosticWork == nil ? 0 : 1
        #else
        return 0
        #endif
    }

    @discardableResult
    func refreshLatencyAverages(completion: @escaping @MainActor (String) -> Void) -> Task<Void, Never>? {
        guard !latencyAdmissionClosed, let query = latencyQueryOverride ?? latencyQuery else { return nil }
        retireLatencyWork()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.latencyWork?.id == id { self.latencyWork = nil }
                self.retiringLatencyWork[id] = nil
            }
            do {
                try Task.checkCancellation()
                let pair = try await query()
                guard !Task.isCancelled, !self.latencyAdmissionClosed, self.latencyWork?.id == id else { return }
                self.latencyAverages = pair
                // A synchronous observer may submit a replacement while publishing.
                guard !Task.isCancelled, !self.latencyAdmissionClosed, self.latencyWork?.id == id else { return }
                completion("Refreshed latency averages")
            } catch {
                guard !Task.isCancelled, !self.latencyAdmissionClosed, self.latencyWork?.id == id else { return }
                completion("Latency averages refresh failed: \(error.localizedDescription)")
            }
        }
        latencyWork = (id, task)
        return task
    }

    private func retireLatencyWork() {
        guard let old = latencyWork else { return }
        latencyWork = nil // Revoke publication before cancellation can invoke callbacks.
        retiringLatencyWork[old.id] = old.task
        old.task.cancel()
    }

    func closeAdmission() {
        latencyAdmissionClosed = true // Revoke all diagnostic admission before cancellation.
        retireLatencyWork()
        #if DEBUG
        systemAudioDiagnosticWork?.task.cancel()
        #endif
    }

    func shutdown() async {
        closeAdmission()
        #if DEBUG
        let script = systemAudioDiagnosticWork?.task
        #endif
        // A non-cooperative query remains owned until its real database read exits.
        for task in Array(retiringLatencyWork.values) { await task.value }
        #if DEBUG
        // The script body never calls shutdown on its own owner.
        await script?.value
        #endif
        // Audit admission remains open: App's later generation/history/native
        // cleanup may append legitimate terminal records after this early step.
        await traceWriter.drain()
        #if DEBUG
        shutdownWorkDidFinishForTesting?()
        #endif
    }

    /// Called only after App has joined every producer and retryable cleanup.
    /// A failed App cleanup keeps audit admission open until its explicit retry.
    func finalizeTraceWritesForShutdown() async {
        await traceWriter.sealAndDrain()
    }

    deinit {
        traceWriter.seal()
        #if DEBUG
        systemAudioDiagnosticWork?.task.cancel()
        #endif
    }

    private var developerValue = DeveloperDiagnostics.empty
    private let retrievalTraceChangesSource = PassthroughSubject<RetrievalTrace?, Never>()
    private var retrievalTracePublicationID = UUID()
    var developer: DeveloperDiagnostics {
        get { developerValue }
        set { publishDeveloper(newValue) }
    }
    var retrievalTraceChanges: AnyPublisher<RetrievalTrace?, Never> {
        retrievalTraceChangesSource.eraseToAnyPublisher()
    }

    func setRetrievalTrace(_ trace: RetrievalTrace?) {
        var next = developerValue
        next.lastRetrievalTrace = trace
        publishDeveloper(next, forceTrace: true)
    }

    private func publishDeveloper(_ next: DeveloperDiagnostics, forceTrace: Bool = false) {
        let publishesTrace = forceTrace || developerValue.lastRetrievalTrace != next.lastRetrievalTrace
        if publishesTrace { retrievalTracePublicationID = UUID() }
        let publicationID = retrievalTracePublicationID
        developerValue = next
        objectWillChange.send()
        // A reentrant replacement revokes this trace; unrelated metadata does not.
        guard retrievalTracePublicationID == publicationID else { return }
        if publishesTrace { retrievalTraceChangesSource.send(next.lastRetrievalTrace) }
    }
    var runtime = TranscriptRuntimeDiagnostics.empty
    // One bounded sampling cursor. The capture receiver owns absolute ingress
    // counters; this cursor only admits each observed delta once to runtime.
    private var sampledCaptureIngress: (roundID: UUID,
        sources: [AudioSourceType: LocalParakeetASRProvider.CaptureIngressSnapshot.SourceCounters])?
    // This is a display projection of the sole runtime counters. Stopping hides
    // the active count without deleting the retained diagnostic totals.
    var systemAudioASRBufferCount: Int {
        runtime.audioIsRunning ? runtime.bufferCount(for: .systemAudio) : 0
    }
    // One bounded metadata snapshot, not a task registry or UI control fact.
    struct StageBWorkerTrace {
        let generationID: String
        let beganMonotonicNS: UInt64
        var phase: Int = 1
        var tokenCount: Int = 0
        var didExit = false
        var updatedMonotonicNS: UInt64
        var firstPhaseMonotonicNS: [Int: UInt64]

        init(generationID: String) {
            self.generationID = generationID
            let now = DispatchTime.now().uptimeNanoseconds
            beganMonotonicNS = now
            updatedMonotonicNS = now
            firstPhaseMonotonicNS = [1: now]
        }
    }
    private(set) var stageBWorkerTrace: StageBWorkerTrace?

    func beginStageBWorkerTrace(generationID: String) {
        stageBWorkerTrace = StageBWorkerTrace(generationID: generationID)
    }

    func recordStageBWorkerPhase(generationID: String, phase: Int, tokenReceived: Bool = false) {
        guard stageBWorkerTrace?.generationID == generationID else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        stageBWorkerTrace?.phase = phase
        if tokenReceived { stageBWorkerTrace?.tokenCount += 1 }
        if stageBWorkerTrace?.firstPhaseMonotonicNS[phase] == nil {
            if let phases = stageBWorkerTrace?.firstPhaseMonotonicNS, phases.count >= 12,
               let oldest = phases.min(by: { $0.value < $1.value })?.key {
                stageBWorkerTrace?.firstPhaseMonotonicNS.removeValue(forKey: oldest)
            }
            stageBWorkerTrace?.firstPhaseMonotonicNS[phase] = now
        }
        stageBWorkerTrace?.updatedMonotonicNS = now
    }

    func finishStageBWorkerTrace(generationID: String) {
        guard stageBWorkerTrace?.generationID == generationID else { return }
        stageBWorkerTrace?.didExit = true
        stageBWorkerTrace?.updatedMonotonicNS = DispatchTime.now().uptimeNanoseconds
    }
    @Published private(set) var recentEvents: [TranscriptRuntimeEventRecord] = []
    static let retainedEventLimit = 40
    var traceLogURL: URL
    private var highFrequencyEventAt: [String: Date] = [:]
    var sampledIdentityCount: Int { highFrequencyEventAt.count }
    private(set) var sampledIdentityEvictionCount = 0
    private let traceStore: RuntimeTranscriptTraceStore
    private let traceWriter: RuntimeTranscriptTraceStore.Writer
    var traceWriteSnapshot: RuntimeTranscriptTraceStore.WriteSnapshot { traceWriter.snapshot }

    #if DEBUG
    // Nil in normal use. This observes actual synchronous work and request
    // scheduling without retaining text or changing any business timestamp.
    var onPipelineTimingForTesting: (@MainActor (
        String, String?, String?, String?, UInt64, UInt64, Int
    ) -> Void)?
    #endif

    init(traceLogURL: URL, traceStore: RuntimeTranscriptTraceStore = .shared, latencyQuery: LatencyQuery? = nil) {
        self.traceLogURL = traceLogURL
        self.traceStore = traceStore
        self.traceWriter = traceStore.makeWriter()
        self.latencyQuery = latencyQuery
    }

    func updateDeveloper(_ mutate: (inout DeveloperDiagnostics) -> Void) {
        var next = developer
        mutate(&next)
        developer = next
    }

    func record(_ event: TranscriptRuntimeEvent, context: DisplayContext, mode: DiagnosticTraceMode) {
        #if DEBUG
        let timingObserver = onPipelineTimingForTesting
        let beganNS = timingObserver == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        #endif
        updateRuntime(event)
        // Do not allocate/enrich/store a record for each captured PCM buffer.
        if case .audioBufferReceived = event { return }
        guard shouldRecord(event) else { return }
        let record = event.record
        #if DEBUG
        let enrichBeganNS = timingObserver == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        #endif
        let enrichedRecord = enriched(record, context: context)
        #if DEBUG
        let enrichEndedNS = timingObserver == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        #endif
        appendRecord(enrichedRecord, mode: mode)
        #if DEBUG
        if let timingObserver {
            let endedNS = DispatchTime.now().uptimeNanoseconds
            let characters = record.text.utf16.count
            timingObserver("diagnostic.enrich.\(record.name)", record.sessionID,
                record.questionID, record.generationID, enrichBeganNS, enrichEndedNS, characters)
            timingObserver("diagnostic.record_total.\(record.name)", record.sessionID,
                record.questionID, record.generationID, beganNS, endedNS, characters)
        }
        #endif
    }

    /// A retired operation reports its frozen session and exact cleanup result.
    /// It is an audit event: it must not replace the current capture/runtime facts
    /// or borrow transcript/question text from a later session.
    func recordCaptureCleanupResult(sessionID: String, teardownID: UUID,
                                    released: Bool, mode: DiagnosticTraceMode) {
        appendRecord(TranscriptRuntimeEventRecord(timestamp: Date(),
            name: released ? "capture.cleanup.operation.completed" : "capture.cleanup.operation.failed",
            sessionID: sessionID, captureTeardownID: teardownID.uuidString), mode: mode)
    }

    private func appendRecord(_ record: TranscriptRuntimeEventRecord, mode: DiagnosticTraceMode) {
        let memoryRecord = mode == .fullText ? record : record.redactedForMetadata()
        var next = recentEvents
        next.append(memoryRecord)
        if next.count > Self.retainedEventLimit { next.removeFirst(next.count - Self.retainedEventLimit) }
        // Freeze the selected file before a synchronous display observer can
        // change it. File overflow is diagnostic loss, never a UI final/control
        // drop: runtime totals and this bounded memory record are still kept.
        let admittedURL = traceLogURL
        if mode != .off {
            traceWriter.append(line: record.jsonLine(for: mode), to: admittedURL, mode: mode)
        }
        // Observers can now read the authoritative overflow counters.
        recentEvents = next
    }

    // Scalar verification records reuse the existing file writer. They never
    // enrich text, publish UI state or change business runtime totals.
    func recordVerificationTiming(_ event: VerificationTimingEvent, mode: DiagnosticTraceMode) {
        guard VerificationTiming.enabled, mode != .off else { return }
        traceWriter.append(line: VerificationTiming.jsonLine(event), to: traceLogURL, mode: mode)
    }
    func recordVerificationPCM(_ batch: VerificationPCMLeaf.Batch, mode: DiagnosticTraceMode) {
        guard VerificationTiming.enabled, mode != .off else { return }
        traceWriter.append(line: VerificationTiming.jsonLine(batch), to: traceLogURL, mode: mode)
    }

    func reset(clearEvents: Bool) {
        runtime = .empty
        sampledCaptureIngress = nil
        if clearEvents {
            recentEvents = []
            highFrequencyEventAt = [:]
            sampledIdentityEvictionCount = 0
        }
    }

    func markAudioStopped() { runtime.audioIsRunning = false }

    func sampleCaptureIngress(_ snapshot: LocalParakeetASRProvider.CaptureIngressSnapshot,
                              sessionID: String) -> [TranscriptRuntimeEvent] {
        let previous = sampledCaptureIngress?.roundID == snapshot.roundID
            ? sampledCaptureIngress?.sources ?? [:] : [:]
        sampledCaptureIngress = (snapshot.roundID, snapshot.sources)
        return [AudioSourceType.microphone, .systemAudio].sorted {
            (snapshot.sources[$0]?.lastBufferAt ?? .distantPast) < (snapshot.sources[$1]?.lastBufferAt ?? .distantPast)
        }.compactMap { source in
            guard let current = snapshot.sources[source], let timestamp = current.lastBufferAt else { return nil }
            let delta = current.bufferCount - (previous[source]?.bufferCount ?? 0)
            guard delta > 0 else { return nil }
            return .audioBufferReceived(sessionID: sessionID,
                frameCount: max(0, current.frameCount - (previous[source]?.frameCount ?? 0)),
                timestamp: timestamp, bufferCount: delta, source: source)
        }
    }

    func exportText(mode: DiagnosticTraceMode) -> String {
        recentEvents.compactMap { $0.jsonLine(for: mode) }.joined(separator: "\n")
    }

    func prepareForMode(_ mode: DiagnosticTraceMode) {
        traceStore.prepareForMode(mode, at: traceLogURL)
    }

    func clearTrace() throws {
        try traceStore.clearTraceFiles(at: traceLogURL)
        recentEvents = []
        highFrequencyEventAt = [:]
        sampledIdentityEvictionCount = 0
    }

    private func updateRuntime(_ event: TranscriptRuntimeEvent) {
        switch event {
        case let .audioStarted(sessionID, _):
            runtime.audioSessionID = sessionID
            runtime.audioIsRunning = true
        case let .audioBufferReceived(sessionID, _, timestamp, bufferCount, source):
            runtime.audioSessionID = sessionID
            runtime.audioIsRunning = true
            runtime.lastAudioBufferAt = timestamp
            runtime.recordAudioBufferBatch(count: bufferCount, source: source)
        case let .asrPartial(sessionID, _, _, _, _, _, _, timestamp):
            runtime.audioSessionID = sessionID
            runtime.audioIsRunning = true
            runtime.lastASRPartialAt = timestamp
            runtime.partialTranscriptCount += 1
        case let .asrFinal(sessionID, _, _, _, _, _, _, timestamp):
            runtime.audioSessionID = sessionID
            runtime.audioIsRunning = true
            runtime.lastASRFinalAt = timestamp
            runtime.finalTranscriptCount += 1
        case let .utteranceCandidate(sessionID, _, timestamp):
            runtime.audioSessionID = sessionID
            runtime.lastQuestionCandidateAt = timestamp
        case let .questionAccepted(sessionID, _, timestamp):
            runtime.audioSessionID = sessionID
            runtime.lastQuestionAcceptedAt = timestamp
        case let .questionRejected(sessionID, _, _, timestamp):
            runtime.audioSessionID = sessionID
            runtime.lastQuestionRejectedAt = timestamp
        case let .generationStarted(sessionID, _, _, _, timestamp):
            runtime.audioSessionID = sessionID
            runtime.lastGenerationStartedAt = timestamp
            runtime.lastGenerationRejectedReason = ""
        case let .generationCompleted(sessionID, _, _, _, _):
            runtime.audioSessionID = sessionID
            runtime.lastGenerationRejectedReason = ""
        case let .generationTimedOut(sessionID, _, _, _, _):
            runtime.audioSessionID = sessionID
            runtime.lastGenerationRejectedReason = "timed_out"
        case let .generationRejected(sessionID, _, reason, _):
            runtime.audioSessionID = sessionID
            runtime.lastGenerationRejectedReason = reason.rawValue
        case let .partialAnswerRejectedIncomplete(sessionID, _, _, _, reason, _),
             let .persistenceRejected(sessionID, _, _, _, reason, _),
             let .cancelledGenerationPersistenceRejected(sessionID, _, _, _, reason, _):
            runtime.audioSessionID = sessionID
            runtime.lastGenerationRejectedReason = reason
        case let .duplicatePersistenceRejected(sessionID, _, _, _, _, reason, _),
             let .cumulativeReplayRejected(sessionID, _, _, _, _, _, _, _, _, reason, _),
             let .staleGenerationResultRejected(sessionID, _, _, _, _, _, _, _, reason, _),
             let .currentCardRegressionRejected(sessionID, _, _, _, _, _, _, _, reason, _):
            runtime.audioSessionID = sessionID
            runtime.lastGenerationRejectedReason = reason
        case let .duplicatePartialSuppressed(sessionID, _, _, _):
            runtime.audioSessionID = sessionID
            runtime.lastQuestionRejectedAt = Date()
        case let .answerRejectedWrongProjectGrounding(sessionID, _, _, _, _, _):
            runtime.audioSessionID = sessionID
            runtime.lastGenerationRejectedReason = QuestionRuntimeRejectionReason.mismatchedAlignment.rawValue
        case let .lifecycle(_, sessionID, _, _, _, _, reason, _, skipped, _):
            runtime.audioSessionID = sessionID
            if skipped || !reason.isEmpty { runtime.lastGenerationRejectedReason = reason }
        case let .questionQueued(sessionID, _, _, _, _),
             let .questionDequeued(sessionID, _, _, _, _),
             let .queueDepthChanged(sessionID, _, _, _),
             let .queueDrainRequested(sessionID, _, _, _),
             let .queueDrainBlocked(sessionID, _, _, _),
             let .utteranceBufferConsumed(sessionID, _, _, _),
             let .utteranceBufferReset(sessionID, _, _, _),
             let .generationSkippedBecauseActive(sessionID, _, _, _, _),
             let .fallbackUsedForIncompleteStream(sessionID, _, _, _, _, _),
             let .persistenceStarted(sessionID, _, _, _, _),
             let .persistenceSucceeded(sessionID, _, _, _, _),
             let .intentionalQuestionRepeatAccepted(sessionID, _, _, _, _),
             let .questionHistoryAppended(sessionID, _, _, _, _),
             let .visibleCurrentSuggestionUpdated(sessionID, _, _, _, _),
             let .queuedAnswerPersisted(sessionID, _, _, _, _),
             let .uiHistoryRefresh(sessionID, _, _, _):
            runtime.audioSessionID = sessionID
        }
    }

    private func shouldRecord(_ event: TranscriptRuntimeEvent) -> Bool {
        switch event {
        case .audioBufferReceived:
            return false
        case let .asrPartial(sessionID, _, recognitionTaskID, _, _, _, _, timestamp):
            return claim("asrPartial|\(sessionID)|\(recognitionTaskID ?? "session")", timestamp: timestamp)
        case let .partialAnswerRejectedIncomplete(sessionID, questionID, generationID, _, _, timestamp):
            return claim("partialAnswerRejectedIncomplete|\(sessionID)|\(generationID ?? questionID ?? "unknown")", timestamp: timestamp)
        case let .visibleCurrentSuggestionUpdated(sessionID, questionID, generationID, _, timestamp):
            return claim("visibleCurrentSuggestionUpdated|\(sessionID)|\(generationID ?? questionID ?? "unknown")", timestamp: timestamp)
        case let .lifecycle(eventName, sessionID, questionID, generationID, _, _, _, _, _, timestamp)
            where eventName == "transcript.partial" || eventName == "answer.ui.rendered":
            return claim("\(eventName)|\(sessionID)|\(generationID ?? questionID ?? "session")", timestamp: timestamp)
        default:
            return true
        }
    }

    private func claim(_ key: String, timestamp: Date) -> Bool {
        if let previous = highFrequencyEventAt[key], timestamp.timeIntervalSince(previous) < 1.0 { return false }
        // Eviction forgets diagnostic throttling only; a revisited identity may be sampled again within one second.
        if highFrequencyEventAt[key] == nil, highFrequencyEventAt.count >= Self.retainedEventLimit,
           let oldest = highFrequencyEventAt.min(by: {
               $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
           })?.key {
            highFrequencyEventAt.removeValue(forKey: oldest)
            sampledIdentityEvictionCount += 1
        }
        highFrequencyEventAt[key] = timestamp
        return true
    }

    private func enriched(_ input: TranscriptRuntimeEventRecord, context: DisplayContext) -> TranscriptRuntimeEventRecord {
        var record = input
        let sourceText = record.rawText.isEmpty ? record.text : record.rawText
        if !sourceText.isEmpty {
            let canonicalTerms = ASRCanonicalizer.canonicalizeTerms(sourceText)
            if record.canonicalText.isEmpty { record.canonicalText = QuestionCanonicalizer.canonicalize(sourceText) }
            let splitCandidates = MultiQuestionSplitter.split(canonicalTerms).map { RawQuestionCleaner.clean($0) }.filter { !$0.isEmpty }
            if record.splitCandidates.isEmpty { record.splitCandidates = splitCandidates }
            let acceptedCandidates = QuestionCandidatePipeline.extract(from: sourceText)
            if record.completenessResult.isEmpty {
                record.completenessResult = acceptedCandidates.isEmpty
                    ? (QuestionCompletenessGate.isIncompleteFragment(sourceText) ? "incomplete" : "not_accepted")
                    : "accepted:\(acceptedCandidates.count)"
            }
            if let first = acceptedCandidates.first {
                if record.candidateText.isEmpty { record.candidateText = first.text }
                if record.questionIntent.isEmpty { record.questionIntent = first.answerRelevanceIntent.rawValue }
                if record.intentResult.isEmpty { record.intentResult = first.intent.rawValue }
                if record.duplicateKey.isEmpty { record.duplicateKey = first.duplicateKey }
            }
        }
        if record.acceptanceStatus.isEmpty { record.acceptanceStatus = "observed" }
        if record.rejectionReason.isEmpty { record.rejectionReason = record.reason }
        if record.generationRejectedReason.isEmpty, record.name == "generationRejected" {
            record.generationRejectedReason = record.rejectionReason
        }
        record.uiTranscriptText = context.transcriptText
        record.visibleQuestionText = context.visibleQuestionText
        return record
    }
}
