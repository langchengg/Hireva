import Foundation
import Combine

/// Owns answer-request launch identity, its root task, and generation child tasks.
///
/// UI application, evidence validation and persistence remain separate boundaries.
/// Cancellation is cooperative: identity invalidation prevents a late callback
/// from publishing even when its provider has not finished cleaning up yet.
@MainActor
final class GenerationCoordinator: ObservableObject {
    struct ActiveGeneration {
        let persistenceTicket: Int
        let identity: GenerationIdentity
        let triggerPath: GenerationTriggerPath
        let startedAt: Date
        let providerConfiguration: LLMProviderConfiguration?
        let answerProviderMode: AnswerProviderMode?
        // The accepted question and routed policy share this one value snapshot.
        // A replacement copies this record before retiring its children; history
        // must not reconstruct the evidence decision from current UI or SQL.
        fileprivate(set) var questionSnapshot: DetectedQuestion?
        fileprivate(set) var questionRoutingTask: Task<InterviewQuestionDecision, Error>?
        fileprivate(set) var questionRoutingRegistrationID: UUID?
        fileprivate(set) var contextRetrievalTask: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>?
        fileprivate(set) var contextRetrievalRegistrationID: UUID?
        fileprivate(set) var stageATask: Task<String, Error>?
        fileprivate(set) var stageALaunchID: UUID?
        fileprivate(set) var stageATimeoutTask: Task<Void, Never>?
        fileprivate(set) var stageATimeoutRegistrationID: UUID?
        fileprivate(set) var stageADeadlineAnswerPreserved = false
        fileprivate(set) var stageBTask: Task<Void, Never>?
        fileprivate(set) var stageBLaunchID: UUID?
        // A real JSON provider child, distinct from the retained Manual router/RAG worker.
        fileprivate(set) var manualProviderTask: Task<(card: SuggestionCard, response: LLMChatResult), Error>?
        fileprivate(set) var manualProviderRegistrationID: UUID?
        fileprivate(set) var fallbackWatchdogTask: Task<Void, Never>?
        fileprivate(set) var fullCardWatchdogTask: Task<Void, Never>?
        fileprivate(set) var queuedQuestionHandoffTask: Task<Void, Never>?
        fileprivate(set) var queuedQuestionHandoffRegistrationID: UUID?

        var generationID: String { identity.generationID }
        var questionID: String? { identity.acceptedQuestionID }
        var questionTextSnapshot: String { identity.questionText }
        var questionIntent: AnswerRelevanceIntent { identity.questionIntent }
        var hasTasks: Bool {
            questionRoutingTask != nil || contextRetrievalTask != nil || stageATask != nil || stageATimeoutTask != nil || stageBTask != nil ||
                fallbackWatchdogTask != nil || fullCardWatchdogTask != nil || queuedQuestionHandoffTask != nil || manualProviderTask != nil
        }

        fileprivate func cancelAll() {
            questionRoutingTask?.cancel()
            contextRetrievalTask?.cancel()
            stageATask?.cancel()
            stageATimeoutTask?.cancel()
            stageBTask?.cancel()
            manualProviderTask?.cancel()
            fallbackWatchdogTask?.cancel()
            fullCardWatchdogTask?.cancel()
            queuedQuestionHandoffTask?.cancel()
        }
    }

    enum TaskRole: Sendable {
        case stageATimeout, stageB, fallbackWatchdog, fullCardWatchdog, queuedQuestionHandoff
    }

    enum LocalAnswerRetry: Sendable {
        case emptyPrimary, alignmentRejected, compactRecovery, groundedRecovery
    }

    enum LocalAnswerEvent {
        case requestStarted(LocalLLMRequest, launchID: UUID, requestIndex: Int, attempt: Int)
        case streamCompleted(String, launchID: UUID, requestIndex: Int, attempt: Int)
        case answerParsed(LocalQwenParsedAnswer)
        case alignmentStarted
        case alignmentCompleted(LocalQwenAnswerValidationResult)
        case retrying(LocalAnswerRetry)
        case requestFailed(OllamaFailureCategory)
        case exhausted(OllamaFailureCategory)
    }

    struct ActiveRequest {
        let id: String
        let triggerPath: GenerationTriggerPath
        fileprivate(set) var task: Task<Void, Never>?
    }

    // Combine synthesizes its nonisolated publisher from this notification
    // counter. Keep the owned task record as stored state so deinit can cancel
    // it without invoking a MainActor-isolated property-wrapper accessor.
    @Published private var observationRevision = 0
    private(set) var activeGeneration: ActiveGeneration? {
        didSet { ownershipChanged() }
    }
    private(set) var activeRequest: ActiveRequest? {
        didSet { ownershipChanged() }
    }
    // Notification metadata only: owned records remain the sole authority.
    // Compound synchronous mutations expose one committed record/retirement
    // snapshot. These scopes never cross await or hold an ordinary lock.
    private var ownershipMutationDepth = 0
    private var ownershipPublicationPending = false

    private func beginOwnershipMutation() { ownershipMutationDepth += 1 }
    private func endOwnershipMutation() {
        precondition(ownershipMutationDepth > 0)
        ownershipMutationDepth -= 1
        guard ownershipMutationDepth == 0, ownershipPublicationPending else { return }
        ownershipPublicationPending = false
        observationRevision &+= 1
    }
    private func ownershipChanged() {
        if ownershipMutationDepth > 0 { ownershipPublicationPending = true }
        else { observationRevision &+= 1 }
    }
    private(set) var terminalGenerationIDs = Set<String>()
    private var retiringTasks: [UUID: RetiringTask] = [:]
    private var drainWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var isShuttingDown = false

    private enum OwnedTask: Sendable {
        case questionRouting(Task<InterviewQuestionDecision, Error>)
        case contextRetrieval(Task<(context: RetrievedContext, trace: RetrievalTrace), Error>)
        case answer(Task<String, Error>)
        case control(Task<Void, Never>)
        case localAnswerProducer(Task<Void, Never>)
        case manualProvider(Task<(card: SuggestionCard, response: LLMChatResult), Error>)

        nonisolated func cancel() {
            switch self {
            case .questionRouting(let task): task.cancel()
            case .contextRetrieval(let task): task.cancel()
            case .answer(let task): task.cancel()
            case .control(let task), .localAnswerProducer(let task): task.cancel()
            case .manualProvider(let task): task.cancel()
            }
        }
        nonisolated func awaitExit() async {
            switch self {
            case .questionRouting(let task): _ = await task.result
            case .contextRetrieval(let task): _ = await task.result
            case .answer(let task): _ = await task.result
            case .control(let task), .localAnswerProducer(let task): await task.value
            case .manualProvider(let task): _ = await task.result
            }
        }
    }

    private enum ControlTaskExecutionScope {
        @TaskLocal static var launchID: UUID? = nil
    }

    private struct RetiringTask: Sendable {
        let work: OwnedTask
        let join: Task<Void, Never>
        // Metadata on the existing retained work, not a second task registry.
        let controlLaunchID: UUID?
    }

    /// An owned Manual worker or its inherited child cannot await a drain that
    /// waits for this exact still-live launch. Expired inherited scope is safe.
    var canDrainFromCurrentTask: Bool {
        guard let launchID = ControlTaskExecutionScope.launchID else { return true }
        return activeGeneration?.stageBLaunchID != launchID &&
            !retiringTasks.values.contains { $0.controlLaunchID == launchID }
    }

    var retiringTaskCount: Int { retiringTasks.count }
    /// Exact provider producers transferred to the sole retirement registry.
    /// This is a projection, not a second task list or a mirrored counter.
    var retiringLocalProducerTaskCount: Int {
        retiringTasks.values.filter {
            if case .localAnswerProducer = $0.work { return true }
            return false
        }.count
    }

    /// Derived lifecycle projection; no mirrored registry or writable counter.
    var retiringContextRetrievalTaskCount: Int {
        retiringTasks.values.filter {
            if case .contextRetrieval = $0.work { return true }
            return false
        }.count
    }

    var requestTask: Task<Void, Never>? { activeRequest?.task }
    /// Read-only lifecycle diagnostics, derived from the owner's task handles.
    /// A cancelled task is still pending cleanup until its actual exit.
    var pendingCleanupTaskCount: Int {
        let children = [activeGeneration?.stageATimeoutTask, activeGeneration?.stageBTask,
            activeGeneration?.fallbackWatchdogTask, activeGeneration?.fullCardWatchdogTask, activeGeneration?.queuedQuestionHandoffTask]
        return retiringTasks.count + (activeRequest?.task == nil ? 0 : 1) +
            (activeGeneration?.stageATask == nil ? 0 : 1) + children.compactMap { $0 }.count +
            (activeGeneration?.manualProviderTask == nil ? 0 : 1) +
            (activeGeneration?.contextRetrievalTask == nil ? 0 : 1) +
            (activeGeneration?.questionRoutingTask == nil ? 0 : 1)
    }

    var autoLaunchPending: Bool {
        activeRequest?.triggerPath == .autoDetect && activeGeneration == nil
    }

    /// A launch owns work even before routing has produced a generation record.
    /// Revoke both identities synchronously before asking previous work to stop.
    func beginRequest(triggerPath: GenerationTriggerPath) -> String {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        invalidateAndCancel()
        let id = UUID().uuidString
        guard !isShuttingDown else { return id }
        activeRequest = ActiveRequest(id: id, triggerPath: triggerPath)
        return id
    }

    /// The application supplies a narrow operation; this owner creates, registers,
    /// retires and joins the root. The operation does not hold a coordinator back-reference.
    @discardableResult
    func launchRequest(
        triggerPath: GenerationTriggerPath,
        operation: @escaping @MainActor (String) async -> Void
    ) -> String {
        let id = beginRequest(triggerPath: triggerPath)
        guard isCurrentRequest(id) else { return id }
        let task = Task { [weak self] in
            guard self?.isCurrentRequest(id) == true, !Task.isCancelled else { return }
            defer { self?.finishRequest(requestID: id) }
            await operation(id)
        }
        registerRequestTask(task, requestID: id)
        return id
    }

    func isCurrentRequest(_ requestID: String) -> Bool { activeRequest?.id == requestID }

    @discardableResult
    func registerRequestTask(_ task: Task<Void, Never>, requestID: String) -> Bool {
        guard isCurrentRequest(requestID) else { retire(.control(task), cancel: true); return false }
        beginOwnershipMutation()
        let previous = activeRequest?.task
        activeRequest?.task = task
        if let previous { retire(.control(previous), cancel: true) }
        endOwnershipMutation()
        // A synchronous subscriber may submit a newer root at publication.
        return isCurrentRequest(requestID) && activeRequest?.task == task
    }

    func finishRequest(requestID: String) {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        guard isCurrentRequest(requestID) else { return }
        let task = activeRequest?.task
        activeRequest = nil
        // Called from the root's defer: transfer ownership synchronously, never
        // await that same task here. Its join observer runs after the root exits.
        if let task { retire(.control(task), cancel: false) }
    }

    var stageATask: Task<String, Error>? { activeGeneration?.stageATask }
    var stageBTask: Task<Void, Never>? { activeGeneration?.stageBTask }
    var fallbackWatchdogTask: Task<Void, Never>? { activeGeneration?.fallbackWatchdogTask }
    var fullCardWatchdogTask: Task<Void, Never>? { activeGeneration?.fullCardWatchdogTask }
    var queuedQuestionHandoffTask: Task<Void, Never>? { activeGeneration?.queuedQuestionHandoffTask }

    func activate(
        identity: GenerationIdentity,
        persistenceTicket: Int,
        triggerPath: GenerationTriggerPath,
        startedAt: Date,
        providerConfiguration: LLMProviderConfiguration? = nil,
        answerProviderMode: AnswerProviderMode? = nil,
        questionSnapshot: DetectedQuestion? = nil
    ) {
        if let questionSnapshot {
            let snapshotIdentity = GenerationIdentity(question: questionSnapshot,
                generationID: identity.generationID, promptPrimaryQuestion: identity.promptPrimaryQuestion,
                contextSnapshotID: identity.contextSnapshotID)
            guard snapshotIdentity.mismatchReason(comparedTo: identity) == nil else { return }
        }
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        let previous = activeGeneration
        activeGeneration = nil
        retireGeneration(previous, cancel: true)
        guard !isShuttingDown else { return }
        activeGeneration = ActiveGeneration(
            persistenceTicket: persistenceTicket,
            identity: identity,
            triggerPath: triggerPath,
            startedAt: startedAt,
            providerConfiguration: providerConfiguration,
            answerProviderMode: answerProviderMode,
            questionSnapshot: questionSnapshot
        )
    }

    /// Clear the authoritative identity before cancellation can invoke cleanup.
    @discardableResult
    func invalidateAndCancel() -> ActiveGeneration? {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        let previous = activeGeneration
        let previousRequest = activeRequest
        activeGeneration = nil
        activeRequest = nil
        if let task = previousRequest?.task { retire(.control(task), cancel: true) }
        retireGeneration(previous, cancel: true)
        return previous
    }

    func isCurrent(_ generationID: String) -> Bool {
        activeGeneration?.generationID == generationID
    }

    func isCurrent(_ identity: GenerationIdentity) -> Bool {
        guard let current = activeGeneration?.identity else { return false }
        return identity.mismatchReason(comparedTo: current) == nil
    }

    func canPublish(_ identity: GenerationIdentity) -> Bool {
        isCurrent(identity) && !terminalGenerationIDs.contains(identity.generationID)
    }

    func hasPreservedStageADeadlineAnswer(identity: GenerationIdentity) -> Bool {
        isCurrent(identity) && activeGeneration?.stageADeadlineAnswerPreserved == true
    }

    @discardableResult
    func recordPreservedStageADeadlineAnswer(identity: GenerationIdentity) -> Bool {
        guard canPublish(identity) else { return false }
        if activeGeneration?.stageADeadlineAnswerPreserved == true { return true }
        beginOwnershipMutation()
        activeGeneration?.stageADeadlineAnswerPreserved = true
        endOwnershipMutation()
        return isCurrent(identity) && activeGeneration?.stageADeadlineAnswerPreserved == true
    }

    func markTerminal(generationID: String) {
        guard isCurrent(generationID), !terminalGenerationIDs.contains(generationID) else { return }
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        terminalGenerationIDs.insert(generationID)
        clearTask(role: .queuedQuestionHandoff, generationID: generationID)
        clearTask(role: .fallbackWatchdog, generationID: generationID)
        ownershipChanged()
    }

    /// Session reset may discard audit fences only after active work is invalid.
    func resetTerminalHistory() {
        guard activeGeneration == nil, activeRequest == nil else { return }
        terminalGenerationIDs.removeAll()
        ownershipChanged()
    }

    @discardableResult
    func registerStageATask(_ task: Task<String, Error>, generationID: String, launchID: UUID? = nil) -> Bool {
        guard isCurrent(generationID), !terminalGenerationIDs.contains(generationID) else {
            retire(.answer(task), cancel: true)
            return false
        }
        let registeredLaunchID = launchID ?? UUID()
        beginOwnershipMutation()
        let previous = activeGeneration?.stageATask
        activeGeneration?.stageATask = task
        activeGeneration?.stageALaunchID = registeredLaunchID
        if let previous { retire(.answer(previous), cancel: true) }
        endOwnershipMutation()
        // Registration is useful to the caller only while this exact task and
        // launch remain owned, including same-generation subscriber replacement.
        return isCurrent(generationID) && activeGeneration?.stageATask == task &&
            activeGeneration?.stageALaunchID == registeredLaunchID
    }

    /// Owns creation, registration and consumption of the frozen Stage A stream.
    /// Application callbacks are synchronous on MainActor. The production caller
    /// captures its UI owner weakly. Each output is fenced by the complete
    /// identity; normal completion leaves retirement to the awaiting root.
    @discardableResult
    func launchStageAFirstAnswer(
        context: GenerationExecutionContext,
        providerQuestion: DetectedQuestion,
        providerContext: RetrievedContext,
        cvSummary: String,
        jdSummary: String,
        providerConfiguration: LLMProviderConfiguration?,
        onStarted: @escaping @MainActor (GenerationIdentity) -> Void,
        onToken: @escaping @MainActor (GenerationIdentity, String, String) -> Bool,
        onCompleted: @escaping @MainActor (GenerationIdentity, String) -> String?,
        onRejected: @escaping @MainActor (GenerationIdentity) -> Void,
        onExit: @escaping @MainActor () -> Void
    ) -> Task<String, Error>? {
        let identity = context.identity
        let providerIdentity = GenerationIdentity(question: providerQuestion,
            generationID: identity.generationID, promptPrimaryQuestion: context.promptPrimaryQuestion,
            contextSnapshotID: context.contextSnapshotID)
        guard !isShuttingDown, canPublish(identity),
              providerIdentity.mismatchReason(comparedTo: identity) == nil,
              let service = dependencies.suggestionGenerationService else { return nil }
        let task = Task<String, Error> { [weak self] in
            defer { onExit() }
            try Task.checkCancellation()
            guard self?.canPublish(identity) == true else {
                onRejected(identity)
                throw CancellationError()
            }
            onStarted(identity)
            try Task.checkCancellation()
            guard self?.canPublish(identity) == true else {
                onRejected(identity)
                throw CancellationError()
            }
            let stream = try await service.generateFastSayFirstStream(
                question: providerQuestion, context: providerContext,
                cvSummary: cvSummary, jdSummary: jdSummary,
                customProviderConfig: providerConfiguration
            )
            try Task.checkCancellation()
            guard self?.canPublish(identity) == true else {
                onRejected(identity)
                throw CancellationError()
            }
            var collected = ""
            for try await token in stream {
                guard self?.canPublish(identity) == true else {
                    onRejected(identity)
                    throw CancellationError()
                }
                try Task.checkCancellation()
                collected += token
                guard onToken(identity, token, collected) else {
                    throw CancellationError()
                }
            }
            try Task.checkCancellation()
            guard self?.canPublish(identity) == true else {
                onRejected(identity)
                throw CancellationError()
            }
            guard let completed = onCompleted(identity, collected) else {
                throw CancellationError()
            }
            return completed
        }
        // No await between task creation and registration: its actor-isolated
        // body cannot enter until the exact handle is already authoritative.
        guard registerStageATask(task, generationID: identity.generationID) else { return nil }
        return task
    }

    /// Waits for the already registered first-answer child under the existing
    /// cooperative deadline. Nil means this exact child lost publication authority;
    /// errors for the current child propagate unchanged. Cleanup can retire only
    /// the captured registrations, never a later child/timer of the same identity.
    /// This does not certify resource exit for opaque stream-only providers.
    func awaitStageAFirstAnswer(
        identity: GenerationIdentity,
        timeoutSeconds: TimeInterval,
        delayProvider: any DelayProvider
    ) async throws -> String? {
        try Task.checkCancellation()
        guard !isShuttingDown, canPublish(identity),
              let task = activeGeneration?.stageATask,
              let launchID = activeGeneration?.stageALaunchID else { return nil }
        let timeoutRegistrationID = activeGeneration?.stageATimeoutRegistrationID
        defer {
            if ownsStageALaunch(identity: identity, launchID: launchID) {
                clearStageATask(generationID: identity.generationID)
            }
            if let timeoutRegistrationID, isCurrent(identity),
               activeGeneration?.stageATimeoutRegistrationID == timeoutRegistrationID {
                clearTask(role: .stageATimeout, generationID: identity.generationID)
            }
        }
        do {
            let answer = try await Self.withTimeout(seconds: timeoutSeconds, delayProvider: delayProvider) {
                try await withTaskCancellationHandler { try await task.value }
                    onCancel: { task.cancel() }
            }
            guard ownsStageALaunch(identity: identity, launchID: launchID),
                  canPublish(identity) else { return nil }
            try Task.checkCancellation()
            return answer
        } catch {
            guard ownsStageALaunch(identity: identity, launchID: launchID),
                  canPublish(identity) else { return nil }
            throw error
        }
    }

    /// Owns one frozen Stage B provider workflow, including its exact trigger,
    /// stream parser, empty-stream fallback and task retirement. UI callbacks
    /// keep raw sections separate from the redacted provider result; rejecting a
    /// preview does not reject the provider workflow's eventual complete answer.
    @discardableResult
    func launchStageBExpansion(
        context: GenerationExecutionContext,
        providerQuestion: DetectedQuestion,
        providerContext: RetrievedContext,
        cvSummary: String,
        jdSummary: String,
        providerConfiguration: LLMProviderConfiguration?,
        trigger: StageBTrigger,
        deadlineDelayProvider: any DelayProvider,
        onStarted: @escaping @MainActor (GenerationIdentity) -> Void,
        onReady: @escaping @MainActor (GenerationIdentity) -> Void,
        onSections: @escaping @MainActor (GenerationIdentity, StreamingSuggestionSections, Int) -> Void,
        onFallbackResult: @escaping @MainActor (GenerationIdentity, GenerationProviderResult) -> Bool,
        onCompleted: @escaping @MainActor (GenerationIdentity, GenerationProviderResult, StreamingSuggestionSections, Bool, Int) async throws -> Void,
        onFailure: @escaping @MainActor (GenerationIdentity, Error) -> Void,
        onRejected: @escaping @MainActor (GenerationIdentity) -> Void,
        onPhase: @escaping @MainActor (GenerationIdentity, Int, Bool) -> Void,
        onExit: @escaping @MainActor (GenerationIdentity, Bool) -> Void
    ) -> Task<Void, Never>? {
        let identity = context.identity
        let providerIdentity = GenerationIdentity(question: providerQuestion,
            generationID: identity.generationID, promptPrimaryQuestion: context.promptPrimaryQuestion,
            contextSnapshotID: context.contextSnapshotID)
        guard !isShuttingDown, canPublish(identity),
              providerIdentity.mismatchReason(comparedTo: identity) == nil,
              let service = dependencies.suggestionGenerationService else { return nil }
        let launchID = UUID()
        let task = Task { [weak self] in
            defer {
                let cleared = self?.finishStageBLaunch(identity: identity, launchID: launchID) ?? false
                onExit(identity, cleared)
            }
            guard !Task.isCancelled,
                  self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                  self?.canPublish(identity) == true else { return }
            onStarted(identity)
            await trigger.wait(timeoutMs: 500)
            guard !Task.isCancelled else { return }
            guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                  self?.canPublish(identity) == true else { onRejected(identity); return }
            onPhase(identity, 2, false)
            guard !Task.isCancelled else { return }
            guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                  self?.canPublish(identity) == true else { onRejected(identity); return }
            onReady(identity)
            do {
                try Task.checkCancellation()
                guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                      self?.canPublish(identity) == true else { onRejected(identity); return }
                let streamStartedMS = Self.elapsedMS(since: context.startedAt)
                var parser = StreamingSuggestionSectionParser()
                var sections = StreamingSuggestionSections()
                var sawStreamingSections = false
                onPhase(identity, 3, false)
                try Task.checkCancellation()
                guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                      self?.canPublish(identity) == true else { onRejected(identity); return }
                let stream = try await service.generateFullCardSectionStream(
                    question: providerQuestion, context: providerContext,
                    transcriptContext: context.transcriptSnapshot, sessionID: context.session.id,
                    cvSummary: cvSummary, jdSummary: jdSummary,
                    customProviderConfig: providerConfiguration)
                try Task.checkCancellation()
                guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                      self?.canPublish(identity) == true else { onRejected(identity); return }
                onPhase(identity, 4, false)
                for try await token in stream {
                    try Task.checkCancellation()
                    guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                          self?.canPublish(identity) == true else { onRejected(identity); return }
                    onPhase(identity, 5, true)
                    try Task.checkCancellation()
                    guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                          self?.canPublish(identity) == true else { onRejected(identity); return }
                    sections = parser.append(token)
                    guard sections.hasVisibleContent else { continue }
                    sawStreamingSections = true
                    onSections(identity, sections, streamStartedMS)
                }
                try Task.checkCancellation()
                guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                      self?.canPublish(identity) == true else { onRejected(identity); return }
                onPhase(identity, 6, false)
                if !sawStreamingSections {
                    let fallbackContext = GenerationExecutionContext.make(
                        session: context.session, question: providerQuestion,
                        generationID: identity.generationID, triggerPath: context.triggerPath,
                        provider: providerConfiguration, retrievedContext: providerContext,
                        transcriptSnapshot: context.transcriptSnapshot, cvSummary: cvSummary,
                        jdSummary: jdSummary, startedAt: context.startedAt, source: context.source,
                        speaker: context.speaker, stage: .fullAnswer,
                        interviewContextSnapshot: context.interviewContextSnapshot)
                    let request = GenerationProviderRequest(context: fallbackContext, streamingEnabled: false)
                    onPhase(identity, 7, false)
                    try Task.checkCancellation()
                    guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                          self?.canPublish(identity) == true else { onRejected(identity); return }
                    let result = try await Self.withTimeout(seconds: 15.0, delayProvider: deadlineDelayProvider) { [weak self] in
                        guard let self else { throw CancellationError() }
                        return await self.executeProviderRequest(request,
                            question: providerQuestion, context: providerContext,
                            transcriptContext: context.transcriptSnapshot, sessionID: context.session.id,
                            cvSummary: cvSummary, jdSummary: jdSummary,
                            providerConfiguration: providerConfiguration)
                    }
                    try Task.checkCancellation()
                    guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                          self?.canPublish(identity) == true else { onRejected(identity); return }
                    onPhase(identity, 8, false)
                    try Task.checkCancellation()
                    guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                          self?.canPublish(identity) == true else { onRejected(identity); return }
                    guard onFallbackResult(identity, result) else { return }
                    guard result.providerStatus == .completed else { throw ProviderExecutionFailure(result: result) }
                    // The fallback result has already undergone its existing
                    // provider redaction. Streaming sections remain raw below.
                    sections = result.parsedSections ?? StreamingSuggestionSections(
                        strategy: "Direct Answer", sayFirst: result.sayFirst, keyPoints: result.keyPoints,
                        followUpReady: result.followUp, caution: result.safeDiagnostics["caution"] ?? "")
                }
                try Task.checkCancellation()
                guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                      self?.canPublish(identity) == true else { onRejected(identity); return }
                let result = GenerationProviderResult(identity: identity, sayFirst: sections.sayFirst,
                    keyPoints: sections.keyPoints, followUp: sections.followUpReady, parsedSections: sections,
                    latencyMS: Self.elapsedMS(since: context.startedAt), firstTokenMS: nil, firstVisibleMS: nil,
                    providerStatus: .completed, errorClassification: nil)
                onPhase(identity, 9, false)
                try Task.checkCancellation()
                guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                      self?.canPublish(identity) == true else { onRejected(identity); return }
                try await onCompleted(identity, result, sections, sawStreamingSections, streamStartedMS)
                // Completion may legitimately mark this identity terminal and
                // clear its handle. A different identity never receives phase 10.
                if self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true ||
                    (self?.isCurrent(identity) == true && self?.stageBTask == nil) {
                    onPhase(identity, 10, false)
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                      self?.canPublish(identity) == true else { onRejected(identity); return }
                // The old application clears its handle before reporting an
                // error; preserve that ordering so failure handling does not
                // cancel the very worker executing its synchronous UI callback.
                _ = self?.finishStageBLaunch(identity: identity, launchID: launchID)
                onPhase(identity, 11, false)
                guard !Task.isCancelled, self?.canPublish(identity) == true else { return }
                onFailure(identity, error)
            }
        }
        guard registerStageBLaunch(task, identity: identity, launchID: launchID) else { return nil }
        return task
    }

    /// Creates the Manual routing/RAG/answer workflow in this existing owner.
    /// The operation retains its existing frozen input and UI/DB boundaries.
    @discardableResult
    func launchManualWorkflow(
        identity: GenerationIdentity,
        operation: @escaping @MainActor (GenerationIdentity) async -> Void,
        onExit: @escaping @MainActor (GenerationIdentity, Bool) -> Void
    ) -> Task<Void, Never>? {
        guard !isShuttingDown, canPublish(identity) else { return nil }
        let launchID = UUID()
        let task = Task { [weak self] in
            await ControlTaskExecutionScope.$launchID.withValue(launchID) {
                defer {
                    let cleared = self?.finishStageBLaunch(identity: identity, launchID: launchID) ?? false
                    onExit(identity, cleared)
                }
                guard !Task.isCancelled,
                      self?.ownsStageBLaunch(identity: identity, launchID: launchID) == true,
                      self?.canPublish(identity) == true else { return }
                await operation(identity)
            }
        }
        guard registerStageBLaunch(task, identity: identity, launchID: launchID) else { return nil }
        return task
    }

    /// Only the exact executing Manual launch may clear its workflow role.
    /// External timeout/UI commands continue to use clearTask independently.
    @discardableResult
    func finishManualWorkflow(identity: GenerationIdentity) -> Bool {
        guard let launchID = ControlTaskExecutionScope.launchID else { return false }
        return finishStageBLaunch(identity: identity, launchID: launchID)
    }

    /// Owns the frozen routing child before answer/RAG ExecutionContext exists.
    /// The router retains its exact concrete Ollama producers through exit; this
    /// owner retains that child through cancellation and its actual group join.
    /// Descriptor application, evidence filtering and persistence remain caller
    /// boundaries. No UI object or mutable configuration is read by this worker.
    func routeQuestion(
        identity: GenerationIdentity,
        input: InterviewRoutingInput,
        provider: any LocalLLMProvider,
        model: String
    ) async throws -> InterviewQuestionDecision {
        try Task.checkCancellation()
        guard !isShuttingDown, canPublish(identity),
              identity.acceptedQuestionID == input.questionID,
              identity.questionText == input.question,
              identity.contextSnapshotID == input.contextSnapshotID else { throw CancellationError() }
        let registrationID = UUID()
        let task = Task { [weak self] in
            try Task.checkCancellation()
            guard self?.ownsQuestionRouting(identity: identity, registrationID: registrationID) == true,
                  self?.canPublish(identity) == true else { throw CancellationError() }
            let decision = try await InterviewQuestionRouter.resolve(input, provider: provider, model: model)
            try Task.checkCancellation()
            guard self?.ownsQuestionRouting(identity: identity, registrationID: registrationID) == true,
                  self?.canPublish(identity) == true else { throw CancellationError() }
            return decision
        }
        // Register synchronously before this actor can start the task's body.
        guard registerQuestionRouting(task, identity: identity, registrationID: registrationID) else {
            throw CancellationError()
        }
        defer { finishQuestionRouting(identity: identity, registrationID: registrationID) }
        let decision = try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard ownsQuestionRouting(identity: identity, registrationID: registrationID),
              canPublish(identity),
              recordRoutedQuestion(decision, input: input, identity: identity,
                  registrationID: registrationID) else { throw CancellationError() }
        return decision
    }

    /// Commit the completed route before finishQuestionRouting publishes its
    /// cleared slot. A synchronous subscriber may replace the generation there.
    /// Legacy direct coordinator callers without a question keep their contract;
    /// every App activation supplies the existing complete DetectedQuestion.
    private func recordRoutedQuestion(
        _ decision: InterviewQuestionDecision, input: InterviewRoutingInput,
        identity: GenerationIdentity, registrationID: UUID
    ) -> Bool {
        guard ownsQuestionRouting(identity: identity, registrationID: registrationID),
              canPublish(identity), decision.questionID == input.questionID,
              decision.contextSnapshotID == input.contextSnapshotID,
              decision.questionRevision == input.revision,
              decision.artifactRevision == input.artifactRevision else { return false }
        guard var question = activeGeneration?.questionSnapshot else { return true }
        var descriptor = question.taskDescriptor ?? InterviewTaskDescriptor(question: question.questionText)
        descriptor.question = input.question
        descriptor.apply(decision)
        question.taskDescriptor = descriptor
        beginOwnershipMutation()
        activeGeneration?.questionSnapshot = question
        endOwnershipMutation()
        return ownsQuestionRouting(identity: identity, registrationID: registrationID) && canPublish(identity)
    }

    private func ownsQuestionRouting(identity: GenerationIdentity, registrationID: UUID) -> Bool {
        isCurrent(identity) && activeGeneration?.questionRoutingRegistrationID == registrationID
    }

    private func registerQuestionRouting(
        _ task: Task<InterviewQuestionDecision, Error>,
        identity: GenerationIdentity, registrationID: UUID
    ) -> Bool {
        guard !isShuttingDown, canPublish(identity), var current = activeGeneration else {
            retire(.questionRouting(task), cancel: true)
            return false
        }
        beginOwnershipMutation()
        let previous = current.questionRoutingTask
        current.questionRoutingTask = task
        current.questionRoutingRegistrationID = registrationID
        if var question = current.questionSnapshot, var descriptor = question.taskDescriptor {
            // Starting a fresh route revokes its previous policy while retaining
            // the submitted question/parent metadata in this same owned record.
            descriptor.decision = nil
            question.taskDescriptor = descriptor
            current.questionSnapshot = question
        }
        activeGeneration = current
        if let previous { retire(.questionRouting(previous), cancel: true) }
        endOwnershipMutation()
        return ownsQuestionRouting(identity: identity, registrationID: registrationID) && activeGeneration?.questionRoutingTask == task
    }

    private func finishQuestionRouting(identity: GenerationIdentity, registrationID: UUID) {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        guard ownsQuestionRouting(identity: identity, registrationID: registrationID),
              let task = activeGeneration?.questionRoutingTask else { return }
        activeGeneration?.questionRoutingTask = nil
        activeGeneration?.questionRoutingRegistrationID = nil
        retire(.questionRouting(task), cancel: false)
    }

    /// Owns one RAG operation before the provider ExecutionContext exists.
    /// The caller supplies its frozen retrieval instance, complete identity and
    /// value inputs. Evidence filtering, cache admission and UI/DB checks remain
    /// at their existing boundaries. Awaiting a noncooperative retriever keeps
    /// its actual handle owned; cancellation cannot manufacture resource exit.
    func retrieveContext(
        identity: GenerationIdentity,
        service: any ContextRetrievalService,
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int,
        maxJDWords: Int,
        strategy: AnswerStrategy?
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try Task.checkCancellation()
        guard !isShuttingDown, canPublish(identity),
              identity.questionText == question else { throw CancellationError() }
        let registrationID = UUID()
        let task = Task(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            guard self?.ownsContextRetrieval(identity: identity, registrationID: registrationID) == true,
                  self?.canPublish(identity) == true else { throw CancellationError() }
            // These non-actor-isolated implementations perform SQL/scoring on
            // their generic executor. No detached, unregistered child is needed.
            let result = try await service.retrieveContextWithTrace(question: question,
                intent: intent, maxCVWords: maxCVWords, maxJDWords: maxJDWords, strategy: strategy)
            try Task.checkCancellation()
            guard self?.ownsContextRetrieval(identity: identity, registrationID: registrationID) == true,
                  self?.canPublish(identity) == true else { throw CancellationError() }
            return result
        }
        guard registerContextRetrieval(task, identity: identity, registrationID: registrationID) else {
            throw CancellationError()
        }
        defer { finishContextRetrieval(identity: identity, registrationID: registrationID) }
        let result = try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard ownsContextRetrieval(identity: identity, registrationID: registrationID),
              canPublish(identity) else { throw CancellationError() }
        return result
    }

    private func ownsContextRetrieval(identity: GenerationIdentity, registrationID: UUID) -> Bool {
        isCurrent(identity) && activeGeneration?.contextRetrievalRegistrationID == registrationID
    }

    private func registerContextRetrieval(
        _ task: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>,
        identity: GenerationIdentity, registrationID: UUID
    ) -> Bool {
        guard !isShuttingDown, canPublish(identity), var current = activeGeneration else {
            retire(.contextRetrieval(task), cancel: true)
            return false
        }
        beginOwnershipMutation()
        let previous = current.contextRetrievalTask
        current.contextRetrievalTask = task
        current.contextRetrievalRegistrationID = registrationID
        activeGeneration = current
        if let previous { retire(.contextRetrieval(previous), cancel: true) }
        endOwnershipMutation()
        return ownsContextRetrieval(identity: identity, registrationID: registrationID) && activeGeneration?.contextRetrievalTask == task
    }

    private func finishContextRetrieval(identity: GenerationIdentity, registrationID: UUID) {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        guard ownsContextRetrieval(identity: identity, registrationID: registrationID),
              let task = activeGeneration?.contextRetrievalTask else { return }
        activeGeneration?.contextRetrievalTask = nil
        activeGeneration?.contextRetrievalRegistrationID = nil
        retire(.contextRetrieval(task), cancel: false)
    }

    /// Owns one raw local first-answer operation in the existing Stage A slot.
    /// Existing direct callers keep their raw-text contract. Concrete Ollama
    /// producers remain retained in this owner's sole retirement registry.
    func generateLocalAnswer(
        context: GenerationExecutionContext,
        request: LocalLLMRequest,
        provider: any LocalLLMProvider,
        onToken: @escaping @MainActor (GenerationIdentity, LLMToken) -> Bool
    ) async throws -> String {
        try await runLocalAnswer(context: context, requests: [request], maxAttempts: [1],
            provider: provider, retryDelayProvider: RealDelayProvider(),
            validateAnswer: nil, onToken: onToken, onEvent: { _, _ in true })
    }

    /// The primary attempts, recovery attempts and first-empty retry delay all
    /// share one exact registration. UI/evidence admission and DB persistence
    /// remain with their existing owners; validation receives only frozen values.
    func generateLocalAnswerSequence(
        context: GenerationExecutionContext,
        primaryRequest: LocalLLMRequest,
        compactRecoveryRequest: LocalLLMRequest,
        groundedRecoveryRequest: LocalLLMRequest,
        provider: any LocalLLMProvider,
        retryDelayProvider: any DelayProvider,
        validateAnswer: @escaping @MainActor (String) -> LocalQwenAnswerValidationResult,
        onToken: @escaping @MainActor (GenerationIdentity, LLMToken) -> Bool,
        onEvent: @escaping @MainActor (GenerationIdentity, LocalAnswerEvent) -> Bool
    ) async throws -> String {
        try await runLocalAnswer(context: context,
            requests: [primaryRequest, compactRecoveryRequest, groundedRecoveryRequest],
            maxAttempts: [2, 1, 1], provider: provider,
            retryDelayProvider: retryDelayProvider, validateAnswer: validateAnswer,
            onToken: onToken, onEvent: onEvent)
    }

    private func runLocalAnswer(
        context: GenerationExecutionContext,
        requests: [LocalLLMRequest],
        maxAttempts: [Int],
        provider: any LocalLLMProvider,
        retryDelayProvider: any DelayProvider,
        validateAnswer: (@MainActor (String) -> LocalQwenAnswerValidationResult)?,
        onToken: @escaping @MainActor (GenerationIdentity, LLMToken) -> Bool,
        onEvent: @escaping @MainActor (GenerationIdentity, LocalAnswerEvent) -> Bool
    ) async throws -> String {
        try Task.checkCancellation()
        let identity = context.identity
        guard !isShuttingDown, canPublish(identity),
              context.session.id == identity.sessionID else { throw CancellationError() }
        guard requests.count == maxAttempts.count, !requests.isEmpty,
              requests.allSatisfy({ $0.modelName == context.providerModel }),
              provider.id == context.providerID else {
            throw LLMProviderError.invalidResponse("Local answer provider/model does not match its frozen request.")
        }
        let launchID = UUID()
        let task = Task<String, Error> { [weak self] in
            @MainActor func permitsConsumption() -> Bool {
                !Task.isCancelled &&
                    self?.ownsStageALaunch(identity: identity, launchID: launchID) == true &&
                    self?.canPublish(identity) == true
            }
            @MainActor func observe(_ event: LocalAnswerEvent) throws {
                guard permitsConsumption(), onEvent(identity, event),
                      permitsConsumption() else { throw CancellationError() }
            }
            var lastFailureCategory: OllamaFailureCategory = .providerReturnedNoContent
            var lastFailureDiagnostic = lastFailureCategory.rawValue
            for requestIndex in requests.indices {
                let request = requests[requestIndex]
                for attempt in 1...maxAttempts[requestIndex] {
                    guard permitsConsumption() else { throw CancellationError() }
                    if validateAnswer != nil {
                        try observe(.requestStarted(request, launchID: launchID, requestIndex: requestIndex, attempt: attempt))
                    }
                    // This lexical attempt owns its exact producer through the
                    // same retirement boundary as the former single-attempt API.
                    // No second Task or parallel task registry is introduced.
                    let consume: @MainActor () async throws -> String = { [weak self] in
                        var producerTask: Task<Void, Never>?
                        var streamCompleted = false
                        defer {
                            if let producerTask {
                                if let owner = self {
                                    owner.retire(.localAnswerProducer(producerTask), cancel: !streamCompleted)
                                } else {
                                    producerTask.cancel()
                                }
                            }
                        }
                        let stream: AsyncThrowingStream<LLMToken, Error>
                        if let ollama = provider as? OllamaQwenProvider {
                            let owned = try await ollama.generateOwnedAnswer(request: request)
                            producerTask = owned.producerTask
                            stream = owned.stream
                        } else {
                            // Opaque bare-stream providers retain their existing
                            // contract; a consumer join cannot prove producer exit.
                            stream = try await provider.generateAnswer(request: request)
                        }
                        guard permitsConsumption() else { throw CancellationError() }
                        var collected = ""
                        for try await token in stream {
                            guard permitsConsumption(), onToken(identity, token),
                                  permitsConsumption() else { throw CancellationError() }
                            collected += token.text
                        }
                        guard permitsConsumption() else { throw CancellationError() }
                        streamCompleted = true
                        return collected
                    }
                    let answer: String
                    do {
                        answer = try await consume()
                    } catch {
                        guard permitsConsumption() else { throw CancellationError() }
                        guard validateAnswer != nil else { throw error }
                        let category = OllamaFailureCategory.classify(error)
                        try observe(.requestFailed(category))
                        // Preserve immediate transport failure; this is not an
                        // automatic network retry policy.
                        throw LocalQwenGenerationError(category: category, diagnostic: error.localizedDescription)
                    }
                    guard permitsConsumption() else { throw CancellationError() }
                    guard let validateAnswer else { return answer }
                    try observe(.streamCompleted(answer, launchID: launchID, requestIndex: requestIndex, attempt: attempt))
                    let parsed = LocalQwenAnswerParser.parse(answer, responseSchema: request.responseSchema)
                    try observe(.answerParsed(parsed))
                    if let parserFailure = parsed.failureCategory {
                        lastFailureCategory = parserFailure
                        lastFailureDiagnostic = parsed.sectionParserResult
                    }
                    if !parsed.sayFirst.isEmpty {
                        try observe(.alignmentStarted)
                        let claimValidation = parsed.scopedClaim.map(validateAnswer)
                        guard permitsConsumption() else { throw CancellationError() }
                        let validation: LocalQwenAnswerValidationResult
                        if let claimValidation, !claimValidation.accepted { validation = claimValidation }
                        else { validation = validateAnswer(parsed.sayFirst) }
                        guard permitsConsumption() else { throw CancellationError() }
                        try observe(.alignmentCompleted(validation))
                        guard validation.accepted else {
                            lastFailureCategory = validation.failureCategory ?? .alignmentRejectedNonemptyContent
                            lastFailureDiagnostic = validation.diagnostic
                            try observe(.retrying(.alignmentRejected))
                            // Nonempty misalignment never sleeps, including the
                            // first primary attempt.
                            continue
                        }
                        return parsed.sayFirst
                    }
                    if attempt < maxAttempts[requestIndex] {
                        try observe(.retrying(.emptyPrimary))
                        try await retryDelayProvider.sleep(nanoseconds: 150_000_000)
                        guard permitsConsumption() else { throw CancellationError() }
                    }
                }
                if requestIndex == 0 {
                    try observe(.retrying(.compactRecovery))
                } else if requestIndex == 1 {
                    try observe(.retrying(.groundedRecovery))
                }
            }
            try observe(.exhausted(lastFailureCategory))
            throw LocalQwenGenerationError(category: lastFailureCategory, diagnostic: lastFailureDiagnostic)
        }
        // The entire sequence is registered before the task can enter this actor.
        guard registerStageATask(task, generationID: identity.generationID, launchID: launchID) else {
            throw CancellationError()
        }
        defer { finishLocalStageA(identity: identity, launchID: launchID) }
        let answer = try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard ownsStageALaunch(identity: identity, launchID: launchID),
              canPublish(identity) else { throw CancellationError() }
        return answer
    }

    private func ownsStageALaunch(identity: GenerationIdentity, launchID: UUID) -> Bool {
        isCurrent(identity) && activeGeneration?.stageALaunchID == launchID
    }

    private func finishLocalStageA(identity: GenerationIdentity, launchID: UUID) {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        guard ownsStageALaunch(identity: identity, launchID: launchID),
              let task = activeGeneration?.stageATask else { return }
        activeGeneration?.stageATask = nil
        activeGeneration?.stageALaunchID = nil
        retire(.answer(task), cancel: false)
    }

    /// Owns only the real Manual JSON request. App-side routing, evidence checks,
    /// publication and persistence stay at their existing boundaries. The separate
    /// child is necessary: the retained Manual worker waits for this provider.
    func generateManualSuggestion(
        context: GenerationExecutionContext,
        providerConfiguration: LLMProviderConfiguration?,
        timeoutInterval: TimeInterval?
    ) async throws -> (card: SuggestionCard, response: LLMChatResult) {
        try Task.checkCancellation()
        let identity = context.identity
        guard !isShuttingDown, canPublish(identity) else { throw CancellationError() }
        guard let service = dependencies.suggestionGenerationService else {
            throw LLMProviderError.notConfigured("Suggestion generation service")
        }
        // A missing submission snapshot is a failure, never permission to
        // resolve a different global configuration after routing or retrieval.
        guard let providerConfiguration else {
            throw LLMProviderError.notConfigured("Manual answer provider at submission")
        }
        let registrationID = UUID()
        let task = Task { [weak self] in
            try Task.checkCancellation()
            guard self?.ownsManualProvider(identity: identity, registrationID: registrationID) == true,
                  self?.canPublish(identity) == true else { throw CancellationError() }
            let output = try await service.generate(
                question: context.question, context: context.retrievedContext,
                transcriptContext: context.transcriptSnapshot, sessionID: context.session.id,
                timeoutInterval: timeoutInterval, customProviderConfig: providerConfiguration,
                interviewContextSnapshot: context.interviewContextSnapshot)
            try Task.checkCancellation()
            guard self?.ownsManualProvider(identity: identity, registrationID: registrationID) == true,
                  self?.canPublish(identity) == true else { throw CancellationError() }
            return output
        }
        guard registerManualProvider(task, identity: identity, registrationID: registrationID) else {
            throw CancellationError()
        }
        defer { finishManualProvider(identity: identity, registrationID: registrationID) }
        let output = try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard ownsManualProvider(identity: identity, registrationID: registrationID),
              canPublish(identity) else { throw CancellationError() }
        return output
    }

    private func ownsManualProvider(identity: GenerationIdentity, registrationID: UUID) -> Bool {
        isCurrent(identity) && activeGeneration?.manualProviderRegistrationID == registrationID
    }

    private func registerManualProvider(
        _ task: Task<(card: SuggestionCard, response: LLMChatResult), Error>,
        identity: GenerationIdentity, registrationID: UUID
    ) -> Bool {
        guard !isShuttingDown, canPublish(identity), var current = activeGeneration else {
            retire(.manualProvider(task), cancel: true)
            return false
        }
        beginOwnershipMutation()
        let previous = current.manualProviderTask
        current.manualProviderTask = task
        current.manualProviderRegistrationID = registrationID
        activeGeneration = current
        if let previous { retire(.manualProvider(previous), cancel: true) }
        endOwnershipMutation()
        return ownsManualProvider(identity: identity, registrationID: registrationID) && activeGeneration?.manualProviderTask == task
    }

    /// A cancelled old caller cannot clear a later child of the same generation.
    /// This method transfers the exact handle; it never joins its calling task.
    private func finishManualProvider(identity: GenerationIdentity, registrationID: UUID) {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        guard ownsManualProvider(identity: identity, registrationID: registrationID),
              let task = activeGeneration?.manualProviderTask else { return }
        activeGeneration?.manualProviderTask = nil
        activeGeneration?.manualProviderRegistrationID = nil
        retire(.manualProvider(task), cancel: false)
    }

    private func ownsStageBLaunch(identity: GenerationIdentity, launchID: UUID) -> Bool {
        isCurrent(identity) && activeGeneration?.stageBLaunchID == launchID
    }

    private func registerStageBLaunch(_ task: Task<Void, Never>, identity: GenerationIdentity, launchID: UUID) -> Bool {
        guard !isShuttingDown, canPublish(identity), var current = activeGeneration else {
            retire(.control(task), cancel: true, controlLaunchID: launchID)
            return false
        }
        beginOwnershipMutation()
        let previous = current.stageBTask
        let previousLaunchID = current.stageBLaunchID
        current.stageBTask = task
        current.stageBLaunchID = launchID
        activeGeneration = current
        if let previous { retire(.control(previous), cancel: true, controlLaunchID: previousLaunchID) }
        endOwnershipMutation()
        return ownsStageBLaunch(identity: identity, launchID: launchID) && activeGeneration?.stageBTask == task
    }

    /// Called from this worker's defer: transfer its exact handle to retirement,
    /// without awaiting itself or clearing another registration of the same role.
    @discardableResult
    private func finishStageBLaunch(identity: GenerationIdentity, launchID: UUID) -> Bool {
        guard ownsStageBLaunch(identity: identity, launchID: launchID) else { return false }
        clearTask(role: .stageB, generationID: identity.generationID, cancel: false)
        return isCurrent(identity) && activeGeneration?.stageBTask == nil
    }

    /// Synchronous terminal application uses this existing immutable record as
    /// its receipt. Identity alone cannot distinguish a same-ID role replacement.
    /// Terminal commit may only remove its captured fallback/queued timers; it
    /// cannot grant authority over a newly registered provider or deadline.
    func ownsProviderTaskSnapshot(_ captured: ActiveGeneration, requestID: String?) -> Bool {
        guard !isShuttingDown, isCurrent(captured.identity), activeRequest?.id == requestID,
              let current = activeGeneration else { return false }
        let terminal = terminalGenerationIDs.contains(captured.generationID)
        return current.stageATask == captured.stageATask && current.stageALaunchID == captured.stageALaunchID &&
            current.stageATimeoutTask == captured.stageATimeoutTask &&
            current.stageATimeoutRegistrationID == captured.stageATimeoutRegistrationID &&
            current.stageBTask == captured.stageBTask && current.stageBLaunchID == captured.stageBLaunchID &&
            current.manualProviderTask == captured.manualProviderTask &&
            current.manualProviderRegistrationID == captured.manualProviderRegistrationID &&
            current.fullCardWatchdogTask == captured.fullCardWatchdogTask &&
            (current.fallbackWatchdogTask == captured.fallbackWatchdogTask ||
                (terminal && current.fallbackWatchdogTask == nil)) &&
            (current.queuedQuestionHandoffTask == captured.queuedQuestionHandoffTask ||
                (terminal && current.queuedQuestionHandoffTask == nil)) &&
            current.queuedQuestionHandoffRegistrationID == captured.queuedQuestionHandoffRegistrationID
    }

    /// Retire only the captured provider roles in one committed mutation, keeping
    /// every handle in the existing retirement registry through its actual exit.
    /// The caller receives no authority if the committed publication starts a
    /// new request or replaces a role, even under the same generation identity.
    func retireFinishedProviderTasks(
        captured: ActiveGeneration, requestID: String?, cancelExpansion: Bool, retireFirstAnswer: Bool = true
    ) -> ActiveGeneration? {
        guard ownsProviderTaskSnapshot(captured, requestID: requestID) else { return nil }
        var expected = captured
        beginOwnershipMutation()
        if retireFirstAnswer {
            clearStageATask(generationID: captured.generationID)
            expected.stageATask = nil
            expected.stageALaunchID = nil
        }
        clearTask(role: .stageATimeout, generationID: captured.generationID)
        expected.stageATimeoutTask = nil
        expected.stageATimeoutRegistrationID = nil
        clearTask(role: .fullCardWatchdog, generationID: captured.generationID)
        expected.fullCardWatchdogTask = nil
        clearTask(role: .stageB, generationID: captured.generationID, cancel: cancelExpansion)
        expected.stageBTask = nil
        expected.stageBLaunchID = nil
        if cancelExpansion {
            expected.manualProviderTask = nil
            expected.manualProviderRegistrationID = nil
        }
        endOwnershipMutation()
        return ownsProviderTaskSnapshot(expected, requestID: requestID) ? expected : nil
    }

    func clearStageATask(generationID: String) {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        guard isCurrent(generationID) else { return }
        let previous = activeGeneration?.stageATask
        activeGeneration?.stageATask = nil
        activeGeneration?.stageALaunchID = nil
        if let previous { retire(.answer(previous), cancel: true) }
    }

    @discardableResult
    func registerTask(_ task: Task<Void, Never>, role: TaskRole, generationID: String, registrationID: UUID? = nil) -> Bool {
        guard isCurrent(generationID), !terminalGenerationIDs.contains(generationID) else {
            retire(.control(task), cancel: true)
            return false
        }
        beginOwnershipMutation()
        let previous = taskForRole(role)
        let previousLaunchID = role == .stageB ? activeGeneration?.stageBLaunchID : nil
        setTask(task, role: role, registrationID: registrationID)
        if let previous { retire(.control(previous), cancel: true, controlLaunchID: previousLaunchID) }
        endOwnershipMutation()
        return isCurrent(generationID) && taskForRole(role) == task &&
            (role != .queuedQuestionHandoff || registrationID == nil ||
                activeGeneration?.queuedQuestionHandoffRegistrationID == registrationID)
    }

    /// Owns the queued-question timer through cancellation and actual exit.
    /// Queue contents and the supersession decision remain application policy.
    @discardableResult
    func launchQueuedQuestionHandoff(
        identity: GenerationIdentity,
        nanoseconds: UInt64,
        delayProvider: any DelayProvider,
        onHandoff: @escaping @MainActor (GenerationIdentity) -> Void
    ) -> Task<Void, Never>? {
        guard !isShuttingDown, canPublish(identity) else { return nil }
        let registrationID = UUID()
        let task = Task { [weak self] in
            defer { self?.finishQueuedQuestionHandoff(identity: identity, registrationID: registrationID) }
            do {
                try await delayProvider.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
            } catch { return }
            guard let self, self.canPublish(identity),
                  self.activeGeneration?.queuedQuestionHandoffRegistrationID == registrationID else { return }
            // Publish retirement before the application may submit Q2. A
            // synchronous subscriber's later timer registration wins instead.
            self.finishQueuedQuestionHandoff(identity: identity, registrationID: registrationID)
            guard !Task.isCancelled, self.canPublish(identity),
                  self.activeGeneration?.queuedQuestionHandoffRegistrationID == registrationID,
                  self.queuedQuestionHandoffTask == nil else { return }
            onHandoff(identity)
        }
        guard registerTask(task, role: .queuedQuestionHandoff,
            generationID: identity.generationID, registrationID: registrationID) else { return nil }
        return task
    }

    private func finishQueuedQuestionHandoff(identity: GenerationIdentity, registrationID: UUID) {
        guard isCurrent(identity), activeGeneration?.queuedQuestionHandoffTask != nil,
              activeGeneration?.queuedQuestionHandoffRegistrationID == registrationID else { return }
        clearTask(role: .queuedQuestionHandoff, generationID: identity.generationID, cancel: false)
    }

    /// Applies the remote stream's exit presentation and retires only the
    /// fallback timer captured before that synchronous callback can reenter.
    @discardableResult
    func applyStageAStreamExit(
        identity: GenerationIdentity,
        onExit: @MainActor (GenerationIdentity) -> Bool
    ) -> Bool {
        guard !isShuttingDown, !Task.isCancelled, canPublish(identity) else { return false }
        let watchdog = fallbackWatchdogTask
        guard onExit(identity), !Task.isCancelled, canPublish(identity) else { return false }
        return retireFirstAnswerFallbackWatchdog(identity: identity, capturedTask: watchdog)
    }

    /// Selects the immediate first-answer fallback for this frozen generation.
    /// UI/evidence application stays at the caller's synchronous boundary.
    /// Legacy activations without a provider snapshot supply only the enum;
    /// the owned snapshot takes precedence whenever it exists.
    @discardableResult
    func applyImmediateFirstAnswerFallback(
        identity: GenerationIdentity,
        providerModeIfUnspecified: AnswerProviderMode,
        presentation: @MainActor @Sendable (GenerationIdentity)
            -> (isLoadingWithoutVisibleAnswer: Bool, hasVisibleAnswer: Bool)?,
        onFallback: @MainActor @Sendable
            (GenerationIdentity, Int, @MainActor @Sendable () -> Bool) -> Bool
    ) -> Bool {
        guard !isShuttingDown, !Task.isCancelled, canPublish(identity),
              let generation = activeGeneration,
              (generation.answerProviderMode ?? providerModeIfUnspecified) != .localQwenPrimary,
              let submitted = presentation(identity),
              !Task.isCancelled, canPublish(identity),
              submitted.isLoadingWithoutVisibleAnswer, !submitted.hasVisibleAnswer else { return false }
        let watchdog = fallbackWatchdogTask
        let applied = onFallback(identity, Self.elapsedMS(since: generation.startedAt)) { [weak self] in
            self?.retireFirstAnswerFallbackWatchdog(identity: identity, capturedTask: watchdog) == true
        }
        return applied && !Task.isCancelled && canPublish(identity)
    }

    /// The application can retire only the exact role captured before its
    /// synchronous publication. A subscriber's later task always wins.
    private func retireFirstAnswerFallbackWatchdog(
        identity: GenerationIdentity, capturedTask: Task<Void, Never>?
    ) -> Bool {
        guard !isShuttingDown, !Task.isCancelled, canPublish(identity),
              fallbackWatchdogTask == capturedTask else { return false }
        clearTask(role: .fallbackWatchdog, generationID: identity.generationID)
        return !Task.isCancelled && canPublish(identity) && fallbackWatchdogTask == nil
    }

    /// The remote first-answer policy belongs to the generation owner. The
    /// projection is synchronous and contains only the admitted UI values.
    @discardableResult
    func launchInitialFirstAnswerFallbackDeadline(
        identity: GenerationIdentity,
        startedAt: Date,
        delayProvider: any DelayProvider,
        presentation: @escaping @MainActor @Sendable (GenerationIdentity)
            -> (visibleCard: SuggestionCard?, firstVisibleTextAt: Date?)?,
        onFallback: @escaping @MainActor @Sendable (GenerationIdentity, Int) -> Void
    ) -> Task<Void, Never>? {
        guard !isShuttingDown, canPublish(identity),
              activeGeneration?.answerProviderMode != .localQwenPrimary else { return nil }
        return launchDeadline(identity: identity, role: .fallbackWatchdog,
            nanoseconds: 1_500_000_000, delayProvider: delayProvider
        ) { [weak self] identity, _ in
            guard let self, !Task.isCancelled, self.canPublish(identity),
                  let submitted = presentation(identity),
                  !Task.isCancelled, self.canPublish(identity),
                  submitted.visibleCard == nil, submitted.firstVisibleTextAt == nil else { return }
            onFallback(identity, Self.elapsedMS(since: startedAt))
        }
    }

    /// RAG keeps its existing profile-context rule and does not require an empty
    /// card slot. It replaces the initial timer through the same retained role.
    @discardableResult
    func launchRAGFirstAnswerFallbackDeadline(
        context: GenerationExecutionContext,
        delayProvider: any DelayProvider,
        presentation: @escaping @MainActor @Sendable (GenerationIdentity)
            -> (visibleCard: SuggestionCard?, firstVisibleTextAt: Date?)?,
        onFallback: @escaping @MainActor @Sendable (GenerationIdentity, Int) -> Void
    ) -> Task<Void, Never>? {
        let identity = context.identity
        guard !isShuttingDown, canPublish(identity),
              activeGeneration?.answerProviderMode != .localQwenPrimary else { return nil }
        // Keep the old registration/cancellation contract even for general
        // tasks: their registered timer exits without publishing a profile card.
        let allowsProfileFallback = PromptContextBuilder.usesProfileContext(
            context.promptSnapshot.taskDescriptor ?? InterviewTaskDescriptor(question: context.question.questionText)
        )
        return launchDeadline(identity: identity, role: .fallbackWatchdog,
            nanoseconds: 1_500_000_000, delayProvider: delayProvider
        ) { [weak self] identity, _ in
            guard let self, !Task.isCancelled, self.canPublish(identity),
                  let submitted = presentation(identity),
                  !Task.isCancelled, self.canPublish(identity),
                  allowsProfileFallback, submitted.firstVisibleTextAt == nil else { return }
            onFallback(identity, Self.elapsedMS(since: context.startedAt))
        }
    }

    /// Manual keeps its original timer registration even for local-primary
    /// requests, but only a frozen configured-provider mode and completed route
    /// can select a template. No view or application container is retained.
    @discardableResult
    func launchManualFirstAnswerFallbackDeadline(
        identity: GenerationIdentity,
        forceDeepSeek: Bool,
        startedAt: Date,
        delayProvider: any DelayProvider,
        hasManualCard: @escaping @MainActor @Sendable (GenerationIdentity) -> Bool?,
        onFallback: @escaping @MainActor @Sendable (GenerationIdentity, DetectedQuestion, Int) -> Void
    ) -> Task<Void, Never>? {
        guard !isShuttingDown, canPublish(identity), let generation = activeGeneration else { return nil }
        let allowsTemplate = generation.answerProviderMode != .localQwenPrimary || forceDeepSeek
        return launchDeadline(identity: identity, role: .fallbackWatchdog,
            nanoseconds: 1_500_000_000, delayProvider: delayProvider
        ) { [weak self] identity, _ in
            guard let self, !Task.isCancelled, self.canPublish(identity),
                  let hasManualCard = hasManualCard(identity),
                  !Task.isCancelled, self.canPublish(identity),
                  !hasManualCard, allowsTemplate,
                  let question = self.activeGeneration?.questionSnapshot,
                  question.id == identity.acceptedQuestionID,
                  question.sessionID == identity.sessionID,
                  question.questionText == identity.questionText,
                  question.taskDescriptor?.decision != nil else { return }
            onFallback(identity, question, Self.elapsedMS(since: startedAt))
        }
    }

    /// Manual's existing full-card deadline branches use the frozen provider
    /// mode and routed question already retained by this owner. Presentation
    /// supplies only card presence; the application still validates and applies
    /// the selected plan, and commits its own terminal UI/consent boundary.
    @discardableResult
    func launchManualFullCardDeadline(
        identity: GenerationIdentity,
        forceDeepSeek: Bool,
        startedAt: Date,
        nanoseconds: UInt64,
        delayProvider: any DelayProvider,
        presentation: @escaping @MainActor @Sendable (GenerationIdentity)
            -> (manualCard: SuggestionCard?, visibleCard: SuggestionCard?)?,
        onTimeout: @escaping @MainActor @Sendable (StageBApplicationPlan, DetectedQuestion?) -> Void
    ) -> Task<Void, Never>? {
        guard !isShuttingDown, canPublish(identity), let generation = activeGeneration else { return nil }
        let localPrimary = generation.answerProviderMode == .localQwenPrimary && !forceDeepSeek
        return launchDeadline(identity: identity, role: .fullCardWatchdog,
            nanoseconds: nanoseconds, delayProvider: delayProvider
        ) { [weak self] identity, _ in
            guard let self, !Task.isCancelled, self.canPublish(identity) else { return }
            let stageB = self.stageBTask
            let stageBLaunch = self.activeGeneration?.stageBLaunchID
            guard let submitted = presentation(identity), !Task.isCancelled, self.canPublish(identity),
                  self.retireCapturedStageB(identity: identity, task: stageB, launchID: stageBLaunch),
                  !Task.isCancelled, self.canPublish(identity) else { return }
            let routed = self.activeGeneration?.questionSnapshot.flatMap { question in
                question.id == identity.acceptedQuestionID && question.sessionID == identity.sessionID &&
                    question.questionText == identity.questionText && question.taskDescriptor?.decision != nil
                    ? question : nil
            }
            let action: StageBApplicationAction
            let reason: String
            if routed == nil {
                action = .markProviderFailed
                reason = "Manual question classification did not complete."
            } else if localPrimary {
                action = .markProviderFailed
                reason = "Local manual answer timed out."
            } else if submitted.manualCard != nil || submitted.visibleCard != nil {
                action = .keepVisibleFirstAnswer
                reason = "Manual capture full answer timed out."
            } else {
                action = .useSemanticFallback
                reason = "No visible manual answer within 8 seconds."
            }
            let plan = StageBApplicationPlan(generationID: identity.generationID,
                detectedQuestionID: identity.acceptedQuestionID, action: action, fallbackReason: reason,
                shouldPersist: false, shouldUpdateVisibleCard: action == .useSemanticFallback,
                safeDiagnostics: ["applicationPlanSource": "GenerationCoordinator",
                    "stageBClassification": StageBResultClassification.timedOut.rawValue,
                    "elapsedMS": String(Self.elapsedMS(since: startedAt))], identity: identity)
            guard !Task.isCancelled, self.canPublish(identity) else { return }
            onTimeout(plan, routed)
        }
    }

    /// Owns configured-provider failure selection and exact expansion retirement.
    /// The application supplies frozen local-answer execution and guarded UI;
    /// that execution reuses generateLocalAnswerSequence's existing attempts.
    /// True means recovered or obsolete; false preserves the caller's current
    /// expansion/preserved-first-answer/failure policy.
    func recoverConfiguredProviderBeforeFirstToken(
        context: GenerationExecutionContext,
        expectedExpansion: Task<Void, Never>,
        firstTokenObserved: @escaping @MainActor (GenerationIdentity) -> Bool?,
        onStarted: @escaping @MainActor (GenerationIdentity) -> Bool,
        recover: @escaping @MainActor (GenerationIdentity) async throws -> Bool,
        onRecovered: @escaping @MainActor (GenerationIdentity) -> Void,
        onFailure: @escaping @MainActor (GenerationIdentity, Error) -> Void
    ) async -> Bool {
        let identity = context.identity
        guard !isShuttingDown, !Task.isCancelled, canPublish(identity) else { return true }
        guard activeGeneration?.answerProviderMode == .deepSeekWithLocalQwenFallback else { return false }
        // The original expansion is frozen at creation, before any Stage A
        // exit/operation publication. Nil means it already exited normally.
        guard stageATask == nil, stageBTask == nil || stageBTask == expectedExpansion else { return true }
        let firstAnswer = stageATask
        let firstAnswerLaunch = activeGeneration?.stageALaunchID
        let expansion = stageBTask
        let expansionLaunch = activeGeneration?.stageBLaunchID
        @MainActor func stillOwnsSelection() -> Bool {
            !isShuttingDown && !Task.isCancelled && canPublish(identity) &&
                stageATask == firstAnswer && activeGeneration?.stageALaunchID == firstAnswerLaunch &&
                stageBTask == expansion && activeGeneration?.stageBLaunchID == expansionLaunch
        }
        guard let sawToken = firstTokenObserved(identity), stillOwnsSelection() else { return true }
        guard !sawToken else { return false }
        guard onStarted(identity), stillOwnsSelection() else { return true }
        guard retireCapturedStageB(identity: identity, task: expansion, launchID: expansionLaunch),
              !Task.isCancelled, canPublish(identity),
              stageATask == firstAnswer, activeGeneration?.stageALaunchID == firstAnswerLaunch else { return true }
        do {
            let finished = try await recover(identity)
            guard !isShuttingDown, !Task.isCancelled, isCurrent(identity),
                  stageATask == nil, stageBTask == nil else { return true }
            if finished {
                // Legal local completion is terminal. Do not reject its final
                // feedback by asking canPublish after the business commit.
                onRecovered(identity)
                return true
            }
            return !canPublish(identity)
        } catch {
            guard !isShuttingDown, !Task.isCancelled, canPublish(identity),
                  stageATask == nil, stageBTask == nil else { return true }
            onFailure(identity, error)
            return !canPublish(identity) || Task.isCancelled || isShuttingDown || stageATask != nil || stageBTask != nil
        }
    }

    /// Only the handle captured before a synchronous publication can be retired.
    /// The existing retirement registry retains the cancelled worker/child
    /// through their actual exits, without joining this deadline or UI actor.
    private func retireCapturedStageB(
        identity: GenerationIdentity, task: Task<Void, Never>?, launchID: UUID?
    ) -> Bool {
        guard !isShuttingDown, !Task.isCancelled, canPublish(identity),
              stageBTask == task, activeGeneration?.stageBLaunchID == launchID else { return false }
        clearTask(role: .stageB, generationID: identity.generationID)
        return !Task.isCancelled && canPublish(identity) && stageBTask == nil
    }

    /// Selects the full-answer deadline outcome in the same owner that creates,
    /// cancels and retains its timer. The synchronous projection supplies only
    /// current presentation values under this exact identity; application keeps
    /// evidence/consent admission and its existing terminal publication order.
    @discardableResult
    func launchFullCardDeadline(
        identity: GenerationIdentity,
        startedAt: Date,
        nanoseconds: UInt64,
        delayProvider: any DelayProvider,
        presentation: @escaping @MainActor @Sendable (GenerationIdentity)
            -> (visibleCard: SuggestionCard?, streamedSayFirst: String)?,
        onTimeout: @escaping @MainActor @Sendable
            (StageBApplicationPlan, SuggestionCard?, String, Int) -> Void
    ) -> Task<Void, Never>? {
        let localPrimary = activeGeneration?.answerProviderMode == .localQwenPrimary
        return launchDeadline(identity: identity, role: .fullCardWatchdog,
            nanoseconds: nanoseconds, delayProvider: delayProvider, priority: .userInitiated
        ) { [weak self] identity, _ in
            guard let self, !Task.isCancelled, self.canPublish(identity),
                  let submitted = presentation(identity),
                  !Task.isCancelled, self.canPublish(identity) else { return }
            // Preserve the current policy: a nonempty visible card takes
            // precedence over uncommitted stream text, then local fallback.
            let visibleCard = submitted.visibleCard.flatMap { card in
                card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : card
            }
            let streamed = submitted.streamedSayFirst.trimmingCharacters(in: .whitespacesAndNewlines)
            let action: StageBApplicationAction = localPrimary ? .markProviderFailed
                : (visibleCard != nil || !streamed.isEmpty ? .keepVisibleFirstAnswer : .useSemanticFallback)
            let plan = StageBApplicationPlan(generationID: identity.generationID,
                detectedQuestionID: identity.acceptedQuestionID, action: action,
                fallbackReason: "full-card watchdog timeout", shouldPersist: !localPrimary,
                shouldUpdateVisibleCard: !localPrimary,
                safeDiagnostics: ["applicationPlanSource": "GenerationCoordinator",
                    "stageBClassification": StageBResultClassification.timedOut.rawValue],
                identity: identity)
            guard !Task.isCancelled, self.canPublish(identity) else { return }
            // Do not mark terminal before this boundary: it first admits any
            // validated Q1 history, then commits through this owner's existing
            // markTerminal at the real UI terminal-publication point. A Q2
            // subscriber may reenter there and must remain authoritative.
            let routing = localPrimary ? self.activeGeneration?.questionRoutingTask : nil
            let retrieval = localPrimary ? self.activeGeneration?.contextRetrievalTask : nil
            onTimeout(plan, visibleCard, streamed, Self.elapsedMS(since: startedAt))
            routing?.cancel()
            retrieval?.cancel()
        }
    }

    /// Creates and registers one deadline before its callback can enter this
    /// actor. The clock and complete identity stay frozen for this operation.
    /// A clock that ignores cancellation may finish later, but cannot publish.
    @discardableResult
    func launchDeadline(
        identity: GenerationIdentity,
        role: TaskRole,
        nanoseconds: UInt64,
        delayProvider: any DelayProvider,
        priority: TaskPriority? = nil,
        onDeadline: @escaping @MainActor @Sendable (GenerationIdentity, TaskRole) -> Void
    ) -> Task<Void, Never>? {
        guard !isShuttingDown, canPublish(identity) else { return nil }
        let task = Task.detached(priority: priority ?? Task.currentPriority) { [weak self] in
            do {
                try await delayProvider.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
            } catch { return }
            await self?.publishDeadline(identity: identity, role: role, onDeadline: onDeadline)
        }
        guard registerTask(task, role: role, generationID: identity.generationID) else { return nil }
        return task
    }

    private func publishDeadline(
        identity: GenerationIdentity,
        role: TaskRole,
        onDeadline: @MainActor @Sendable (GenerationIdentity, TaskRole) -> Void
    ) {
        guard !Task.isCancelled, !isShuttingDown, canPublish(identity) else { return }
        onDeadline(identity, role)
    }

    func clearTask(role: TaskRole, generationID: String, cancel: Bool = true) {
        beginOwnershipMutation()
        defer { endOwnershipMutation() }
        guard isCurrent(generationID) else { return }
        let previous = taskForRole(role)
        let previousLaunchID = role == .stageB ? activeGeneration?.stageBLaunchID : nil
        setTask(nil, role: role)
        if let previous { retire(.control(previous), cancel: cancel, controlLaunchID: previousLaunchID) }
        if cancel, case .stageB = role, let child = activeGeneration?.manualProviderTask {
            activeGeneration?.manualProviderTask = nil
            activeGeneration?.manualProviderRegistrationID = nil
            retire(.manualProvider(child), cancel: cancel)
        }
    }

    private func taskForRole(_ role: TaskRole) -> Task<Void, Never>? {
        switch role {
        case .stageATimeout: return activeGeneration?.stageATimeoutTask
        case .stageB: return activeGeneration?.stageBTask
        case .fallbackWatchdog: return activeGeneration?.fallbackWatchdogTask
        case .fullCardWatchdog: return activeGeneration?.fullCardWatchdogTask
        case .queuedQuestionHandoff: return activeGeneration?.queuedQuestionHandoffTask
        }
    }

    private func setTask(_ task: Task<Void, Never>?, role: TaskRole, registrationID: UUID? = nil) {
        switch role {
        case .stageATimeout:
            activeGeneration?.stageATimeoutTask = task
            activeGeneration?.stageATimeoutRegistrationID = task == nil ? nil : UUID()
        case .stageB:
            activeGeneration?.stageBTask = task
            activeGeneration?.stageBLaunchID = nil
        case .fallbackWatchdog: activeGeneration?.fallbackWatchdogTask = task
        case .fullCardWatchdog: activeGeneration?.fullCardWatchdogTask = task
        case .queuedQuestionHandoff:
            activeGeneration?.queuedQuestionHandoffTask = task
            // Retain the last exact receipt through completion publication.
            // Reactivation resets it, and a new timer replaces it. This is no
            // active task or second registry; it prevents same-identity reentry.
            if task != nil { activeGeneration?.queuedQuestionHandoffRegistrationID = registrationID ?? UUID() }
        }
    }

    private func retireGeneration(_ generation: ActiveGeneration?, cancel: Bool) {
        guard let generation else { return }
        if let task = generation.questionRoutingTask { retire(.questionRouting(task), cancel: cancel) }
        if let task = generation.contextRetrievalTask { retire(.contextRetrieval(task), cancel: cancel) }
        if let task = generation.stageATask { retire(.answer(task), cancel: cancel) }
        if let task = generation.manualProviderTask { retire(.manualProvider(task), cancel: cancel) }
        if let task = generation.stageATimeoutTask { retire(.control(task), cancel: cancel) }
        if let task = generation.stageBTask {
            retire(.control(task), cancel: cancel, controlLaunchID: generation.stageBLaunchID)
        }
        for task in [generation.fallbackWatchdogTask, generation.fullCardWatchdogTask, generation.queuedQuestionHandoffTask].compactMap({ $0 }) {
            retire(.control(task), cancel: cancel)
        }
    }

    /// Retains an admitted save through its actual completion. This grants no
    /// publication authority; completed history survives a newer UI request.
    func retainAdmittedPersistenceUntilExit(_ task: Task<Void, Never>) {
        retire(.control(task), cancel: false)
    }

    private func retire(_ work: OwnedTask, cancel: Bool, controlLaunchID: UUID? = nil) {
        if cancel { work.cancel() }
        let id = UUID()
        // Retain the work until its real exit; weak self is promoted only after
        // await, so the observer does not itself keep the owner alive forever.
        let join = Task { @MainActor [weak self] in
            await work.awaitExit()
            guard let self else { return }
            self.retiringTasks.removeValue(forKey: id)
            self.ownershipChanged()
            if self.retiringTasks.isEmpty {
                self.drainWaiters.values.forEach { $0.yield(()) }
            }
        }
        retiringTasks[id] = RetiringTask(work: work, join: join, controlLaunchID: controlLaunchID)
        ownershipChanged()
    }

    /// External lifecycle callers only. Normal root completion transfers its
    /// handle with finishRequest instead of waiting on itself. Cancellation of
    /// this wait removes its observer; it cannot force a noncooperative task out.
    func drainRetiredTasks() async {
        guard canDrainFromCurrentTask, !retiringTasks.isEmpty, !Task.isCancelled else { return }
        let id = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        drainWaiters[id] = continuation
        defer {
            drainWaiters.removeValue(forKey: id)
            continuation.finish()
        }
        for await _ in events {
            if retiringTasks.isEmpty { return }
        }
    }

    func closeAdmission() {
        isShuttingDown = true
        invalidateAndCancel()
    }

    /// The deadline bounds the cooperative observer, not Task.value on work
    /// that ignores cancellation. False leaves unfinished handles owned and
    /// visible in pendingCleanupTaskCount, allowing later cleanup to be joined.
    func shutdownAndDrain(
        timeout: TimeInterval = 5,
        delayProvider: DelayProvider = RealDelayProvider()
    ) async -> Bool {
        guard canDrainFromCurrentTask else { return false }
        closeAdmission()
        guard !retiringTasks.isEmpty else { return true }
        do {
            try await Self.withTimeout(seconds: timeout, delayProvider: delayProvider) { @MainActor in
                await self.drainRetiredTasks()
            }
            return retiringTasks.isEmpty
        } catch {
            return false
        }
    }

    deinit {
        activeRequest?.task?.cancel()
        activeGeneration?.cancelAll()
        for task in retiringTasks.values {
            task.work.cancel()
            task.join.cancel()
        }
        drainWaiters.values.forEach { $0.finish() }
    }
    struct ProviderExecutionFailure: LocalizedError, Equatable {
        let result: GenerationProviderResult

        var errorDescription: String? {
            result.errorMessage ?? "Provider request failed."
        }
    }

    /// Narrow provider dependencies; the owner has no application-state container.
    struct Dependencies {
        var suggestionGenerationService: SuggestionGenerationService?
        var delayProvider: DelayProvider

        init(
            suggestionGenerationService: SuggestionGenerationService? = nil,
            delayProvider: DelayProvider = RealDelayProvider()
        ) {
            self.suggestionGenerationService = suggestionGenerationService
            self.delayProvider = delayProvider
        }
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    /// Executes one non-streaming provider request and converts the result into
    /// the typed provider result model.
    ///
    /// This is intentionally not a lifecycle method. It does not register tasks,
    /// cancel other generations, mutate AppState, persist suggestions, or decide
    /// whether the result is still current for the UI.
    func executeProviderRequest(
        _ request: GenerationProviderRequest,
        question: DetectedQuestion,
        context: RetrievedContext,
        transcriptContext: String,
        sessionID: String,
        cvSummary: String,
        jdSummary: String,
        providerConfiguration: LLMProviderConfiguration? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async -> GenerationProviderResult {
        guard let suggestionGenerationService = dependencies.suggestionGenerationService else {
            return makeFailureResult(
                request: request,
                error: LLMProviderError.notConfigured("Suggestion generation service"),
                status: .failed
            )
        }

        do {
            let output = try await suggestionGenerationService.generateFullCard(
                question: question,
                context: context,
                transcriptContext: transcriptContext,
                sessionID: sessionID,
                cvSummary: cvSummary,
                jdSummary: jdSummary,
                customProviderConfig: providerConfiguration,
                timeoutInterval: timeoutInterval
            )
            let card = output.card
            let response = output.response
            let sections = StreamingSuggestionSections(
                strategy: card.strategy,
                sayFirst: card.sayFirst,
                keyPoints: card.keyPoints,
                followUpReady: card.followUpReady,
                caution: card.caution ?? ""
            )
            var diagnostics = request.safeDiagnostics
            diagnostics["providerName"] = response.providerName
            diagnostics["providerModel"] = response.modelName
            diagnostics["providerKind"] = response.providerKind.rawValue
            diagnostics["latencyMS"] = "\(response.latencyMS)"
            if let caution = card.caution, !caution.isEmpty {
                diagnostics["caution"] = caution
            }

            return GenerationProviderResult(
                identity: request.identity,
                sayFirst: card.sayFirst,
                keyPoints: card.keyPoints,
                followUp: card.followUpReady,
                parsedSections: sections,
                latencyMS: response.latencyMS,
                firstTokenMS: nil,
                firstVisibleMS: nil,
                providerID: request.providerID,
                providerName: response.providerName,
                providerModel: response.modelName,
                providerKind: response.providerKind,
                safeDiagnostics: diagnostics,
                providerStatus: .completed,
                errorClassification: nil,
                errorMessage: nil
            )
        } catch {
            return makeFailureResult(request: request, error: error)
        }
    }

    /// Interprets one Stage B result without applying it.
    ///
    /// The caller owns UI mutation, fallback application, and persistence.
    /// The coordinator separately fences identity and owns task cleanup; this method turns provider
    /// output plus the currently visible answer into a typed decision.
    func interpretStageBResult(
        generationID: String,
        detectedQuestionID: String?,
        activeGenerationID: String?,
        questionText: String,
        providerResult: GenerationProviderResult?,
        sections: StreamingSuggestionSections?,
        sawStreamingSections: Bool,
        visibleSayFirst: String?,
        visibleAnswerExists: Bool,
        identity: GenerationIdentity? = nil,
        questionDecision: InterviewQuestionDecision? = nil
    ) -> GenerationStageBResult {
        if activeGenerationID != generationID {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: .discardStaleResult,
                classification: .staleResult,
                fallbackReason: "Stage B result belongs to an inactive generation.",
                questionText: questionText,
                alignmentResult: nil,
                identity: identity
            )
        }

        let providerStatus = providerResult?.providerStatus
        let visibleAnswerIsUsable = Self.isVisibleAnswerUsable(
            visibleSayFirst,
            questionText: questionText,
            visibleAnswerExists: visibleAnswerExists,
            decision: questionDecision
        )

        if providerStatus == .timedOut {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: visibleAnswerIsUsable ? .keepFirstVisibleAnswer : .useSemanticFallback,
                classification: .timedOut,
                fallbackReason: visibleAnswerIsUsable ? nil : "Stage B timed out before producing an aligned visible answer.",
                questionText: questionText,
                alignmentResult: nil,
                identity: identity
            )
        }

        if providerStatus == .failed || providerStatus == .cancelled {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: visibleAnswerIsUsable ? .keepFirstVisibleAnswer : .useSemanticFallback,
                classification: .providerFailure,
                fallbackReason: visibleAnswerIsUsable ? nil : "Stage B provider failed before producing an aligned visible answer.",
                questionText: questionText,
                alignmentResult: nil,
                identity: identity
            )
        }

        let hasSections = sawStreamingSections || sections?.hasVisibleContent == true
        guard hasSections, let sections else {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: visibleAnswerIsUsable ? .keepFirstVisibleAnswer : .useSemanticFallback,
                classification: .noSections,
                fallbackReason: visibleAnswerIsUsable ? nil : "Stage B completed without usable sections.",
                questionText: questionText,
                alignmentResult: nil,
                identity: identity
            )
        }

        let alignment = Self.evaluateStageBSections(sections, questionText: questionText, decision: questionDecision)
        if alignment.verdict == .mismatched {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: .useSemanticFallback,
                classification: .fallbackRequired,
                fallbackReason: alignment.reason,
                questionText: questionText,
                alignmentResult: alignment,
                identity: identity
            )
        }

        return makeStageBDecision(
            generationID: generationID,
            detectedQuestionID: detectedQuestionID,
            providerResult: providerResult,
            decision: .applyFullCard,
            classification: .usableFullCard,
            fallbackReason: nil,
            questionText: questionText,
            alignmentResult: alignment,
            identity: identity
        )
    }

    /// Converts an interpreted Stage B result into an application plan.
    ///
    /// This is a pure planning boundary. It does not mutate UI, persist cards,
    /// register/cancel tasks, start provider work, read Keychain, or inspect
    /// audio/transcript state.
    func makeStageBApplicationPlan(
        from result: GenerationStageBResult,
        visibleSuggestion: SuggestionCard?,
        activeGenerationID: String?,
        activeQuestionID: String?
    ) -> StageBApplicationPlan {
        let isStale = result.generationID != activeGenerationID ||
            (result.detectedQuestionID != nil &&
             activeQuestionID != nil &&
             result.detectedQuestionID != activeQuestionID)

        var diagnostics = result.safeDiagnostics.reduce(into: [String: String]()) { output, item in
            output[GenerationProviderResult.redactSecrets(item.key)] = GenerationProviderResult.redactSecrets(item.value)
        }
        diagnostics["applicationPlanSource"] = "GenerationCoordinator"
        diagnostics["generationID"] = GenerationProviderResult.redactSecrets(result.generationID)
        diagnostics["detectedQuestionID"] = GenerationProviderResult.redactSecrets(result.detectedQuestionID ?? "")
        diagnostics["activeGenerationMatches"] = isStale ? "false" : "true"
        diagnostics["visibleAnswerExists"] = visibleSuggestion == nil ? "false" : "true"

        if isStale || result.decision == .discardStaleResult {
            diagnostics["stageBApplicationAction"] = StageBApplicationAction.discardStaleResult.rawValue
            return StageBApplicationPlan(
                generationID: result.generationID,
                detectedQuestionID: result.detectedQuestionID,
                action: .discardStaleResult,
                fallbackReason: result.fallbackReason ?? "Stage B result belongs to an inactive generation.",
                shouldPersist: false,
                shouldUpdateVisibleCard: false,
                safeDiagnostics: diagnostics,
                identity: result.identity
            )
        }

        let action: StageBApplicationAction
        switch result.decision {
        case .applyFullCard:
            action = .applyFullCard
        case .keepFirstVisibleAnswer:
            action = .keepVisibleFirstAnswer
        case .useSemanticFallback:
            action = .useSemanticFallback
        case .discardStaleResult:
            action = .discardStaleResult
        case .providerFailed:
            action = .markProviderFailed
        }
        diagnostics["stageBApplicationAction"] = action.rawValue

        return StageBApplicationPlan(
            generationID: result.generationID,
            detectedQuestionID: result.detectedQuestionID,
            action: action,
            fallbackReason: result.fallbackReason,
            shouldPersist: Self.shouldPersistStageBPlan(action: action, visibleSuggestion: visibleSuggestion),
            shouldUpdateVisibleCard: Self.shouldUpdateVisibleCard(action: action),
            safeDiagnostics: diagnostics,
            identity: result.identity
        )
    }

    nonisolated static func elapsedMS(since start: Date, now: Date = Date()) -> Int {
        Int(now.timeIntervalSince(start) * 1000)
    }

    /// A cooperative deadline. The group joins cancelled children before returning;
    /// an operation that ignores cancellation must release its own resource or gate.
    nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        delayProvider: DelayProvider = RealDelayProvider(),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                let value = try await operation()
                try Task.checkCancellation()
                return value
            }
            group.addTask {
                try await delayProvider.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                try Task.checkCancellation()
                throw NSError(domain: "TimeoutDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(seconds)s"])
            }

            guard let result = try await group.next() else {
                throw NSError(domain: "TimeoutDomain", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown error during race"])
            }
            try Task.checkCancellation()
            return result
        }
    }

    nonisolated static func isSpecificAnswer(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.count < 30 {
            return false
        }
        let genericPhrases = [
            "based on my experience",
            "i can speak to my background",
            "focus on explaining",
            "as a software engineer"
        ]
        for phrase in genericPhrases {
            if cleaned.contains(phrase) && cleaned.count < 80 {
                return false
            }
        }
        return true
    }

    private func makeFailureResult(
        request: GenerationProviderRequest,
        error: Error,
        status: GenerationProviderStatus? = nil
    ) -> GenerationProviderResult {
        let classification = Self.classifyProviderError(error)
        var diagnostics = request.safeDiagnostics
        diagnostics["errorClassification"] = classification.rawValue
        diagnostics["providerStatus"] = (status ?? Self.status(for: classification)).rawValue

        return GenerationProviderResult(
            identity: request.identity,
            sayFirst: "",
            keyPoints: [],
            followUp: [],
            parsedSections: nil,
            latencyMS: nil,
            firstTokenMS: nil,
            firstVisibleMS: nil,
            providerID: request.providerID,
            providerName: request.providerID,
            providerModel: request.model,
            providerKind: nil,
            safeDiagnostics: diagnostics,
            providerStatus: status ?? Self.status(for: classification),
            errorClassification: classification,
            errorMessage: error.localizedDescription
        )
    }

    private func makeStageBDecision(
        generationID: String,
        detectedQuestionID: String?,
        providerResult: GenerationProviderResult?,
        decision: StageBDecision,
        classification: StageBResultClassification,
        fallbackReason: String?,
        questionText: String,
        alignmentResult: AnswerAlignmentResult?,
        identity: GenerationIdentity? = nil
    ) -> GenerationStageBResult {
        var diagnostics = providerResult?.safeDiagnostics ?? [:]
        diagnostics["stageBDecision"] = decision.rawValue
        diagnostics["stageBClassification"] = classification.rawValue
        diagnostics["providerStatus"] = providerResult?.providerStatus.rawValue ?? "streaming"
        diagnostics["questionIntent"] = AnswerRelevancePolicy.intent(for: questionText).rawValue
        if let fallbackReason, !fallbackReason.isEmpty {
            diagnostics["fallbackReason"] = fallbackReason
        }
        if let alignmentResult {
            diagnostics["alignmentVerdict"] = alignmentResult.verdict.rawValue
            diagnostics["alignmentReason"] = alignmentResult.reason
        }

        return GenerationStageBResult(
            generationID: generationID,
            detectedQuestionID: detectedQuestionID,
            providerResult: providerResult,
            decision: decision,
            classification: classification,
            fallbackReason: fallbackReason,
            safeDiagnostics: diagnostics,
            alignmentResult: alignmentResult,
            identity: identity ?? providerResult?.identity
        )
    }

    nonisolated private static func isVisibleAnswerUsable(
        _ visibleSayFirst: String?,
        questionText: String,
        visibleAnswerExists: Bool,
        decision: InterviewQuestionDecision?
    ) -> Bool {
        guard visibleAnswerExists,
              let visibleSayFirst,
              !visibleSayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: visibleSayFirst,
            sayFirst: visibleSayFirst,
            stageBCompleted: false,
            decision: decision
        )
        return alignment.verdict == .aligned || alignment.verdict == .weaklyAligned
    }

    nonisolated private static func evaluateStageBSections(
        _ sections: StreamingSuggestionSections,
        questionText: String,
        decision: InterviewQuestionDecision?
    ) -> AnswerAlignmentResult {
        let answerText = ([sections.sayFirst] + sections.keyPoints + sections.followUpReady)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: answerText,
            sayFirst: sections.sayFirst,
            stageBCompleted: true,
            decision: decision
        )
    }

    nonisolated private static func shouldPersistStageBPlan(
        action: StageBApplicationAction,
        visibleSuggestion: SuggestionCard?
    ) -> Bool {
        switch action {
        case .applyFullCard, .useSemanticFallback:
            return true
        case .keepVisibleFirstAnswer, .markProviderFailed:
            return visibleSuggestion != nil
        case .discardStaleResult:
            return false
        }
    }

    nonisolated private static func shouldUpdateVisibleCard(action: StageBApplicationAction) -> Bool {
        switch action {
        case .applyFullCard, .useSemanticFallback, .markProviderFailed:
            return true
        case .keepVisibleFirstAnswer, .discardStaleResult:
            return false
        }
    }

    nonisolated static func classifyProviderError(_ error: Error) -> GenerationProviderErrorClassification {
        if error is CancellationError {
            return .cancellation
        }

        let nsError = error as NSError
        let message = error.localizedDescription.lowercased()
        if nsError.domain == "TimeoutDomain" || message.contains("timed out") || message.contains("timeout") {
            return .timeout
        }
        if message.contains("json") {
            return .jsonParsing
        }

        if let providerError = error as? LLMProviderError {
            switch providerError {
            case .networkFailure:
                return .network
            case .invalidResponse:
                return message.contains("json") ? .jsonParsing : .provider
            case .notConfigured,
                 .invalidBaseURL,
                 .missingAPIKey,
                 .modelNotFound,
                 .emptyResponse,
                 .rateLimited,
                 .invalidAPIKey,
                 .serverError:
                return .provider
            }
        }

        return .unknown
    }

    nonisolated private static func status(for classification: GenerationProviderErrorClassification) -> GenerationProviderStatus {
        switch classification {
        case .timeout:
            return .timedOut
        case .cancellation:
            return .cancelled
        case .jsonParsing, .provider, .network, .unknown:
            return .failed
        }
    }
}
