import Combine
import Foundation

/// Owns history records and recap work. Each request freezes its source revision;
/// cancelled roots stay owned through provider cleanup and cannot publish later.
@MainActor
final class HistoryState: ObservableObject {
    @Published var sessions: [InterviewSession] = []
    @Published var selectedSessionID: String?
    @Published var selectedSessionTranscript: [TranscriptSegment] = []
    @Published var selectedSessionSuggestions: [SuggestionCard] = []
    @Published var selectedSessionRecap: RecapReport?
    @Published var historicalSuggestionChunks: [String: [RetrievedChunk]] = [:]
    var isGeneratingRecap: Bool { recapTask != nil }

    private let sessionRepository: SessionRepository
    private let transcriptRepository: TranscriptRepository
    private let suggestionRepository: SuggestionRepository
    private let recapRepository: RecapRepository

    init(
        sessions: SessionRepository,
        transcripts: TranscriptRepository,
        suggestions: SuggestionRepository,
        recaps: RecapRepository,
        corrections: HistoryCorrectionRepository,
        practice: PracticeRepository,
        recapService: RecapGenerationService,
        consent: PersistenceConsent
    ) {
        sessionRepository = sessions
        transcriptRepository = transcripts
        suggestionRepository = suggestions
        recapRepository = recaps
        self.corrections = corrections
        practiceRepository = practice
        self.recapService = recapService
        self.consent = consent
    }

    private let corrections: HistoryCorrectionRepository
    private let practiceRepository: PracticeRepository
    private let recapService: RecapGenerationService
    private let consent: PersistenceConsent
    private var recapID = UUID()
    private(set) var recapTask: Task<Void, Never>?
    private(set) var recapSessionID: String?
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var drainWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var admissionClosed = false

    var pendingRecapTaskCount: Int { retiring.count + (recapTask == nil ? 0 : 1) }
    var retiringRecapTaskCount: Int { retiring.count }

    /// Submission is synchronous: source revisions, cached inputs and the
    /// explicit provider configuration are frozen before the root can suspend.
    /// Callbacks publish typed UI feedback only; they grant no app capabilities.
    @discardableResult
    func requestRecap(
        sessionID: String,
        providerConfiguration: LLMProviderConfiguration?,
        routingProvider: any LocalLLMProvider,
        routingModel: String,
        localOnly: Bool,
        persistenceAllowed: @escaping @MainActor () -> Bool,
        onFeedback: @escaping @MainActor (ActionFeedback) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        didPublish: @escaping @MainActor (LLMChatResult) -> Void
    ) throws -> Task<Void, Never>? {
        guard !admissionClosed else { throw CancellationError() }
        guard let session = try sessionRepository.session(id: sessionID) else { throw CancellationError() }
        let ticket = consent.ticket()
        guard persistenceAllowed(), consent.isCurrent(ticket: ticket) else { throw CancellationError() }
        // Existing validated Practice feedback stays a distinct synchronous
        // path. It does not invoke an LLM or turn a model score into a rating.
        if let practice = try? practiceRepository.load(sessionID: session.id) {
            invalidateRecap()
            let id = recapID
            recapSessionID = session.id
            defer {
                // A success observer may submit another recap synchronously.
                // Finishing this branch cannot erase the replacement identity.
                if recapID == id { recapSessionID = nil }
            }
            objectWillChange.send()
            guard persistenceAllowed(), !Task.isCancelled,
                  isCurrent(id, sessionID: session.id),
                  try sessionRepository.session(id: session.id)?.contentRevision == session.contentRevision else {
                throw CancellationError()
            }
            let recap = RecapReport(id: "practice-recap-" + session.id + "-v\(session.contentRevision ?? 0)",
                sessionID: session.id, markdown: RecapGenerationService.practiceMarkdown(practice),
                modelName: "Practice feedback · structural checks only", promptVersion: practice.task.rubricVersion,
                isLocal: true, createdAt: Date(), contentRevision: session.contentRevision ?? 0)
            try consent.write(ticket: ticket) { try recapRepository.saveRecap(recap) }
            if selectedSessionID == session.id { selectedSessionRecap = recap }
            guard isCurrent(id, sessionID: session.id) else { return nil }
            onFeedback(.init(actionID: ActionID.sessionRecap, title: "Recap ready",
                message: "All attempts included with source quotes and coverage.", kind: .success,
                autoDismissAfter: 4.0))
            return nil
        }
        // A missing frozen remote configuration is never resolved later from
        // mutable settings. Local-only does not need or access that capability.
        guard localOnly || providerConfiguration != nil else {
            throw LLMProviderError.notConfigured("Recap LLM provider")
        }
        let transcript = try corrections.effectiveTranscript(
            transcriptRepository.segments(sessionID: session.id), sessionID: session.id)
        let questions = try corrections.effectiveQuestions(
            suggestionRepository.questions(sessionID: session.id), transcript: transcript, sessionID: session.id)
        let revisions = try corrections.revisions(sessionID: session.id)
        let latest = Dictionary(revisions.map { ($0.segmentID, $0) }, uniquingKeysWith: { _, last in last })
        let suppressed = Set(latest.values.filter { !$0.startsQuestion }.map(\.segmentID))
        let cached = try recapRepository.cachedUnits(sessionID: session.id)
        let namespace = [providerConfiguration?.id.uuidString ?? "",
            providerConfiguration?.baseURL ?? "", providerConfiguration?.model ?? ""].joined(separator: "|")
        let service = recapService
        invalidateRecap()
        let id = recapID
        recapSessionID = session.id
        // Avoid retaining the feature owner across provider awaits. A shutdown
        // caller retains and joins it; late completion cannot revive an owner.
        let task = Task { [weak self] in
            defer { self?.didExit(id) }
            do {
                try Task.checkCancellation()
                guard self?.isCurrent(id, sessionID: session.id) == true else { return }
                let result = try await service.generate(session: session, transcript: transcript,
                    context: RetrievedContext(cvChunks: [], jobDescriptionChunks: [], additionalNotesChunks: []),
                    questions: questions, model: providerConfiguration?.model,
                    providerConfiguration: providerConfiguration, routingProvider: routingProvider,
                    routingModel: routingModel, cachedUnits: cached,
                    suppressedQuestionBoundaries: suppressed, cacheNamespace: namespace, localOnly: localOnly)
                try self?.accept(result, session: session, id: id, ticket: ticket,
                    persistenceAllowed: persistenceAllowed, onFeedback: onFeedback, didPublish: didPublish)
            } catch {
                self?.failed(error, session: session, id: id, onFeedback: onFeedback, onError: onError)
            }
        }
        recapTask = task
        // State is coherent before synchronous observers can cancel or replace.
        objectWillChange.send()
        guard isCurrent(id, sessionID: session.id) else { return task }
        onFeedback(.init(actionID: ActionID.sessionRecap, title: "Generating recap",
            message: "Processing all saved text units; unknown speakers are not graded...", kind: .loading))
        return task
    }

    private func isCurrent(_ id: UUID, sessionID: String) -> Bool {
        !admissionClosed && recapID == id && recapSessionID == sessionID
    }

    private func accept(
        _ result: (recap: RecapReport, response: LLMChatResult, units: [CachedRecapUnit]),
        session: InterviewSession, id: UUID, ticket: Int,
        persistenceAllowed: @MainActor () -> Bool,
        onFeedback: @MainActor (ActionFeedback) -> Void, didPublish: @MainActor (LLMChatResult) -> Void
    ) throws {
        guard persistenceAllowed() else { throw CancellationError() }
        try Task.checkCancellation()
        guard isCurrent(id, sessionID: session.id),
              try sessionRepository.session(id: session.id)?.contentRevision == session.contentRevision else {
            throw CancellationError()
        }
        // Permission validation and both existing SQL writes stay in the same
        // synchronous admission boundary. No normal lock is held across await.
        // The two repository calls are not claimed as one SQLite transaction.
        try consent.write(ticket: ticket) {
            try recapRepository.saveRecap(result.recap)
            try recapRepository.saveUnits(result.units, sessionID: session.id)
        }
        if selectedSessionID == session.id { selectedSessionRecap = result.recap }
        guard isCurrent(id, sessionID: session.id) else { return }
        didPublish(result.response)
        guard isCurrent(id, sessionID: session.id) else { return }
        onFeedback(.init(actionID: ActionID.sessionRecap, title: "Recap ready",
            message: "Session recap is visible.", kind: .success, autoDismissAfter: 4.0))
    }

    private func failed(_ error: Error, session: InterviewSession, id: UUID,
        onFeedback: @MainActor (ActionFeedback) -> Void, onError: @MainActor (String) -> Void) {
        guard !(error is CancellationError), !Task.isCancelled,
              isCurrent(id, sessionID: session.id) else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        onFeedback(.init(actionID: ActionID.sessionRecap, title: "Recap failed",
            message: message, kind: .error, autoDismissAfter: nil))
        guard !Task.isCancelled, isCurrent(id, sessionID: session.id) else { return }
        onError(message)
    }

    /// Invalidation precedes cancellation. The old root stays in this owner's
    /// retiring set until its service and exact local producers actually exit.
    func cancelRecap(sessionID: String? = nil) {
        if let sessionID, recapSessionID != sessionID { return }
        invalidateRecap()
        objectWillChange.send()
    }

    private func invalidateRecap() {
        let previous = recapID
        recapID = UUID()
        recapSessionID = nil
        if let task = recapTask {
            retiring[previous] = task
            task.cancel()
        }
        recapTask = nil
    }

    private func didExit(_ id: UUID) {
        retiring.removeValue(forKey: id)
        if recapID == id {
            recapTask = nil
            recapSessionID = nil
        }
        objectWillChange.send()
        if retiring.isEmpty { drainWaiters.values.forEach { $0.yield(()) } }
    }

    func closeAdmission() {
        admissionClosed = true
        cancelRecap()
    }

    func drainRetiredRecaps() async {
        guard !retiring.isEmpty, !Task.isCancelled else { return }
        let id = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        drainWaiters[id] = continuation
        defer { drainWaiters.removeValue(forKey: id); continuation.finish() }
        for await _ in events { if retiring.isEmpty { return } }
    }

    /// The deadline ends only the observer. Uncooperative work remains owned
    /// and counted, so a caller cannot report resource cleanup complete.
    func shutdownAndDrain(timeout: TimeInterval = 5, delayProvider: DelayProvider = RealDelayProvider()) async -> Bool {
        closeAdmission()
        do {
            try await GenerationCoordinator.withTimeout(seconds: timeout, delayProvider: delayProvider) { @MainActor in
                await self.drainRetiredRecaps()
            }
            return retiring.isEmpty
        } catch { return false }
    }

    deinit {
        recapTask?.cancel()
        retiring.values.forEach { $0.cancel() }
        drainWaiters.values.forEach { $0.finish() }
    }

    func refreshSessions() throws {
        sessions = try sessionRepository.listSessions()
    }

    func loadSessionDetails(sessionID: String) throws {
        // Complete the reads before publishing, so an I/O failure cannot display
        // one session's ID alongside another session's transcript or recap.
        let transcript = try transcriptRepository.segments(sessionID: sessionID)
        let cards = try suggestionRepository.suggestions(sessionID: sessionID)
        let recap = try recapRepository.recap(sessionID: sessionID)
        var chunks: [String: [RetrievedChunk]] = [:]
        for card in cards {
            chunks[card.id] = (try? suggestionRepository.retrievedChunks(suggestionCardID: card.id)) ?? []
        }
        selectedSessionID = sessionID
        selectedSessionTranscript = transcript
        selectedSessionSuggestions = cards
        selectedSessionRecap = recap
        historicalSuggestionChunks = chunks
    }

    func clearSelection() {
        selectedSessionID = nil
        selectedSessionTranscript = []
        selectedSessionSuggestions = []
        selectedSessionRecap = nil
        historicalSuggestionChunks = [:]
    }
}
