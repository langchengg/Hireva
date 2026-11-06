import Combine
import Foundation

/// Owns the current Live workspace and its session-scoped question ingress.
/// Generation requests, native audio resources and persistence stay with
/// their existing owners.
/// Content and generation presentation have one writable UI authority. Runtime
/// admission/terminal identities remain with GenerationCoordinator; render
/// parameters are immutable projections for pure-rule characterization.
@MainActor
final class LiveInterviewFeature: ObservableObject {
    private let liveStateSource = CurrentValueSubject<LiveInterviewState, Never>(.idle)
    var liveState: LiveInterviewState {
        get { liveStateSource.value }
        set { liveStateSource.send(newValue); objectWillChange.send() }
    }
    var liveStateUpdates: AnyPublisher<LiveInterviewState, Never> {
        liveStateSource.eraseToAnyPublisher()
    }
    private let sessionSource = CurrentValueSubject<InterviewSession?, Never>(nil)
    var currentSession: InterviewSession? {
        get { sessionSource.value }
        set {
            let previous = sessionSource.value
            // Revoke old semantic admission before publishing the committed
            // session. A subscriber's later detector belongs to that new value.
            // Cosmetic title edits preserve the existing admission.
            if previous?.id != newValue?.id ||
                previous?.contextSnapshotID != newValue?.contextSnapshotID ||
                previous?.contentRevision != newValue?.contentRevision ||
                previous?.endedAt != newValue?.endedAt {
                invalidateAutomaticDetectionAdmission()
            }
            sessionSource.send(newValue)
            objectWillChange.send()
        }
    }
    var currentSessionUpdates: AnyPublisher<InterviewSession?, Never> {
        sessionSource.eraseToAnyPublisher()
    }
    @Published var transcriptSegments: [TranscriptSegment] = []
    // Each subject is the sole writable value. Commit before synchronous
    // subscribers can replace the active generation; no willSet tail can then
    // overwrite their replacement. Keep initial and same-value delivery.
    private let suggestionSource = CurrentValueSubject<SuggestionCard?, Never>(nil)
    var currentSuggestion: SuggestionCard? {
        get { suggestionSource.value }
        set { suggestionSource.send(newValue); objectWillChange.send() }
    }
    var suggestionUpdates: AnyPublisher<SuggestionCard?, Never> {
        suggestionSource.eraseToAnyPublisher()
    }
    @Published var liveSuggestionHistory: [SuggestionCard] = []
    private let detectedQuestionSource = CurrentValueSubject<DetectedQuestion?, Never>(nil)
    var lastDetectedQuestion: DetectedQuestion? {
        get { detectedQuestionSource.value }
        set { detectedQuestionSource.send(newValue); objectWillChange.send() }
    }
    var detectedQuestionUpdates: AnyPublisher<DetectedQuestion?, Never> {
        detectedQuestionSource.eraseToAnyPublisher()
    }
    private let possibleQuestionSource = CurrentValueSubject<DetectedQuestion?, Never>(nil)
    var possibleQuestion: DetectedQuestion? {
        get { possibleQuestionSource.value }
        set { possibleQuestionSource.send(newValue); objectWillChange.send() }
    }
    var possibleQuestionUpdates: AnyPublisher<DetectedQuestion?, Never> {
        possibleQuestionSource.eraseToAnyPublisher()
    }
    @Published var lastTranscriptSnippet = ""
    @Published var rawTranscriptText = ""
    @Published var partialTranscriptText = ""
    @Published var finalTranscriptText = ""
    @Published var displayTranscriptText = ""
    @Published var lastAcceptedQuestionText = ""
    @Published var currentSuggestionRetrievedChunks: [RetrievedChunk] = []
    private let streamedSayFirstSource = CurrentValueSubject<String, Never>("")
    var streamedSayFirst: String {
        get { streamedSayFirstSource.value }
        set { streamedSayFirstSource.send(newValue); objectWillChange.send() }
    }
    var streamedSayFirstUpdates: AnyPublisher<String, Never> {
        streamedSayFirstSource.eraseToAnyPublisher()
    }
    // The busy fact participates in automatic queue admission. Commit before
    // notifying observers so an old terminal setter cannot overwrite a newly
    // submitted generation; transition time follows the same presentation owner.
    private let suggestionGenerationStartedSource = CurrentValueSubject<Bool, Never>(false)
    var suggestionGenerationStarted: Bool {
        get { suggestionGenerationStartedSource.value }
        set { suggestionGenerationStartedSource.send(newValue); objectWillChange.send() }
    }
    private let lastGenerationStateChangeAtSource = CurrentValueSubject<Date?, Never>(nil)
    var lastGenerationStateChangeAt: Date? {
        get { lastGenerationStateChangeAtSource.value }
        set { lastGenerationStateChangeAtSource.send(newValue); objectWillChange.send() }
    }
    private let generationStateSource = CurrentValueSubject<GenerationUIState, Never>(.idle)
    var generationUIState: GenerationUIState {
        get { generationStateSource.value }
        set { generationStateSource.send(newValue); objectWillChange.send() }
    }
    var generationStateUpdates: AnyPublisher<GenerationUIState, Never> {
        generationStateSource.eraseToAnyPublisher()
    }
    private let telemetrySource = CurrentValueSubject<GenerationTelemetry, Never>(.idle)
    var currentGenerationTelemetry: GenerationTelemetry {
        get { telemetrySource.value }
        set { telemetrySource.send(newValue); objectWillChange.send() }
    }
    var generationTelemetryUpdates: AnyPublisher<GenerationTelemetry, Never> {
        telemetrySource.eraseToAnyPublisher()
    }
    private let currentSuggestionSetAtSource = CurrentValueSubject<Date?, Never>(nil)
    var currentSuggestionSetAt: Date? {
        get { currentSuggestionSetAtSource.value }
        set { currentSuggestionSetAtSource.send(newValue); objectWillChange.send() }
    }
    var currentSuggestionSetAtUpdates: AnyPublisher<Date?, Never> {
        currentSuggestionSetAtSource.eraseToAnyPublisher()
    }
    private let softFallbackUsedSource = CurrentValueSubject<Bool, Never>(false)
    var softFallbackUsed: Bool {
        get { softFallbackUsedSource.value }
        set { softFallbackUsedSource.send(newValue); objectWillChange.send() }
    }
    var softFallbackUsedUpdates: AnyPublisher<Bool, Never> {
        softFallbackUsedSource.eraseToAnyPublisher()
    }
    private let softFallbackLatencyMSSource = CurrentValueSubject<Int?, Never>(nil)
    var softFallbackLatencyMS: Int? {
        get { softFallbackLatencyMSSource.value }
        set { softFallbackLatencyMSSource.send(newValue); objectWillChange.send() }
    }
    var softFallbackLatencyMSUpdates: AnyPublisher<Int?, Never> {
        softFallbackLatencyMSSource.eraseToAnyPublisher()
    }
    private let softFallbackShownAtSource = CurrentValueSubject<Date?, Never>(nil)
    var softFallbackShownAt: Date? {
        get { softFallbackShownAtSource.value }
        set { softFallbackShownAtSource.send(newValue); objectWillChange.send() }
    }
    var softFallbackShownAtUpdates: AnyPublisher<Date?, Never> {
        softFallbackShownAtSource.eraseToAnyPublisher()
    }
    private let finalVisibleSourceSource = CurrentValueSubject<String?, Never>(nil)
    var finalVisibleSource: String? {
        get { finalVisibleSourceSource.value }
        set { finalVisibleSourceSource.send(newValue); objectWillChange.send() }
    }
    var finalVisibleSourceUpdates: AnyPublisher<String?, Never> {
        finalVisibleSourceSource.eraseToAnyPublisher()
    }
    // Presentation phase preserves the existing Stage A start/exit contract;
    // actual producer/task lifetime remains in GenerationCoordinator.
    private let providerStreamActiveSource = CurrentValueSubject<Bool, Never>(false)
    var providerStreamActive: Bool {
        get { providerStreamActiveSource.value }
        set { providerStreamActiveSource.send(newValue); objectWillChange.send() }
    }
    var providerStreamActiveUpdates: AnyPublisher<Bool, Never> {
        providerStreamActiveSource.eraseToAnyPublisher()
    }
    private let isStreamingSayFirstSource = CurrentValueSubject<Bool, Never>(false)
    var isStreamingSayFirst: Bool {
        get { isStreamingSayFirstSource.value }
        set { isStreamingSayFirstSource.send(newValue); objectWillChange.send() }
    }
    var isStreamingSayFirstUpdates: AnyPublisher<Bool, Never> {
        isStreamingSayFirstSource.eraseToAnyPublisher()
    }
    private let isExpandingSuggestionCardSource = CurrentValueSubject<Bool, Never>(false)
    var isExpandingSuggestionCard: Bool {
        get { isExpandingSuggestionCardSource.value }
        set { isExpandingSuggestionCardSource.send(newValue); objectWillChange.send() }
    }
    var isExpandingSuggestionCardUpdates: AnyPublisher<Bool, Never> {
        isExpandingSuggestionCardSource.eraseToAnyPublisher()
    }

    private let captureRuntimeSource = CurrentValueSubject<CaptureRuntimeState, Never>(.idle)
    var currentCaptureRuntimeState: CaptureRuntimeState {
        get { captureRuntimeSource.value }
        set { captureRuntimeSource.send(newValue); objectWillChange.send() }
    }
    var captureRuntimeStateUpdates: AnyPublisher<CaptureRuntimeState, Never> {
        captureRuntimeSource.eraseToAnyPublisher()
    }
    @Published var stopReason: StopReason?
    @Published var lastCaptureStartedAt: Date?
    @Published var lastCaptureStoppedAt: Date?
    @Published var recent20CaptureEvents: [LiveCaptureEvent] = []

    // The selected mode remains a setting. Resolved flow and the latest turn
    // belong to this Live session; partial ASR can update the turn without
    // committing a phase transition.
    @Published var resolvedInterviewSessionPhase: DialogueSessionPhase = .auto
    @Published var interviewPhase: InterviewPhase = .unknown {
        didSet { applyLegacyInterviewPhaseBridge(interviewPhase) }
    }
    @Published var detectedDialogueSpeakerRole: DialogueTurnRole = .ambiguous
    @Published var detectedDialogueTurnType: DialogueTurnType = .unknown
    @Published var lastDialogueSourceChannel = ""
    @Published var lastModeTransition = ""
    @Published var lastModeTransitionReason = ""

    // Session-scoped ingress memory is independent from UI snapshots and from
    // capture/LLM work. Reuse the exact transcript and question identities; a
    // cumulative callback must not become fresh merely after a cooldown.
    private let autoQuestionDuplicateCooldownSeconds: TimeInterval = 60
    private var recentQuestionTimestamps = [String: Date]()
    private var acceptedQuestionSegmentIDs = [String: String]()
    private var consumedQuestionOccurrences = [String: TranscriptQuestionIngressIdentity]()
    private var consumedQuestionSourceSpans = [String: TranscriptQuestionIngressIdentity]()
    private var consumedQuestionAbsoluteSourceSpans = [String: TranscriptQuestionIngressIdentity]()
    private var acceptedNormalizedQuestionKeys = Set<String>()
    private(set) var intentionalRepeatQuestionIDs = Set<String>()
    private var transcriptReconciler = TranscriptReconciler()

    private struct RecentSystemAudioRecord {
        let text: String
        let timestamp: Date
    }
    private var recentSystemAudioRecords: [RecentSystemAudioRecord] = []
    private var transcriptSegmentIngestedAt = [String: Date]()

    struct PendingAcceptedQuestion: Equatable {
        let question: DetectedQuestion
        let session: InterviewSession
        let transcript: String
        let canonicalQuestion: String
        let intent: AnswerRelevanceIntent
        let promptPrimaryQuestion: String
        let duplicateKey: String
        let queuedAt: Date
        let consentTicket: Int?
    }
    private var acceptedQuestionQueue: [PendingAcceptedQuestion] = []
    private var queueCommitDepth = 0
    var pendingAcceptedQuestions: [PendingAcceptedQuestion] { acceptedQuestionQueue }

    private func commitAcceptedQuestions(_ operation: @MainActor () -> Void) {
        queueCommitDepth += 1
        defer {
            queueCommitDepth -= 1
            if queueCommitDepth == 0 { objectWillChange.send() }
        }
        operation()
    }

    // Ingress timing and echo support are not UI publications. Preserve the
    // existing bounded metadata and five-second cross-source history policies.
    func recordTranscriptIngress(segmentID: String, at date: Date) {
        transcriptSegmentIngestedAt[segmentID] = date
        if transcriptSegmentIngestedAt.count > 512 {
            let oldestIDs = transcriptSegmentIngestedAt.sorted { $0.value < $1.value }
                .prefix(256).map(\.key)
            for id in oldestIDs {
                transcriptSegmentIngestedAt.removeValue(forKey: id)
            }
        }
    }

    func transcriptIngressDate(for segmentID: String) -> Date? {
        transcriptSegmentIngestedAt[segmentID]
    }

    func recordSystemAudioForEcho(_ text: String, now: Date = Date()) {
        recentSystemAudioRecords.append(RecentSystemAudioRecord(text: text, timestamp: now))
        recentSystemAudioRecords.removeAll { now.timeIntervalSince($0.timestamp) > 5.0 }
    }

    func microphoneEchoMatch(_ text: String, now: Date = Date()) -> (textLength: Int, similarity: Double)? {
        recentSystemAudioRecords.removeAll { now.timeIntervalSince($0.timestamp) > 5.0 }
        let micWords = Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        guard !micWords.isEmpty else { return nil }
        for record in recentSystemAudioRecords {
            let systemWords = Set(record.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty })
            let intersection = micWords.intersection(systemWords)
            let union = micWords.union(systemWords)
            if !union.isEmpty {
                let similarity = Double(intersection.count) / Double(union.count)
                if similarity >= 0.5 { return (record.text.count, similarity) }
            }
        }
        return nil
    }

    // These callbacks are synchronous and nonescaping. Commit the sole queue,
    // finish existing App coordination, then notify. No old business effects
    // run after a subscriber can stop or replace the just-submitted request.
    @discardableResult
    func enqueueAcceptedQuestion(_ pending: PendingAcceptedQuestion,
        onCommitted: @MainActor () -> Void) -> Bool {
        guard !acceptedQuestionQueue.contains(where: { $0.duplicateKey == pending.duplicateKey }) else { return false }
        commitAcceptedQuestions {
            acceptedQuestionQueue.append(pending)
            onCommitted()
        }
        return true
    }

    @discardableResult
    func dequeueAcceptedQuestion(ifHeadMatches expected: PendingAcceptedQuestion,
        onCommitted: @MainActor (PendingAcceptedQuestion) -> Void) -> Bool {
        guard let head = acceptedQuestionQueue.first, head == expected else { return false }
        commitAcceptedQuestions {
            acceptedQuestionQueue.removeFirst()
            onCommitted(head)
        }
        return true
    }

    func clearAcceptedQuestions(onCommitted: @MainActor () -> Void) {
        commitAcceptedQuestions {
            acceptedQuestionQueue.removeAll()
            onCommitted()
        }
    }

    // The final listening transition of the ASR acceptance caller belongs to
    // the same synchronous coordination, before its new queue notification.
    func coordinateAcceptedQuestions(_ operation: @MainActor () -> Void) {
        commitAcceptedQuestions(operation)
    }

    // Existing mixed replay fixtures replace a whole queue through AppState.
    // This forwards to the same storage and needs no later business effect.
    func replaceAcceptedQuestions(_ questions: [PendingAcceptedQuestion]) {
        commitAcceptedQuestions { acceptedQuestionQueue = questions }
    }

    // One registry owns current and retired detection/debounce roots until
    // their real exit. Admission identity is not a claim that a cancelled
    // provider has released its resources.
    private struct DetectionWork: Sendable {
        let task: Task<Void, Never>
        let join: Task<Void, Never>
        let partialSegmentID: String?
    }
    private enum DetectionExecutionScope {
        @TaskLocal static var id: UUID? = nil
    }
    private var detectionWork: [UUID: DetectionWork] = [:]
    private var automaticDetectionID: UUID?
    private var detectionDebounceID: UUID?
    private var partialFinalizationIDs: [String: UUID] = [:]
    private var automaticDetectionAdmissionClosed = false
#if DEBUG
    // Observation only of the actual original handle immediately before join.
    var automaticDetectionTaskWillAwaitForTesting: (@MainActor (Task<Void, Never>) -> Void)?
#endif

    var activeDetectionTask: Task<Void, Never>? {
        automaticDetectionID.flatMap { detectionWork[$0]?.task }
    }
    var detectionDebounceTask: Task<Void, Never>? {
        detectionDebounceID.flatMap { detectionWork[$0]?.task }
    }
    var pendingAutomaticDetectionTaskCount: Int {
        detectionWork.values.filter { $0.partialSegmentID == nil }.count
    }
    var pendingPartialFinalizationTaskCount: Int {
        detectionWork.values.filter { $0.partialSegmentID != nil }.count
    }
    // Count original retained roots by current admission; join observers are
    // intentionally outside this metric. No additional task storage exists.
    var detectionTaskCounts: (active: Int, retiring: Int) {
        let admitted = Set([automaticDetectionID, detectionDebounceID].compactMap { $0 })
            .union(partialFinalizationIDs.values)
        let active = detectionWork.keys.filter { admitted.contains($0) }.count
        return (active, detectionWork.count - active)
    }
    // Current compatibility projection only. Retired roots remain in the same
    // exact-identity ingress registry until their original Task has exited.
    var partialUtteranceFinalizationTasks: [String: Task<Void, Never>] {
        partialFinalizationIDs.compactMapValues { detectionWork[$0]?.task }
    }

    @discardableResult
    func submitPartialUtteranceFinalization(segmentID: String,
        operation: @escaping @MainActor (UUID) async -> Void) -> Task<Void, Never>? {
        guard !automaticDetectionAdmissionClosed else { return nil }
        let previous = partialFinalizationIDs[segmentID].flatMap { detectionWork[$0]?.task }
        let id = UUID()
        partialFinalizationIDs[segmentID] = id // Revoke before cancellation can reenter.
        previous?.cancel()
        guard acceptsPartialUtteranceFinalization(segmentID: segmentID, id: id) else { return nil }
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  self.acceptsPartialUtteranceFinalization(segmentID: segmentID, id: id) else { return }
            await DetectionExecutionScope.$id.withValue(id) { await operation(id) }
        }
        registerDetectionWork(task, id: id, partialSegmentID: segmentID)
        return task
    }

    func acceptsPartialUtteranceFinalization(segmentID: String, id: UUID) -> Bool {
        !automaticDetectionAdmissionClosed && partialFinalizationIDs[segmentID] == id
    }

    func finishPartialUtteranceFinalizationAdmission(segmentID: String, id: UUID) {
        if partialFinalizationIDs[segmentID] == id { partialFinalizationIDs[segmentID] = nil }
    }

    func cancelPartialUtteranceFinalization(segmentID: String) {
        let id = partialFinalizationIDs.removeValue(forKey: segmentID)
        if let id { detectionWork[id]?.task.cancel() }
    }

    func cancelPartialUtteranceFinalizations() {
        partialFinalizationIDs.removeAll()
        for work in detectionWork.values where work.partialSegmentID != nil { work.task.cancel() }
    }

    // Execution metadata only: admission still uses automaticDetectionID.
    // An inherited child cannot wait for the exact root that keeps it alive.
    var canDrainAutomaticDetectionFromCurrentTask: Bool {
        guard let id = DetectionExecutionScope.id else { return true }
        return detectionWork[id] == nil
    }

    @discardableResult
    func submitAutomaticDetection(
        operation: @escaping @MainActor (UUID) async -> Void
    ) -> Task<Void, Never>? {
        guard !automaticDetectionAdmissionClosed else { return nil }
        cancelAutomaticDetection()
        let id = UUID()
        automaticDetectionID = id
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  self.acceptsAutomaticDetection(id) else { return }
            await DetectionExecutionScope.$id.withValue(id) {
                await operation(id)
            }
        }
        registerDetectionWork(task, id: id)
        return task
    }

    func scheduleAutomaticDetection(
        delayNanoseconds: UInt64, operation: @escaping @MainActor () -> Void
    ) {
        guard !automaticDetectionAdmissionClosed else { return }
        cancelAutomaticDetectionDebounce()
        let id = UUID()
        detectionDebounceID = id
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delayNanoseconds) }
            catch { return }
            guard let self, !Task.isCancelled,
                  !self.automaticDetectionAdmissionClosed,
                  self.detectionDebounceID == id else { return }
            DetectionExecutionScope.$id.withValue(id) { operation() }
        }
        registerDetectionWork(task, id: id)
    }

    private func registerDetectionWork(_ task: Task<Void, Never>, id: UUID,
        partialSegmentID: String? = nil) {
        let join = Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.detectionWork.removeValue(forKey: id)
            if self.automaticDetectionID == id { self.automaticDetectionID = nil }
            if self.detectionDebounceID == id { self.detectionDebounceID = nil }
            if let partialSegmentID, self.partialFinalizationIDs[partialSegmentID] == id {
                self.partialFinalizationIDs[partialSegmentID] = nil
            }
        }
        // MainActor cannot run either child before this synchronous commit.
        detectionWork[id] = DetectionWork(task: task, join: join, partialSegmentID: partialSegmentID)
    }

    func acceptsAutomaticDetection(_ id: UUID) -> Bool {
        !automaticDetectionAdmissionClosed && automaticDetectionID == id
    }

    func finishAutomaticDetectionAdmission(_ id: UUID) {
        if automaticDetectionID == id { automaticDetectionID = nil }
        // The exact record stays managed until registerDetectionWork joins exit.
    }

    func cancelAutomaticDetection() {
        let task = activeDetectionTask
        automaticDetectionID = nil
        task?.cancel()
    }

    func cancelAutomaticDetectionDebounce() {
        let task = detectionDebounceTask
        detectionDebounceID = nil
        task?.cancel()
    }

    func invalidateAutomaticDetectionAdmission() {
        cancelAutomaticDetection()
        cancelPartialUtteranceFinalizations()
    }

    func closeAutomaticDetectionAdmission() {
        automaticDetectionAdmissionClosed = true
        automaticDetectionID = nil
        detectionDebounceID = nil
        partialFinalizationIDs.removeAll()
        for work in detectionWork.values { work.task.cancel() }
    }

    /// A root or inherited child reports incomplete cleanup instead of joining
    /// its own exit. The same registry retains it for an external drain.
    @discardableResult
    func drainAutomaticDetection() async -> Bool {
        guard canDrainAutomaticDetectionFromCurrentTask else { return false }
        while !detectionWork.isEmpty {
            let snapshot = Array(detectionWork.values)
            for work in snapshot {
#if DEBUG
                automaticDetectionTaskWillAwaitForTesting?(work.task)
#endif
                await work.join.value
            }
        }
        return true
    }

    deinit {
        for work in detectionWork.values { work.task.cancel() }
    }

    func dialogueRuntimeState(selectedSessionMode: InterviewSessionMode) -> DialogueRuntimeState {
        DialogueRuntimeState(
            selectedSessionMode: selectedSessionMode,
            resolvedSessionPhase: resolvedInterviewSessionPhase,
            detectedSpeakerRole: detectedDialogueSpeakerRole,
            detectedTurnType: detectedDialogueTurnType
        )
    }

    func interviewSessionModeSelectionDidChange(
        from oldValue: InterviewSessionMode,
        to selectedMode: InterviewSessionMode
    ) {
        let nextPhase = DialogueSessionPhase.initial(for: selectedMode)
        guard oldValue != selectedMode || resolvedInterviewSessionPhase != nextPhase else { return }
        let previous = resolvedInterviewSessionPhase
        resolvedInterviewSessionPhase = nextPhase
        lastModeTransition = "\(previous.rawValue) -> \(nextPhase.rawValue)"
        lastModeTransitionReason = "user selected \(selectedMode.rawValue)"
    }

    func applyDialogueDecision(
        _ decision: DialogueTriggerDecision,
        source: AudioSourceType,
        allowModeTransition: Bool = true
    ) {
        detectedDialogueSpeakerRole = decision.speakerRole
        detectedDialogueTurnType = decision.turnType
        lastDialogueSourceChannel = source.rawValue
        if allowModeTransition,
           let nextPhase = decision.nextResolvedSessionPhase,
           nextPhase != resolvedInterviewSessionPhase {
            let previous = resolvedInterviewSessionPhase
            resolvedInterviewSessionPhase = nextPhase
            lastModeTransition = "\(previous.rawValue) -> \(nextPhase.rawValue)"
            lastModeTransitionReason = decision.modeTransitionReason
        }
    }

    func applyLegacyInterviewPhaseBridge(_ phase: InterviewPhase) {
        switch phase {
        case .unknown:
            return
        case .logistics:
            detectedDialogueTurnType = .logistics
        case .candidatePresentation:
            resolvedInterviewSessionPhase = .presentation
            detectedDialogueTurnType = .candidatePresentation
        case .interviewerQuestions:
            resolvedInterviewSessionPhase = .panelQuestions
        case .candidateAnswer:
            // Candidate answer is a turn classification, never a global mode.
            detectedDialogueTurnType = .candidateAnswer
        case .candidateQuestionsToPanel:
            resolvedInterviewSessionPhase = .candidateQuestions
            detectedDialogueTurnType = .candidateQuestionToPanel
        case .closing:
            resolvedInterviewSessionPhase = .closing
            detectedDialogueTurnType = .closing
        }
    }

    func segmentForQuestionExtraction(_ segment: TranscriptSegment) -> TranscriptSegment? {
        transcriptReconciler.segmentForQuestionExtraction(segment)
    }

    func markIntentionalQuestionRepeat(_ questionID: String) {
        intentionalRepeatQuestionIDs.insert(questionID)
    }

    func resetQuestionIngress() {
        invalidateAutomaticDetectionAdmission()
        recentQuestionTimestamps.removeAll()
        acceptedQuestionSegmentIDs.removeAll()
        consumedQuestionOccurrences.removeAll()
        consumedQuestionSourceSpans.removeAll()
        consumedQuestionAbsoluteSourceSpans.removeAll()
        acceptedNormalizedQuestionKeys.removeAll()
        intentionalRepeatQuestionIDs.removeAll()
        transcriptReconciler.reset()
    }

#if DEBUG
    // Existing synthetic replay tests intentionally age the semantic cooldown
    // and restart reconciliation. No production caller writes these values.
    var recentQuestionTimestampsForTesting: [String: Date] {
        get { recentQuestionTimestamps }
        set { recentQuestionTimestamps = newValue }
    }
    var transcriptReconcilerForTesting: TranscriptReconciler {
        get { transcriptReconciler }
        set { transcriptReconciler = newValue }
    }
#endif

    // UI audit snapshots have the existing twenty-event bound. Native resource
    // ownership and successful cleanup remain with LiveCaptureLifecycle.
    func appendCaptureEvent(_ event: LiveCaptureEvent) {
        recent20CaptureEvents.append(event)
        if recent20CaptureEvents.count > 20 { recent20CaptureEvents.removeFirst() }
    }

    // Keep control-task cancellation at the caller. This method only clears
    // the five current display fields formerly reset together by that boundary.
    func resetTranscriptDisplay() {
        rawTranscriptText = ""
        partialTranscriptText = ""
        finalTranscriptText = ""
        displayTranscriptText = ""
        lastAcceptedQuestionText = ""
    }

    /// The input has already passed the production publication boundary. Local
    /// history additionally refuses partial, empty and foreign-session cards.
    /// Returning the normalized stored value lets the caller keep its existing
    /// audit/HistoryState effects without repeating this mutation rule.
    @discardableResult
    func recordVisibleCardInHistory(_ card: SuggestionCard) -> (card: SuggestionCard, didAppend: Bool)? {
        guard !card.isPartial,
              !card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              currentSession?.id == card.sessionID else { return nil }
        var historyCard = card
        if historyCard.detectedQuestionID == nil {
            historyCard.detectedQuestionID = historyCard.questionID
        }
        let didAppend = !liveSuggestionHistory.contains { $0.id == historyCard.id }
        if let index = liveSuggestionHistory.firstIndex(where: { $0.id == historyCard.id }) {
            liveSuggestionHistory[index] = historyCard
        } else {
            liveSuggestionHistory.append(historyCard)
        }
        liveSuggestionHistory.sort { $0.createdAt < $1.createdAt }
        if liveSuggestionHistory.count > 20 {
            liveSuggestionHistory.removeFirst(liveSuggestionHistory.count - 20)
        }
        return (historyCard, didAppend)
    }

    var visibleAnswerExists: Bool {
        if let card = currentSuggestion, !displayableAnswerText(card.sayFirst).isEmpty { return true }
        return !displayableAnswerText(streamedSayFirst).isEmpty
    }

    func shouldShowBlockingAnswerSpinner(generationState: GenerationUIState, elapsedMS: Int) -> Bool {
        generationState.isLoadingWithoutVisibleAnswer && !visibleAnswerExists && elapsedMS < 1_500
    }

    func shouldShowAnswerExpansionStatus(generationState: GenerationUIState, isExpanding: Bool) -> Bool {
        visibleAnswerExists && (generationState.isExpandingAfterVisibleAnswer || isExpanding)
    }

    func visibleSuggestionState(
        activeIdentity: GenerationIdentity?,
        generationState: GenerationUIState
    ) -> VisibleSuggestionState? {
        if let card = currentSuggestion,
           let generationID = card.generationID ?? activeIdentity?.generationID,
           let identity = GenerationIdentity(card: card, generationID: generationID) {
            return VisibleSuggestionState(identity: identity,
                questionText: identity.questionText, answerText: card.sayFirst,
                status: card.stageBStatus ?? generationState.displayName,
                generationErrorText: generationErrorText(for: generationState), card: card)
        }
        if let activeIdentity {
            return VisibleSuggestionState(identity: activeIdentity,
                questionText: activeIdentity.questionText, answerText: streamedSayFirst,
                status: generationState.displayName,
                generationErrorText: generationErrorText(for: generationState), card: nil)
        }
        return nil
    }

    func visibleQuestionText(
        for card: SuggestionCard?,
        activeIdentity: GenerationIdentity?,
        generationState: GenerationUIState
    ) -> String? {
        if card == nil, let snapshot = visibleSuggestionState(activeIdentity: activeIdentity, generationState: generationState) {
            return snapshot.questionText
        }
        if let cardQuestion = card?.questionText ?? card?.promptPrimaryQuestion ?? card?.promptQuestionText,
           !cardQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return cardQuestion }
        if !streamedSayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let activeQuestion = activeIdentity?.questionText,
           !activeQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return activeQuestion }
        if let lastDetectedQuestion { return lastDetectedQuestion.questionText }
        return possibleQuestion?.questionText
    }

    /// Reuses existing coherent render models. Call in the observing view body;
    /// do not cache this result as a parallel writable presentation snapshot.
    func renderState(
        activeIdentity: GenerationIdentity?,
        generationState: GenerationUIState,
        elapsedMS: Int,
        isStreaming: Bool,
        isExpanding: Bool,
        providerStreamActive: Bool
    ) -> VisibleAssistantRenderState {
        let snapshot = visibleSuggestionState(activeIdentity: activeIdentity, generationState: generationState)
        let card = currentSuggestion
        let question = snapshot?.questionText ??
            visibleQuestionText(for: card, activeIdentity: activeIdentity, generationState: generationState) ??
            (!displayTranscriptText.isEmpty ? displayTranscriptText : lastTranscriptSnippet)
        let rawAnswer = snapshot?.answerText.isEmpty == false ? snapshot?.answerText ?? "" :
            (card?.sayFirst.isEmpty == false ? card?.sayFirst ?? "" : streamedSayFirst)
        let answer = displayableAnswerText(rawAnswer)
        return VisibleAssistantRenderState(questionText: question, answerText: answer,
            keyPoints: card?.keyPoints ?? [],
            generationStatus: snapshot?.status ?? generationState.displayName,
            generationErrorText: snapshot?.generationErrorText ?? generationErrorText(for: generationState),
            isGenerating: shouldShowBlockingAnswerSpinner(generationState: generationState, elapsedMS: elapsedMS) ||
                shouldShowAnswerExpansionStatus(generationState: generationState, isExpanding: isExpanding) ||
                isStreaming || providerStreamActive,
            hasAnswerText: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            activeGenerationID: activeIdentity?.generationID,
            activeQuestionID: activeIdentity?.acceptedQuestionID)
    }

    func displayableAnswerText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(trimmed) ? "" : trimmed
    }

    func generationErrorText(for state: GenerationUIState) -> String? {
        guard let reason = state.failureReason,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch state {
        case .lowConfidenceRejected: return reason
        case .failed: return "Generation failed: \(reason)"
        case .timeout: return "Generation timed out: \(reason)"
        case .cancelled: return "Generation cancelled: \(reason)"
        case .idle, .preparing, .generatingFirstAnswer, .showingFallback, .streamingAnswer,
             .expandingFullAnswer, .answerReady, .needsInput: return nil
        }
    }

    func isRecentDuplicateAutoQuestion(
        _ questionText: String,
        transcriptSegmentID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        let normalized = normalizedQuestion(questionText)
        guard !normalized.isEmpty else { return false }

        if let transcriptSegmentID,
           acceptedQuestionSegmentIDs[normalized] == transcriptSegmentID {
            return true
        }
        if let transcriptSegmentID {
            for (fingerprint, acceptedSegmentID) in acceptedQuestionSegmentIDs
            where acceptedSegmentID == transcriptSegmentID && isNearDuplicateQuestion(normalized, fingerprint) {
                return true
            }
        }

        pruneRecentQuestionTimestamps(now: now)

        if let lastTime = recentQuestionTimestamps[normalized],
           now.timeIntervalSince(lastTime) <= autoQuestionDuplicateCooldownSeconds {
            return true
        }

        for (fingerprint, timestamp) in recentQuestionTimestamps {
            if now.timeIntervalSince(timestamp) <= autoQuestionDuplicateCooldownSeconds {
                if isNearDuplicateQuestion(normalized, fingerprint) {
                    return true
                }
            }
        }

        return false
    }

    private func isNearDuplicateQuestion(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }

        let lhsWordCount = lhs.split(separator: " ").count
        let rhsWordCount = rhs.split(separator: " ").count
        guard lhsWordCount > 0, rhsWordCount > 0 else {
            return false
        }

        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count > rhs.count ? lhs : rhs
        guard longer.contains(shorter) else {
            return false
        }

        let wordRatio = Double(max(lhsWordCount, rhsWordCount)) / Double(min(lhsWordCount, rhsWordCount))
        if wordRatio <= 1.35 {
            return true
        }

        let remainder = longer
            .replacingOccurrences(of: shorter, with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return !containsQuestionStarter(remainder)
    }

    private func containsQuestionStarter(_ text: String) -> Bool {
        let padded = " \(text.lowercased()) "
        let starters = [
            " what ", " how ", " why ", " where ", " who ", " when ",
            " can you ", " could you ", " would you ", " should you ",
            " are you ", " do you ", " have you ", " is there ",
            " tell me ", " walk me ", " describe ", " explain "
        ]
        return starters.contains { padded.contains($0) }
    }

    func rememberAutoQuestion(
        _ questionText: String,
        transcriptSegmentID: String? = nil,
        now: Date = Date()
    ) {
        let normalized = normalizedQuestion(questionText)
        guard !normalized.isEmpty else { return }
        pruneRecentQuestionTimestamps(now: now)
        recentQuestionTimestamps[normalized] = now
        if let transcriptSegmentID, !transcriptSegmentID.isEmpty {
            acceptedQuestionSegmentIDs[normalized] = transcriptSegmentID
        }
    }

    private func pruneRecentQuestionTimestamps(now: Date) {
        for (fingerprint, timestamp) in recentQuestionTimestamps {
            if now.timeIntervalSince(timestamp) > autoQuestionDuplicateCooldownSeconds {
                recentQuestionTimestamps.removeValue(forKey: fingerprint)
            }
        }
    }

    private func normalizedQuestion(_ text: String) -> String {
        SystemAudioQuestionExtractor.duplicateKey(for: text)
    }

    func consumedReplaySource(
        _ question: DetectedQuestion,
        isCumulativeTranscript: Bool
    ) -> TranscriptQuestionIngressIdentity? {
        guard let ingress = question.ingressIdentity else { return nil }
        if let consumed = consumedQuestionOccurrences[ingress.occurrenceKey] {
            return consumed
        }
        guard isCumulativeTranscript else { return nil }
        if let consumed = consumedQuestionSourceSpans[ingress.sourceSpanKey] {
            return consumed
        }
        if let consumed = consumedQuestionAbsoluteSourceSpans[ingress.absoluteSourceSpanKey] {
            return consumed
        }
        return consumedQuestionAbsoluteSourceSpans.values.first {
            $0.normalizedText == ingress.normalizedText &&
                sourceSpanOverlapScore($0, ingress) >= 0.80
        }
    }

    func isIntentionalQuestionRepeat(
        _ question: DetectedQuestion,
        isCumulativeTranscript: Bool,
        replayedOccurrence: Bool
    ) -> Bool {
        guard !replayedOccurrence else { return false }
        guard !isCumulativeTranscript else { return false }
        let normalized = normalizedQuestion(question.questionText)
        return acceptedNormalizedQuestionKeys.contains(normalized)
    }

    func rememberConsumedTranscriptOccurrence(_ question: DetectedQuestion) {
        let normalized = normalizedQuestion(question.questionText)
        acceptedNormalizedQuestionKeys.insert(normalized)
        guard let ingress = question.ingressIdentity else { return }
        consumedQuestionOccurrences[ingress.occurrenceKey] = ingress
        consumedQuestionSourceSpans[ingress.sourceSpanKey] = ingress
        consumedQuestionAbsoluteSourceSpans[ingress.absoluteSourceSpanKey] = ingress
    }

    func sourceSpanOverlapScore(
        _ lhs: TranscriptQuestionIngressIdentity,
        _ rhs: TranscriptQuestionIngressIdentity
    ) -> Double {
        let overlapStart = max(lhs.sourceStartUTF16, rhs.sourceStartUTF16)
        let overlapEnd = min(lhs.sourceEndUTF16, rhs.sourceEndUTF16)
        let overlap = max(0, overlapEnd - overlapStart)
        let shortest = max(1, min(
            lhs.sourceEndUTF16 - lhs.sourceStartUTF16,
            rhs.sourceEndUTF16 - rhs.sourceStartUTF16
        ))
        return Double(overlap) / Double(shortest)
    }
}

public struct LiveCaptureEvent: Identifiable, Codable, Hashable {
    public let id: String
    public let timestamp: Date
    public let eventName: String
    public let stateBefore: String
    public let stateAfter: String
    public let reason: String
    public let file: String
    public let function: String
    public let line: Int
    public let systemCaptureRunning: Bool
    public let micCaptureRunning: Bool
    public let lastSystemAudioBufferAt: Date?
}
