import AVFoundation
import Combine
import Foundation
import os

/// Owns one bounded Manual recording, its callback streams and retained exit.
/// Generation remains in the existing coordinator after a reviewed transcript.
@MainActor
final class ManualCaptureController: ObservableObject {
    struct Configuration: Equatable {
        let source: ManualCaptureSource
        let maxDuration: Int
        let showTranscriptBeforeSending: Bool
        let autoSendAfterTranscription: Bool
        let requiresOnDeviceRecognition: Bool

        init(source: ManualCaptureSource, maxDuration: Int, showTranscriptBeforeSending: Bool,
            autoSendAfterTranscription: Bool, requiresOnDeviceRecognition: Bool = false) {
            self.source = source; self.maxDuration = maxDuration
            self.showTranscriptBeforeSending = showTranscriptBeforeSending
            self.autoSendAfterTranscription = autoSendAfterTranscription
            self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        }
    }
    struct Dependencies {
        let permissions: PermissionService
        let systemPermissions: SystemAudioPermissionController
        let audio: ManualCaptureCapabilities.Audio
        let speech: ManualCaptureCapabilities.Speech
        // Application policy synchronously stops Live and captures its exact
        // existing cleanup handle. This is not a container or audio scheduler.
        let prepareLiveTeardown: @MainActor () -> Task<Void, Never>?
        let feedback: @MainActor (ActionFeedback) -> Void
        let clearFeedback: @MainActor (String) -> Void
        let onReady: @MainActor (String, Configuration) -> Void
    }
    private final class Round {
        let revision: Int
        let configuration: Configuration
        let callbacks = ManualCaptureCallbackRelay()
        var startup: Task<Void, Never>?
        var finalizer: Task<Void, Never>?
        var partials: Task<Void, Never>?
        var controls: Task<Void, Never>?
        init(revision: Int, configuration: Configuration) {
            self.revision = revision
            self.configuration = configuration
        }
    }
    private struct Retirement {
        let id: UUID
        let task: Task<Void, Error>
    }
    let dependencies: Dependencies
    // Commit before notifying a synchronous subscriber. A later intent can
    // publish its replacement without the outer willSet restoring old state.
    private let stateSource = CurrentValueSubject<ManualCaptureState, Never>(.idle)
    var state: ManualCaptureState {
        get { stateSource.value }
        set { stateSource.send(newValue); objectWillChange.send() }
    }
    var stateUpdates: AnyPublisher<ManualCaptureState, Never> { stateSource.eraseToAnyPublisher() }
    @Published var transcript = ""
    private let suggestionSource = CurrentValueSubject<SuggestionCard?, Never>(nil)
    var suggestion: SuggestionCard? {
        get { suggestionSource.value }
        set { suggestionSource.send(newValue); objectWillChange.send() }
    }
    var suggestionUpdates: AnyPublisher<SuggestionCard?, Never> { suggestionSource.eraseToAnyPublisher() }
    @Published private(set) var error: String?
    @Published private(set) var source = ""
    // This is an immutable stopped-round snapshot, not a live metrics mirror.
    @Published private var stoppedMetrics = (count: 0, timestamp: Optional<Date>.none)
    private(set) var revision = 0
    private var current: Round?
    private var retirement: Retirement?
    private var cleanupFailure: Error?
    private var failedAudioStop: ManualCaptureCapabilities.Stop?
    private var closed = false
    private var audioObservation: AnyCancellable?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        audioObservation = dependencies.audio.changes.sink { [weak self] _ in
            // The capability contract publishes synchronously on MainActor.
            // The real recorder already publishes on its MainActor executor.
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }
    var duration: Double { dependencies.audio.duration() }
    var level: Double { dependencies.audio.level() }
    var decibels: Double { dependencies.audio.decibels() }
    var bufferCount: Int { state == .recording ? dependencies.audio.bufferCount() : stoppedMetrics.count }
    var lastBufferTimestamp: Date? {
        state == .recording ? dependencies.audio.lastBufferTimestamp() : stoppedMetrics.timestamp
    }
    var pendingTaskCount: Int {
        [current?.startup, current?.finalizer, current?.partials, current?.controls]
            .compactMap { $0 }.count + (retirement == nil ? 0 : 1)
    }
    var hasUnreleasedResources: Bool {
        pendingTaskCount > 0 || cleanupFailure != nil
            || (current != nil && [.waitingForPermission, .recording, .stopping, .transcribing].contains(state))
    }
    var startupTask: Task<Void, Never>? { current?.startup }
    var finalizationTask: Task<Void, Never>? { current?.finalizer }

    func start(configuration: Configuration) {
        guard !closed else { return }
        if let cleanupFailure {
            let message = "Previous audio cleanup failed: " + cleanupFailure.localizedDescription
            state = .error(message); error = message
            feedback(.error, action: ActionID.manualRecord, title: "Capture failed", message: message)
            return
        }
        revision &+= 1
        let submittedRevision = revision
        retireCurrent()
        guard !closed, revision == submittedRevision, current == nil else { return }
        let prior = retirement
        let round = Round(revision: submittedRevision, configuration: configuration)
        current = round
        state = .waitingForPermission
        guard isCurrent(round) else { return }
        // Reserve this existing round before another owner's pause can publish
        // synchronously and try to reacquire the same audio resources.
        let live = dependencies.prepareLiveTeardown()
        guard isCurrent(round) else { return }
        // Retain the handoff waiter before synchronous feedback can revoke it.
        round.startup = Task { @MainActor [self] in
            defer { round.startup = nil }
            do {
                // A prior failure must not bypass the retained audio handoff.
                await live?.value
                try await prior?.task.value
                try requireCurrent(round)
                try await dependencies.systemPermissions.finishPreparingForCapture()
                try requireCurrent(round)
                if configuration.source == .systemAudio {
                    let result = try await dependencies.systemPermissions.probeNow()
                    try requireCurrent(round)
                    guard SystemAudioPermissionController.state(for: result) == .granted else {
                        throw MaterialError.invalid("System audio permission is required to capture interviewer audio.")
                    }
                } else {
                    let microphone = await dependencies.permissions.requestMicrophonePermission()
                    try requireCurrent(round)
                    dependencies.systemPermissions.refreshPassive()
                    guard microphone == .authorized else {
                        throw MaterialError.invalid("Microphone permission is required to record speech.")
                    }
                }
                let speech = await dependencies.permissions.requestSpeechRecognition()
                try requireCurrent(round)
                dependencies.systemPermissions.refreshPassive()
                guard speech == .granted else {
                    throw MaterialError.invalid("Speech Recognition permission is required for transcription.")
                }
                try await dependencies.systemPermissions.finishPreparingForCapture()
                try requireCurrent(round)
                let relay = round.callbacks
                try await dependencies.speech.startConfigured(
                    requiresOnDeviceRecognition: configuration.requiresOnDeviceRecognition,
                    { relay.partial($0) }, { relay.control(.final($0)) }, { relay.control(.speechError($0)) })
                try requireCurrent(round)
                // Preserve current behavior: live partials are accepted once
                // Speech is initialized, before the bounded recorder starts.
                state = .recording
                try requireCurrent(round)
                try await dependencies.audio.start(configuration.source, configuration.maxDuration,
                    { relay.control(.audioError($0.localizedDescription)) }, { relay.control(.timeout) })
                try requireCurrent(round)
                // A user stop can be requested while SDK startup is suspended.
                // Its finalizer owns the subsequent state/feedback transition.
                if round.finalizer == nil {
                    feedback(.success, action: ActionID.manualRecord, title: "Recording question",
                        message: "Audio capture is active. Stop when the question is complete.")
                }
            } catch is CancellationError {
                if isCurrent(round), round.finalizer == nil {
                    fail("Audio capture startup was cancelled.", round: round, action: ActionID.manualRecord)
                }
            }
            catch {
                if isCurrent(round) { fail(error.localizedDescription, round: round, action: ActionID.manualRecord) }
            }
        }
        feedback(.loading, action: ActionID.manualRecord, title: "Preparing capture",
            message: "Checking permissions and preparing the recorder...")
        guard isCurrent(round) else { return }
        transcript = ""
        guard isCurrent(round) else { return }
        suggestion = nil
        guard isCurrent(round) else { return }
        error = nil
        guard isCurrent(round) else { return }
        stoppedMetrics = (0, nil)
        guard isCurrent(round) else { return }
        source = configuration.source.rawValue
        guard isCurrent(round) else { return }
        round.partials = Task { @MainActor [self] in
            defer { round.partials = nil }
            for await value in round.callbacks.partials.stream {
                guard isCurrent(round), state == .recording || state == .transcribing else { continue }
                transcript = value
            }
        }
        round.controls = Task { @MainActor [self] in
            defer { round.controls = nil }
            for await event in round.callbacks.controls.stream {
                guard isCurrent(round) else { continue }
                switch event {
                case .final(let value):
                    if state == .recording || state == .transcribing { transcript = value }
                case .speechError(let message), .audioError(let message):
                    fail(message, round: round, action: ActionID.manualRecord)
                case .timeout:
                    stopAndTranscribe(maxDurationReached: true)
                }
            }
        }

    }

    func stopAndTranscribe(maxDurationReached: Bool = false) {
        guard let round = current, isCurrent(round), state == .recording, round.finalizer == nil else { return }
        feedback(.loading, action: ActionID.manualStopTranscribe, title: "Transcribing",
            message: "Stopping audio and finalizing the transcript...")
        guard isCurrent(round) else { return }
        state = .stopping
        guard isCurrent(round) else { return }
        // Stop admission immediately and capture this exact recorder epoch.
        // Speech finalization waits until both its startup and native stop exit.
        let stopped = dependencies.audio.stop()
        let startup = round.startup
        stoppedMetrics = (stopped.bufferCount, stopped.lastBufferTimestamp)
        if maxDurationReached { error = "Max recording duration reached" }
        round.finalizer = Task { @MainActor [self] in
            defer { round.finalizer = nil }
            do {
                await startup?.value
                try requireCurrent(round)
                do { try await dependencies.audio.finishStop(stopped.drain) }
                catch { failedAudioStop = stopped.drain; cleanupFailure = error; throw error }
                try requireCurrent(round)
                state = .transcribing
                try requireCurrent(round)
                for buffer in stopped.buffers { dependencies.speech.append(buffer) }
                let text = try await dependencies.speech.finalize(10)
                try requireCurrent(round)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw MaterialError.invalid("No speech detected or transcription failed. Try recording again.")
                }
                dependencies.speech.cancel()
                transcript = trimmed
                try requireCurrent(round)
                state = .transcriptReady
                try requireCurrent(round)
                round.callbacks.close()
                feedback(.success, action: ActionID.manualStopTranscribe, title: "Transcript ready",
                    message: "Review the question and generate an answer.")
                try requireCurrent(round)
                if !round.configuration.showTranscriptBeforeSending && round.configuration.autoSendAfterTranscription {
                    dependencies.onReady(trimmed, round.configuration)
                }
            } catch is CancellationError { }
            catch {
                if isCurrent(round) { fail(error.localizedDescription, round: round, action: ActionID.manualStopTranscribe) }
            }
        }
    }

    @discardableResult
    func cancel() -> Task<Void, Error>? {
        revision &+= 1
        let cancelledRevision = revision
        retireCurrent()
        let cleanup = retirement?.task
        func stillOwnsCancellation() -> Bool {
            revision == cancelledRevision && current == nil && state == .idle
        }
        guard revision == cancelledRevision, current == nil else { return cleanup }
        state = .idle
        guard stillOwnsCancellation() else { return cleanup }
        transcript = ""
        guard stillOwnsCancellation() else { return cleanup }
        suggestion = nil
        guard stillOwnsCancellation() else { return cleanup }
        error = nil
        guard stillOwnsCancellation() else { return cleanup }
        stoppedMetrics = (0, nil)
        guard stillOwnsCancellation() else { return cleanup }
        dependencies.clearFeedback(ActionID.manualRecord)
        guard stillOwnsCancellation() else { return cleanup }
        dependencies.clearFeedback(ActionID.manualStopTranscribe)
        return cleanup
    }
    /// Live adopts the audio resource only after this exact retirement exits.
    /// Completed reviewed text is retained; a pending recording is revoked.
    func prepareForLiveCapture() throws -> Task<Void, Error>? {
        guard !closed else { throw CancellationError() }
        if let cleanupFailure { throw cleanupFailure }
        guard hasUnreleasedResources else { return nil }
        switch state {
        case .waitingForPermission, .recording, .stopping, .transcribing:
            return cancel()
        default:
            revision &+= 1
            retireCurrent()
            return retirement?.task
        }
    }

    func closeAdmission() { closed = true; cancel() }
    func shutdown() async throws {
        closeAdmission()
        if let owned = retirement { try await owned.task.value }
        if let cleanupFailure { throw cleanupFailure }
    }

    private func isCurrent(_ round: Round) -> Bool {
        !closed && current === round && round.revision == revision
    }
    private func requireCurrent(_ round: Round) throws {
        try Task.checkCancellation()
        guard isCurrent(round), cleanupFailure == nil else { throw CancellationError() }
    }
    private func fail(_ message: String, round: Round, action: String) {
        guard isCurrent(round) else { return }
        revision &+= 1
        let failedRevision = revision
        retireCurrent()
        func stillOwnsFailure() -> Bool { !closed && revision == failedRevision && current == nil }
        guard stillOwnsFailure() else { return }
        state = .error(message)
        guard stillOwnsFailure() else { return }
        error = message
        guard stillOwnsFailure() else { return }
        dependencies.clearFeedback(ActionID.manualRecord)
        guard stillOwnsFailure() else { return }
        dependencies.clearFeedback(ActionID.manualStopTranscribe)
        guard stillOwnsFailure() else { return }
        feedback(.error, action: action, title: "Capture failed", message: message)
    }
    private func retireCurrent() {
        guard let round = current else {
            retryFailedCleanupIfNeeded()
            return
        }
        // Snapshot handles before their own completion defers clear fields.
        // Each round has one startup/finalizer and two callback consumers.
        let startup = round.startup, finalizer = round.finalizer
        let partials = round.partials, controls = round.controls
        current = nil
        round.callbacks.close()
        round.startup?.cancel(); round.finalizer?.cancel()
        round.partials?.cancel(); round.controls?.cancel()
        dependencies.speech.cancel()
        let audioStop = dependencies.audio.cancel()
        let previous = retirement
        let id = UUID()
        let task = Task { @MainActor [self] in
            defer { if retirement?.id == id { retirement = nil } }
            var failure: Error?
            do { try await previous?.task.value } catch { failure = error }
            // The first immutable native stop handle owns any SDK startup it
            // captured. Join it before the finalizer, which may await that stop.
            do { try await dependencies.audio.finishStop(audioStop) }
            catch { if let audioStop { failedAudioStop = audioStop }; failure = failure ?? error }
            await startup?.value
            // Startup may acquire recording after cancellation. Capture and
            // join its exact late stop before a replacement can be admitted.
            dependencies.speech.cancel()
            let lateAudioStop = dependencies.audio.cancel()
            do { try await dependencies.audio.finishStop(lateAudioStop) }
            catch { if let lateAudioStop { failedAudioStop = lateAudioStop }; failure = failure ?? error }
            await finalizer?.value
            await partials?.value
            await controls?.value
            if let failure { cleanupFailure = failure; throw failure }
        }
        retirement = .init(id: id, task: task)
    }
    private func retryFailedCleanupIfNeeded() {
        guard retirement == nil, cleanupFailure != nil, let captured = failedAudioStop else { return }
        let id = UUID()
        let task = Task { @MainActor [self] in
            // The task, not a particular waiter, owns matching retirement.
            defer { if retirement?.id == id { retirement = nil } }
            do {
                try await dependencies.audio.retryStop(captured)
                if retirement?.id == id {
                    failedAudioStop = nil
                    cleanupFailure = nil
                }
            } catch {
                if retirement?.id == id { cleanupFailure = error }
                throw error
            }
        }
        retirement = .init(id: id, task: task)
    }
    private func feedback(_ kind: ActionFeedbackKind, action: String, title: String, message: String) {
        dependencies.feedback(.init(actionID: action, title: title, message: message,
            kind: kind, autoDismissAfter: kind == .success ? 4 : nil))
    }
}

/// Partial strings are replaceable UI snapshots. Each native control kind is
/// admitted once, so the bounded four-element queue never drops a control event.
private final class ManualCaptureCallbackRelay: Sendable {
    enum Control: Sendable {
        case final(String), speechError(String), audioError(String), timeout
        var kind: Int {
            switch self { case .final: 0; case .speechError: 1; case .audioError: 2; case .timeout: 3 }
        }
    }
    private struct Admission: Sendable { var open = true; var accepted = Set<Int>() }
    private let admission = OSAllocatedUnfairLock(initialState: Admission())
    let partials = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let controls = AsyncStream<Control>.makeStream(bufferingPolicy: .bufferingOldest(4))
    func partial(_ value: String) {
        admission.withLock { if $0.open { partials.continuation.yield(value) } }
    }
    func control(_ value: Control) {
        admission.withLock {
            guard $0.open, $0.accepted.insert(value.kind).inserted else { return }
            controls.continuation.yield(value)
        }
    }
    func close() {
        admission.withLock {
            $0.open = false
            partials.continuation.finish()
            controls.continuation.finish()
        }
    }
}
