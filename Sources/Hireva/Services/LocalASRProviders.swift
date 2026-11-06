import AVFoundation
import Darwin
import Foundation
import os

enum ASRProviderID: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case appleSpeech
    case localWhisper
    case localParakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech:
            return "Apple Speech"
        case .localWhisper:
            return "Local Whisper"
        case .localParakeet:
            return "Local Parakeet Experimental"
        }
    }

    var source: ASRSource {
        switch self {
        case .appleSpeech:
            return .appleASR
        case .localWhisper:
            return .localWhisperASR
        case .localParakeet:
            return .localParakeetASR
        }
    }
}

struct ASRConfig: Hashable, Sendable {
    let sessionID: String
    let captureMode: AudioCaptureMode
    let requiresOnDeviceRecognition: Bool
    let contextualStrings: [String]

    init(sessionID: String, captureMode: AudioCaptureMode,
        requiresOnDeviceRecognition: Bool = false, contextualStrings: [String] = []) {
        self.sessionID = sessionID
        self.captureMode = captureMode
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        self.contextualStrings = contextualStrings
    }

    static func opportunityTerms(_ opportunity: OpportunityContext?) -> [String] {
        var seen = Set<String>()
        return Array((opportunity?.allEvidence ?? []).filter {
            $0.evidenceType == .requiredSkill || $0.evidenceType == .preferredSkill
        }.map { $0.statement.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            isValidContextualTerm($0) && seen.insert($0.lowercased()).inserted
        }.prefix(32))
    }

    static func isValidContextualTerm(_ term: String) -> Bool {
        !term.isEmpty && term == term.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !term.contains("  ") && term.utf8.count <= 64 && term.split(separator: " ").count <= 4 &&
            term.utf8.contains { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) } &&
            term.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || [32, 39, 45].contains($0) }
    }
}

/// Each implementation owns its lifecycle executor. Immutable metadata stays
/// synchronous; async requirements admit actor and global-actor implementations.
protocol ASRProvider: AnyObject, Sendable {
    var id: ASRProviderID { get }
    var displayName: String { get }
    var capabilities: ASRProviderCapabilities { get }
    func isAvailable() async -> Bool
    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error>
    func stopTranscription() async
}

extension ASRProvider {
    var capabilities: ASRProviderCapabilities {
        .forProvider(id)
    }
}

enum ASRProviderError: LocalizedError, Equatable {
    case modelNotReady(ASRProviderID)
    case localASRRuntimeNotImplemented(ASRProviderID)
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelNotReady(let id):
            return "\(id.displayName) model is not ready."
        case .localASRRuntimeNotImplemented(let id):
            return "\(id.displayName) native helper is unavailable. Repair the bundled runtime before enabling it."
        case .providerUnavailable(let message):
            return message
        }
    }
}

/// The bridge keeps ownership of startup, forwarding and teardown. A retained
/// stream that is abandoned with `break` still requires explicit stop; cancelling
/// its consuming task terminates forwarding and releases the speech session.
@MainActor
protocol AppleSpeechProviderService: AnyObject {
    var segments: AsyncStream<TranscriptSegment> { get }
    var terminalError: Error? { get }
    var captureCleanupFailure: Error? { get }
    func start(sessionID: String, captureMode: AudioCaptureMode) async throws
    func start(sessionID: String, captureMode: AudioCaptureMode,
        requiresOnDeviceRecognition: Bool) async throws
    func stop()
    func stop(retryFailedResource: Bool)
    func finishStoppingAudioInput() async
}

extension AppleSpeechProviderService {
    // Adapters without native PCM keep their existing no-resource contract.
    // The production Speech service supplies the real exact-input drain.
    func finishStoppingAudioInput() async {}
    var captureCleanupFailure: Error? { nil }
    // Existing adapters have no native failed-input contract. The concrete
    // Speech service implements this policy on its retained exact receipt.
    func stop(retryFailedResource: Bool) { stop() }

    // Existing injected adapters preserve normal behavior. An adapter must
    // explicitly implement the new contract before accepting local-only ASR.
    func start(sessionID: String, captureMode: AudioCaptureMode,
        requiresOnDeviceRecognition: Bool) async throws {
        guard !requiresOnDeviceRecognition else {
            throw TranscriptionError.unavailable("This speech adapter has no on-device recognition contract.")
        }
        try await start(sessionID: sessionID, captureMode: captureMode)
    }
}

extension AppleSpeechTranscriptionService: AppleSpeechProviderService {}

@MainActor
final class AppleSpeechASRProvider: ASRProvider {
    nonisolated let id: ASRProviderID = .appleSpeech
    nonisolated let displayName = "Apple Speech"
    static let maximumPendingTranscriptEvents = 64
    static let maximumTranscriptTextBytes = 64 * 1_024
    private let service: any AppleSpeechProviderService
    private var requestedRoundID: UUID?
    // The id is writable only while active. Keep its last exact output alias
    // after retirement so explicit retry cannot adopt another service round.
    private var activeRound: (id: UUID?, output: AppleSpeechTranscriptionService.TranscriptOutput?)?
    private var activeRoundID: UUID? { activeRound?.id }
    private var startupTask: Task<Void, Error>?
    private var bridgeTask: Task<Void, Never>?
    private var outputContinuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?
    private var teardownTask: Task<Void, Never>?
    private var teardownID: UUID?

    #if DEBUG
    var onRoundRequestedForTesting: (@MainActor (UUID) -> Void)?
    #endif

    var captureCleanupFailure: Error? {
        if let speech = service as? AppleSpeechTranscriptionService {
            guard let output = activeRound?.output else { return nil }
            return speech.captureCleanupFailure(capturedOutput: output)
        }
        return service.captureCleanupFailure
    }
    func ownsCurrentSystemAudioCapture(_ capture: ScreenCaptureKitSystemAudioCaptureService) -> Bool {
        guard let speech = service as? AppleSpeechTranscriptionService,
            let output = activeRound?.output, speech.currentTranscriptOutputIdentity == ObjectIdentifier(output) else { return false }
        return speech.ownsCurrentSystemAudioCapture(capture)
    }
    func hasMostRecentSystemAudioCaptureReceipt(_ capture: ScreenCaptureKitSystemAudioCaptureService) -> Bool {
        guard let speech = service as? AppleSpeechTranscriptionService,
            let output = activeRound?.output, speech.currentTranscriptOutputIdentity == ObjectIdentifier(output) else { return false }
        return speech.hasMostRecentSystemAudioCaptureReceipt(capture)
    }
    func ownsSpeechService(_ captured: AppleSpeechTranscriptionService) -> Bool {
        (service as? AppleSpeechTranscriptionService) === captured
    }
    var hasOwnedTranscriptionWork: Bool {
        activeRoundID != nil || startupTask != nil || bridgeTask != nil || teardownTask != nil ||
            captureCleanupFailure != nil
    }

    init(service: (any AppleSpeechProviderService)? = nil) {
        self.service = service ?? AppleSpeechTranscriptionService()
    }

    func isAvailable() async -> Bool { true }

    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        let roundID = UUID()
        // Invalidate before awaiting teardown. Concurrent starts cannot both
        // adopt the shared service after one suspended stop.
        requestedRoundID = roundID
        (service as? AppleSpeechTranscriptionService)?.invalidateSystemAudioTerminalAttribution()
        #if DEBUG
        onRoundRequestedForTesting?(roundID)
        #endif
        retireActiveRound()
        await teardownTask?.value
        guard requestedRoundID == roundID else { throw CancellationError() }
        try Task.checkCancellation()
        if let captureCleanupFailure { throw captureCleanupFailure }
        activeRound = (roundID, nil)
        let startup = Task { @MainActor [weak self, service] in
            try Task.checkCancellation()
            if let speech = service as? AppleSpeechTranscriptionService {
                try await speech.start(sessionID: config.sessionID, captureMode: config.captureMode,
                    requiresOnDeviceRecognition: config.requiresOnDeviceRecognition, onOutputOwned: { output in
                        guard let self, self.activeRoundID == roundID, self.requestedRoundID == roundID else {
                            speech.stop(capturedOutput: output, retryFailedResource: false)
                            return
                        }
                        self.activeRound?.output = output
                    })
            } else {
                try await service.start(sessionID: config.sessionID, captureMode: config.captureMode,
                    requiresOnDeviceRecognition: config.requiresOnDeviceRecognition)
            }
            try Task.checkCancellation()
        }
        startupTask = startup
        do {
            try await withTaskCancellationHandler {
                try await startup.value
            } onCancel: {
                startup.cancel()
            }
            guard activeRoundID == roundID, requestedRoundID == roundID else { throw CancellationError() }
            try Task.checkCancellation()
            startupTask = nil
            let speech = service as? AppleSpeechTranscriptionService
            let ownedOutput = activeRound?.output
            let outputIdentity = ownedOutput.map { ObjectIdentifier($0) }
            guard speech == nil || (outputIdentity != nil && speech?.currentTranscriptOutputIdentity == outputIdentity) else {
                throw CancellationError()
            }
            let upstream = service.segments
            let terminalError = speech?.captureTerminalErrorReader()
            let pair = AsyncThrowingStream<TranscriptSegment, Error>.makeStream(
                bufferingPolicy: .bufferingOldest(Self.maximumPendingTranscriptEvents))
            outputContinuation = pair.continuation
            let bridge = Task { @MainActor [weak self, service] in
                var outputFailure: Error?
                for await segment in upstream {
                    guard !Task.isCancelled, self?.activeRoundID == roundID,
                        (speech == nil || speech?.currentTranscriptOutputIdentity == outputIdentity) else { break }
                    guard segment.text.utf8.count <= Self.maximumTranscriptTextBytes else {
                        outputFailure = ASRProviderError.providerUnavailable(
                            "Apple Speech transcript text exceeded \(Self.maximumTranscriptTextBytes) bytes.")
                        break
                    }
                    if case .dropped = pair.continuation.yield(segment) {
                        // Retain admitted partial/final order, then let this
                        // existing exact bridge stop and drain before error.
                        outputFailure = ASRProviderError.providerUnavailable(
                            "Apple Speech transcript output buffer overflow (\(Self.maximumPendingTranscriptEvents) events).")
                        break
                    }
                }
                guard let self, self.activeRoundID == roundID else {
                    pair.continuation.finish()
                    return
                }
                let upstreamError: Error?
                if let terminalError { upstreamError = terminalError() }
                else { upstreamError = service.terminalError }
                let error = Task.isCancelled ? nil : outputFailure ?? upstreamError
                self.activeRound?.id = nil
                Self.stopOwnedOutput(service: service, output: ownedOutput, retryFailedResource: false)
                await service.finishStoppingAudioInput()
                if self.requestedRoundID == roundID {
                    self.bridgeTask = nil
                    self.outputContinuation = nil
                }
                pair.continuation.finish(throwing: error)
            }
            bridgeTask = bridge
            // This callback can run on any executor. It only cancels the exact
            // retained bridge; owner-isolated cleanup occurs in that bridge.
            pair.continuation.onTermination = { [bridge] termination in
                if case .cancelled = termination { bridge.cancel() }
            }
            return pair.stream
        } catch {
            if activeRoundID == roundID { retireActiveRound() }
            await teardownTask?.value
            throw error
        }
    }

    func waitForCurrentTranscriptionEnd() async {
        let bridge = bridgeTask
        let teardown = teardownTask
        await bridge?.value
        await teardown?.value
    }

    func stopTranscription() async { await stopTranscription(retryFailedResource: true) }

    func stopTranscription(retryFailedResource retryAuthorized: Bool) async {
        let retryFailedResource = retryAuthorized && captureCleanupFailure != nil && teardownTask == nil
        let ownedOutput = activeRound?.output
        requestedRoundID = nil
        retireActiveRound()
        let captured = teardownTask
        await captured?.value
        guard retryFailedResource, captureCleanupFailure != nil else { return }
        if let inFlight = teardownTask { await inFlight.value; return }
        let retry = ownTeardown { [service] in
            Self.stopOwnedOutput(service: service, output: ownedOutput, retryFailedResource: true)
            await service.finishStoppingAudioInput()
        }
        await retry.value
    }

    private func retireActiveRound() {
        guard activeRoundID != nil || startupTask != nil || bridgeTask != nil else { return }
        let startup = startupTask
        let bridge = bridgeTask
        let output = outputContinuation
        let ownedOutput = activeRound?.output
        let previousTeardown = teardownTask
        // Identity invalidation precedes cancellation and synchronous service
        // stop. A late old bridge never calls stop on a new round.
        activeRound?.id = nil
        startupTask = nil
        bridgeTask = nil
        outputContinuation = nil
        startup?.cancel()
        bridge?.cancel()
        output?.finish()
        Self.stopOwnedOutput(service: service, output: ownedOutput, retryFailedResource: false)
        _ = ownTeardown { [service] in
            await previousTeardown?.value
            _ = try? await startup?.value
            // Startup is joined before the second stop and input snapshot;
            // it cannot reacquire a request after cleanup has reported exit.
            Self.stopOwnedOutput(service: service, output: ownedOutput, retryFailedResource: false)
            await service.finishStoppingAudioInput()
            await bridge?.value
        }
    }

    private static func stopOwnedOutput(service: any AppleSpeechProviderService,
        output: AppleSpeechTranscriptionService.TranscriptOutput?, retryFailedResource: Bool) {
        if let speech = service as? AppleSpeechTranscriptionService {
            if let output { speech.stop(capturedOutput: output, retryFailedResource: retryFailedResource) }
            // A cancelled not-yet-issued startup never acquired a service output.
        } else { service.stop(retryFailedResource: retryFailedResource) }
    }

    private func ownTeardown(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        teardownID = id
        let task = Task { @MainActor [self] in
            await operation()
            if teardownID == id { teardownID = nil; teardownTask = nil }
        }
        teardownTask = task
        return task
    }
}

@MainActor
final class LocalPlaceholderASRProvider: ASRProvider {
    nonisolated let id: ASRProviderID
    nonisolated let displayName: String
    private let modelManager: any LocalModelManager
    private let model: LocalModelDescriptor

    init(id: ASRProviderID, model: LocalModelDescriptor, modelManager: any LocalModelManager) {
        self.id = id
        self.displayName = id.displayName
        self.model = model
        self.modelManager = modelManager
    }

    func isAvailable() async -> Bool {
        (await modelManager.modelStatus(model)).isReady
    }

    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        guard await isAvailable() else {
            throw ASRProviderError.modelNotReady(id)
        }
        throw ASRProviderError.providerUnavailable("\(displayName) runtime is not connected yet.")
    }

    func stopTranscription() async {}
}

struct ParakeetTranscriptEvent: Codable, Equatable, Sendable {
    let segmentId: String
    let text: String
    let isFinal: Bool
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let confidence: Double?
    let source: String?
    let audioSource: String?
    let speaker: String?

    init(
        segmentId: String,
        text: String,
        isFinal: Bool,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        confidence: Double? = nil,
        source: String? = ASRSource.localParakeetASR.rawValue,
        audioSource: String? = nil,
        speaker: String? = nil
    ) {
        self.segmentId = segmentId
        self.text = text
        self.isFinal = isFinal
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.source = source
        self.audioSource = audioSource
        self.speaker = speaker
    }
}

struct ParakeetRuntimeDiagnostics: Codable, Hashable, Sendable {
    let runtimeMode: String
    let helperPath: String
    let helperBundled: Bool
    let helperExecutable: Bool
    let helperArchitecture: String
    let runtimeVersion: String
    let sherpaVersion: String
    let onnxRuntimeVersion: String
    let healthStatus: String
    let modelStatus: String
    let lastHealthError: String?

    static func unavailable(path: String = "Not configured", error: String? = nil) -> Self {
        Self(
            runtimeMode: "unavailable",
            helperPath: path,
            helperBundled: false,
            helperExecutable: false,
            helperArchitecture: "unknown",
            runtimeVersion: "unknown",
            sherpaVersion: "unknown",
            onnxRuntimeVersion: "unknown",
            healthStatus: "failed",
            modelStatus: "not_probed",
            lastHealthError: error
        )
    }
}

protocol ParakeetRuntimeClient: AnyObject {
    @MainActor func isRuntimeAvailable() async -> Bool
    @MainActor func runtimeDiagnostics() async -> ParakeetRuntimeDiagnostics
    @MainActor var audioWriterSnapshot: ParakeetAudioWriterDiagnostics? { get }
    @MainActor var cleanupFailure: Error? { get }
    @MainActor func probeModel(at modelDirectory: URL) async -> Bool
    @MainActor func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error>
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType)
    @MainActor func stop() async
}

extension ParakeetRuntimeClient {
    // Adapters without a bounded writer must report unavailable, not zero loss.
    @MainActor var audioWriterSnapshot: ParakeetAudioWriterDiagnostics? { nil }
    @MainActor var cleanupFailure: Error? { nil }

    @MainActor func runtimeDiagnostics() async -> ParakeetRuntimeDiagnostics {
        let available = await isRuntimeAvailable()
        return available
            ? ParakeetRuntimeDiagnostics(
                runtimeMode: "test_or_legacy",
                helperPath: "Injected runtime",
                helperBundled: false,
                helperExecutable: true,
                helperArchitecture: "unknown",
                runtimeVersion: "unknown",
                sherpaVersion: "unknown",
                onnxRuntimeVersion: "unknown",
                healthStatus: "ok",
                modelStatus: "not_probed",
                lastHealthError: nil
            )
            : .unavailable(error: "Runtime health check failed")
    }

    @MainActor func probeModel(at modelDirectory: URL) async -> Bool {
        await isRuntimeAvailable()
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType) {
        appendAudioBuffer(buffer, at: time)
    }
}

enum ParakeetSidecarError: LocalizedError, Equatable {
    case executableNotConfigured
    case launchFailed(String)
    case invalidEvent(String)
    case exited(Int32)
    case healthCheckFailed(String)
    case outputLineTooLong(channel: String, maximumBytes: Int)
    case transcriptBufferOverflow(maximumEvents: Int)
    case transcriptTooLarge(maximumBytes: Int)
    case outputReaderCleanupIncomplete
    case resourceCleanupIncomplete

    var errorDescription: String? {
        switch self {
        case .executableNotConfigured:
            return "Parakeet sidecar executable is not configured."
        case .launchFailed(let message):
            return "Parakeet sidecar failed to launch: \(message)"
        case .invalidEvent(let line):
            return "Parakeet sidecar emitted invalid transcript JSON: \(line)"
        case .exited(let code):
            return "Parakeet sidecar exited with code \(code)."
        case .healthCheckFailed(let message):
            return "Parakeet runtime health check failed: \(message)"
        case .outputLineTooLong(let channel, let maximumBytes):
            return "Parakeet \(channel) line exceeded \(maximumBytes) bytes."
        case .transcriptBufferOverflow(let maximumEvents):
            return "Parakeet transcript output buffer overflow (\(maximumEvents) events)."
        case .transcriptTooLarge(let maximumBytes):
            return "Parakeet transcript text exceeded \(maximumBytes) bytes."
        case .outputReaderCleanupIncomplete:
            return "Parakeet output readers did not fully drain after helper exit."
        case .resourceCleanupIncomplete:
            return "Parakeet helper resources or contextual vocabulary have not been fully released. Retry cleanup before starting."
        }
    }
}

struct ParakeetAudioWriterDiagnostics: Equatable, Sendable {
    let maximumPendingChunks: Int
    let maximumPendingBytes: Int
    let pendingChunks: Int
    let pendingBytes: Int
    let droppedChunks: Int
}

private final class ParakeetLineBuffer: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: Data())
    private let channel: String
    init(channel: String) { self.channel = channel }

    func append(_ data: Data) throws -> [String] {
        try pending.withLock { pending in
            var lines: [String] = []
            var cursor = data.startIndex
            while cursor < data.endIndex {
                let end = data[cursor...].firstIndex(of: 0x0A) ?? data.endIndex
                let fragment = data[cursor..<end]
                // Check before copying. A chunk may contain several complete
                // lines; only the unfinished line consumes this fixed budget.
                guard fragment.count <= ParakeetSidecarRuntimeClient.maximumOutputLineBytes - pending.count else {
                    pending.removeAll(keepingCapacity: false)
                    throw ParakeetSidecarError.outputLineTooLong(channel: channel,
                        maximumBytes: ParakeetSidecarRuntimeClient.maximumOutputLineBytes)
                }
                pending.append(contentsOf: fragment)
                if end < data.endIndex {
                    lines.append(String(decoding: pending, as: UTF8.self))
                    pending.removeAll(keepingCapacity: true)
                    cursor = data.index(after: end)
                } else { cursor = end }
            }
            return lines
        }
    }

    func finish() -> [String] {
        pending.withLock { pending in
            guard !pending.isEmpty else { return [] }
            let line = String(decoding: pending, as: UTF8.self)
            pending.removeAll(keepingCapacity: false)
            return [line]
        }
    }
}

private final class ParakeetOutputStreamState: Sendable {
    private struct TerminalState: Sendable {
        var finished = false
        var stdoutEOF = false
        var stderrEOF = false
        var exitStatus: Int32?
    }
    private let terminal = OSAllocatedUnfairLock(initialState: TerminalState())
    private let buffer = ParakeetLineBuffer(channel: "stdout")
    private let stderrBuffer = ParakeetLineBuffer(channel: "stderr")
    private let continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation

    enum ReaderChannel: Sendable { case stdout, stderr }
    private struct ReaderLifetime: Sendable {
        var admissionClosed = false
        var stdoutCallbacks = 0
        var stderrCallbacks = 0
        // Only the sole exact Process cleanup task calls finishReadCallbacks;
        // concurrent stop callers join that task instead of adding waiters.
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let readers = OSAllocatedUnfairLock(initialState: ReaderLifetime())

    // Admission covers the entire native callback, including parsing, error
    // completion and the nil-default checkpoint. No FileHandle borrow may
    // begin after this output's cleanup seals admission.
    func beginReadCallback(_ channel: ReaderChannel) -> Bool {
        readers.withLock { state in
            guard !state.admissionClosed else { return false }
            switch channel {
            case .stdout: state.stdoutCallbacks += 1
            case .stderr: state.stderrCallbacks += 1
            }
            return true
        }
    }

    func endReadCallback(_ channel: ReaderChannel) {
        let ready = readers.withLock { state -> CheckedContinuation<Void, Never>? in
            switch channel {
            case .stdout: state.stdoutCallbacks -= 1
            case .stderr: state.stderrCallbacks -= 1
            }
            guard state.admissionClosed, state.stdoutCallbacks == 0,
                  state.stderrCallbacks == 0 else { return nil }
            let ready = state.waiter
            state.waiter = nil
            return ready
        }
        ready?.resume()
    }

    func closeReadAdmission() {
        readers.withLock { $0.admissionClosed = true }
    }

    func finishReadCallbacks(didWait: (@Sendable () -> Void)?) async {
        await withCheckedContinuation { continuation in
            let waiting = readers.withLock { state in
                guard state.stdoutCallbacks != 0 || state.stderrCallbacks != 0 else { return false }
                precondition(state.waiter == nil, "Only the exact Process cleanup may drain its readers.")
                state.waiter = continuation
                return true
            }
            // Test notification and continuation resumption occur outside the
            // ordinary lock. Cancellation does not claim an SDK borrow ended.
            if waiting { didWait?() }
            else { continuation.resume() }
        }
    }

    init(continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func receive(_ data: Data, from handle: FileHandle) {
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            buffer.finish().forEach(emit)
            // EOF closes one channel only. The process and the other pipe
            // may still produce a failure, so it cannot establish success.
            recordEOF(.stdout)
            return
        }
        guard !isFinished else { return }
        do { try buffer.append(data).forEach(emit) }
        catch { finish(error) }
    }

    func receiveStderr(_ data: Data, from handle: FileHandle,
        configurationContext: (sessionID: String, captureMode: String, helperPID: Int32, generation: Int)? = nil) {
        func record(_ line: String) {
            print("[ParakeetSidecar] stderr characters=\(line.count)")
            guard !isFinished, let context = configurationContext,
                  let json = ParakeetSidecarRuntimeClient.redactedConfigurationAcknowledgement(
                    line, sessionID: context.sessionID, captureMode: context.captureMode, helperPID: context.helperPID) else { return }
            print("[ParakeetSidecar] recognizer_config generation=\(context.generation) \(json)")
        }
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            for line in stderrBuffer.finish() where !line.isEmpty {
                record(line)
            }
            recordEOF(.stderr)
            return
        }
        // Native reads still drain a failed helper, but no more diagnostics or
        // business values are admitted after its one-shot failure.
        guard !isFinished else { return }
        do {
            for line in try stderrBuffer.append(data) where !line.isEmpty {
                record(line)
            }
        } catch { finish(error) }
    }

    func recordProcessExit(_ status: Int32) {
        completeNormallyIfReady { $0.exitStatus = status }
    }

    private func recordEOF(_ channel: ReaderChannel) {
        completeNormallyIfReady { state in
            switch channel {
            case .stdout: state.stdoutEOF = true
            case .stderr: state.stderrEOF = true
            }
        }
    }

    private func completeNormallyIfReady(_ update: @Sendable (inout TerminalState) -> Void) {
        let status = terminal.withLock { state -> Int32? in
            update(&state)
            guard !state.finished, state.stdoutEOF, state.stderrEOF,
                  let status = state.exitStatus else { return nil }
            state.finished = true
            return status
        }
        guard let status else { return }
        // Continuation termination invokes the existing exact Process owner,
        // outside this lock. Failure and completion stay one-shot.
        if status == 0 { continuation.finish() }
        else { continuation.finish(throwing: ParakeetSidecarError.exited(status)) }
    }

    private func emit(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let event = try? JSONDecoder().decode(ParakeetTranscriptEvent.self, from: data) else {
            finish(ParakeetSidecarError.invalidEvent(line))
            return
        }
        guard !isFinished else { return }
        if case .dropped = continuation.yield(event) {
            // An accepted final remains buffered in order. The rejected next
            // event is an explicit failure, never silent transcript loss.
            finish(ParakeetSidecarError.transcriptBufferOverflow(
                maximumEvents: ParakeetSidecarRuntimeClient.maximumPendingTranscriptEvents))
        }
    }

    var isFinished: Bool { terminal.withLock { $0.finished } }

    func finish(_ error: Error? = nil) {
        let admitted = terminal.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            return true
        }
        guard admitted else { return }
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}

final class ParakeetSidecarRuntimeClient: ParakeetRuntimeClient, Sendable {
    static let sidecarPathDefaultsKey = HirevaPreferenceKeys.parakeetSidecarPath
    static let maximumPendingAudioChunks = 2_048
    static let maximumPendingAudioBytes = 8 * 1_024 * 1_024
    static let maximumOutputReadBytes = 64 * 1_024
    // Cleanup owns these exact exited pipe handles after joining callbacks.
    // This is a finite work budget, not an assumption about OS pipe capacity.
    static let maximumOutputDrainReads = 16
    static let maximumOutputLineBytes = 64 * 1_024
    static let maximumPendingTranscriptEvents = 64
    static let maximumTranscriptTextBytes = 64 * 1_024

    private struct HelperHealth: Decodable {
        let status: String
        let runtimeMode: String
        let runtimeVersion: String
        let sherpaVersion: String
        let onnxRuntimeVersion: String
        let architecture: String
        let source: String
        let modelStatus: String
    }

    private struct MonoAudioSnapshot: Sendable {
        let samples: Data
        let sampleRate: Double
    }

    // Lookup is constructed and invoked only by the runtime control executor.
    @MainActor private let executableURLProvider: () -> URL?
    @MainActor private let runtimeCompatibilityError: (URL) -> String?
    private let healthCheckDelayProvider: any DelayProvider
    private let healthCheckDiagnosticsObserver: (@Sendable (ParakeetRuntimeDiagnostics) -> Void)?
    private let audioWriteAdmissionHook: (@Sendable () -> Void)?
    private let audioSerializationCheckpoint: (@Sendable () -> Void)?
    // Nil in product construction; exposes only copied read counts/identity to
    // deterministic paused-consumer tests, never helper text or native buffers.
    private let outputReadCheckpoint: (@Sendable (Int, String, Int, Bool) -> Void)?
    // Nil by default; observes registration of an exact callback drain waiter.
    private let outputReaderDrainDidWait: (@Sendable (Int) -> Void)?
    private let vocabularyRoot: URL
    typealias VerificationPCMCommit = @Sendable (Data, Int, Bool, ParakeetAudioWriterDiagnostics) throws -> Void
    private let verificationPCMCommit: VerificationPCMCommit?
    private let verificationPCMIsCurrent: @Sendable () -> Bool
    private let verificationPCMConsent = PersistenceConsent()
    static let maximumVerificationPCMBytes = 32 * 1024 * 1024
    static let maximumVerificationPCMRecords = 4096
    private struct InputState: Sendable {
        var process: Process?
        var processGeneration: Int?
        var stdinHandle: FileHandle?
        var stdoutHandle: FileHandle?
        var stderrHandle: FileHandle?
        var outputState: ParakeetOutputStreamState?
        var vocabularyDirectory: URL?
        var cleanupTask: Task<Void, Never>?
        var acceptsAudio = false
        var streamGeneration = 0
        var audioSequence = 0
        var pendingAudioChunks = 0
        var pendingAudioBytes = 0
        var droppedAudioChunks = 0
        var verificationPCM: Data?
        var verificationPCMRecords = 0
        var verificationPCMTruncated = false
    }
    private let inputState = OSAllocatedUnfairLock(initialState: InputState())
    private let inputQueue = DispatchQueue(label: "com.langcheng.hireva.parakeet.sidecar.stdin")

    @MainActor
    init(executableURLProvider: @escaping () -> URL? = {
        ParakeetSidecarRuntimeClient.discoverExecutable(
            bundleURL: Bundle.main.bundleURL,
            environment: ProcessInfo.processInfo.environment,
            storedDevelopmentPath: UserDefaults.standard.string(forKey: sidecarPathDefaultsKey),
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            allowDevelopmentOverrides: _isDebugAssertConfiguration()
        )
    }, runtimeCompatibilityError: @escaping (URL) -> String? = {
        ParakeetSidecarRuntimeClient.bundledRuntimeCompatibilityError(executableURL: $0,
            bundleURL: Bundle.main.bundleURL, operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }, audioWriteAdmissionHook: (@Sendable () -> Void)? = nil,
       audioSerializationCheckpoint: (@Sendable () -> Void)? = nil,
       healthCheckDelayProvider: any DelayProvider = RealDelayProvider(),
       healthCheckDiagnosticsObserver: (@Sendable (ParakeetRuntimeDiagnostics) -> Void)? = nil,
       outputReadCheckpoint: (@Sendable (Int, String, Int, Bool) -> Void)? = nil,
       outputReaderDrainDidWait: (@Sendable (Int) -> Void)? = nil,
       vocabularyRoot: URL? = nil,
       verificationPCMCommit: VerificationPCMCommit? = nil,
       verificationPCMIsCurrent: @escaping @Sendable () -> Bool = { true }) {
        self.executableURLProvider = executableURLProvider
        self.runtimeCompatibilityError = runtimeCompatibilityError
        self.healthCheckDelayProvider = healthCheckDelayProvider
        self.healthCheckDiagnosticsObserver = healthCheckDiagnosticsObserver
        self.audioWriteAdmissionHook = audioWriteAdmissionHook
        self.audioSerializationCheckpoint = audioSerializationCheckpoint
        self.outputReadCheckpoint = outputReadCheckpoint
        self.outputReaderDrainDidWait = outputReaderDrainDidWait
        self.vocabularyRoot = vocabularyRoot ?? HirevaVerificationConfiguration.current?.applicationSupportDirectory ?? FileManager.default.temporaryDirectory
        self.verificationPCMCommit = verificationPCMCommit
        self.verificationPCMIsCurrent = verificationPCMIsCurrent
    }

    static func bundledRuntimeCompatibilityError(executableURL: URL, bundleURL: URL,
        operatingSystemVersion: OperatingSystemVersion) -> String? {
        let bundled = bundleURL.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
        guard executableURL.isFileURL, bundleURL.isFileURL,
              executableURL.standardizedFileURL.absoluteURL == bundled.standardizedFileURL.absoluteURL else { return nil }
        guard operatingSystemVersion.majorVersion < 15 ||
              (operatingSystemVersion.majorVersion == 15 && operatingSystemVersion.minorVersion < 5) else { return nil }
        // dyld loads the bundled ONNX dependency before the helper can report health.
        return "Bundled Native Parakeet requires macOS 15.5 or later because its ONNX Runtime dependency loads before startup. This ASR backend is unavailable on this system."
    }

    static func discoverExecutable(
        bundleURL: URL,
        environment: [String: String],
        storedDevelopmentPath: @autoclosure () -> String?,
        currentDirectory: URL,
        allowDevelopmentOverrides: Bool,
        verificationConfiguration: HirevaVerificationConfiguration? = .current,
        fileManager: FileManager = .default
    ) -> URL? {
        let bundled = bundleURL.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        guard allowDevelopmentOverrides, verificationConfiguration == nil else { return nil }

        for key in ["PARAKEET_ASR_HELPER_PATH", "PARAKEET_ASR_SIDECAR_PATH"] {
            if let path = environment[key], !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        if let storedDevelopmentPath = storedDevelopmentPath(), !storedDevelopmentPath.isEmpty {
            return URL(fileURLWithPath: storedDevelopmentPath)
        }
        let developmentHelper = currentDirectory
            .appendingPathComponent(".build/parakeet-helper/Helpers/parakeet_asr_helper")
        if fileManager.isExecutableFile(atPath: developmentHelper.path) {
            return developmentHelper
        }
        let legacyBundled = bundleURL.appendingPathComponent("Contents/Resources/parakeet_asr_sidecar")
        if fileManager.isExecutableFile(atPath: legacyBundled.path) {
            return legacyBundled
        }
        return nil
    }

    @MainActor func isRuntimeAvailable() async -> Bool {
        (await runtimeDiagnostics()).healthStatus == "ok"
    }

    @MainActor func runtimeDiagnostics() async -> ParakeetRuntimeDiagnostics {
        guard !Task.isCancelled else { return .unavailable(error: "Health check cancelled") }
        guard let executableURL = executableURLProvider() else {
            return .unavailable(error: "Bundled native Parakeet helper is missing")
        }
        let executable = FileManager.default.isExecutableFile(atPath: executableURL.path)
        guard executable else {
            return .unavailable(path: executableURL.path, error: "Helper is not executable")
        }
        if let error = runtimeCompatibilityError(executableURL) {
            let diagnostics = ParakeetRuntimeDiagnostics.unavailable(path: executableURL.path, error: error)
            healthCheckDiagnosticsObserver?(diagnostics)
            return diagnostics
        }
        let diagnostics = await Self.runHealthCheck(executableURL: executableURL, arguments: ["--health"], timeout: 3,
            delayProvider: healthCheckDelayProvider)
        healthCheckDiagnosticsObserver?(diagnostics)
        return diagnostics
    }

    @MainActor func probeModel(at modelDirectory: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let executableURL = executableURLProvider(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return false
        }
        guard runtimeCompatibilityError(executableURL) == nil else { return false }
        let diagnostics = await Self.runHealthCheck(
            executableURL: executableURL,
            arguments: ["--health", "--probe-model", "--model-dir", modelDirectory.path],
            timeout: 15,
            delayProvider: healthCheckDelayProvider
        )
        return diagnostics.healthStatus == "ok" && diagnostics.modelStatus == "ready"
    }

    @MainActor func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        guard let executableURL = executableURLProvider(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ParakeetSidecarError.executableNotConfigured
        }
        try Task.checkCancellation()
        if let error = runtimeCompatibilityError(executableURL) {
            throw ParakeetSidecarError.healthCheckFailed(error)
        }
        await stop()
        if let cleanupFailure { throw cleanupFailure }
        try withInputStateLock { state in
            guard state.process == nil, state.vocabularyDirectory == nil else {
                throw ParakeetSidecarError.launchFailed("The previous Parakeet helper has not fully exited and drained.")
            }
        }

        guard config.contextualStrings.count <= 32,
              config.contextualStrings.allSatisfy(ASRConfig.isValidContextualTerm) else {
            throw ParakeetSidecarError.launchFailed("Invalid contextual vocabulary; use at most 32 short English terms.")
        }
        let vocabularyDirectory: URL?
        if !config.contextualStrings.isEmpty {
            let directory = vocabularyRoot.appendingPathComponent("ParakeetVocabulary-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            vocabularyDirectory = directory
            guard FileManager.default.createFile(atPath: directory.appendingPathComponent("hotwords.txt").path,
                contents: Data((config.contextualStrings.joined(separator: "\n") + "\n").utf8),
                attributes: [.posixPermissions: 0o600]) else {
                discardUnlaunchedVocabulary(directory)
                throw ParakeetSidecarError.launchFailed("Could not prepare contextual vocabulary.")
            }
        } else { vocabularyDirectory = nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--model-dir", modelDirectory.path,
            "--session-id", config.sessionID,
            "--capture-mode", config.captureMode.rawValue,
            "--jsonl"
        ]
        if let vocabularyDirectory {
            process.arguments! += ["--decoding-method", "modified_beam_search",
                "--hotwords-file", vocabularyDirectory.appendingPathComponent("hotwords.txt").path,
                "--bpe-vocab", vocabularyDirectory.appendingPathComponent("bpe.vocab").path,
                "--approximate-bpe-vocab", "--hotwords-score", "2.5"]
        }
        process.environment = Self.minimalRuntimeEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        let output = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maximumPendingTranscriptEvents))
        let outputState = ParakeetOutputStreamState(continuation: output.continuation)
        // Register before launch, while neither EOF has been observed. The
        // termination callback cannot finish the stream under InputState's lock.
        process.terminationHandler = { process in
            outputState.recordProcessExit(process.terminationStatus)
        }

        let generation: Int
        do {
            try Self.configureOutputReader(stdout.fileHandleForReading)
            try Self.configureOutputReader(stderr.fileHandleForReading)
            generation = try withInputStateLock { state in
                // Launch and registration are one synchronous ownership change.
                // Competing starts cannot overwrite an owned process or adopt
                // a helper whose previous cleanup did not complete.
                guard state.process == nil else {
                    throw ParakeetSidecarError.launchFailed("The previous Parakeet helper has not fully exited and drained.")
                }
                try Task.checkCancellation()
                try process.run()
                _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                state.streamGeneration += 1
                state.audioSequence = 0
                state.droppedAudioChunks = 0
                state.acceptsAudio = true
                state.process = process
                state.processGeneration = state.streamGeneration
                state.stdinHandle = stdin.fileHandleForWriting
                state.stdoutHandle = stdout.fileHandleForReading
                state.stderrHandle = stderr.fileHandleForReading
                state.outputState = outputState
                state.vocabularyDirectory = vocabularyDirectory
                state.verificationPCM = verificationPCMCommit != nil && config.captureMode == .systemAudioOnly ? Data() : nil
                state.verificationPCMRecords = 0
                state.verificationPCMTruncated = false
                return state.streamGeneration
            }
        } catch is CancellationError {
            process.terminationHandler = nil
            outputState.finish(CancellationError())
            if let vocabularyDirectory { discardUnlaunchedVocabulary(vocabularyDirectory) }
            throw CancellationError()
        } catch {
            process.terminationHandler = nil
            outputState.finish(error)
            if let vocabularyDirectory { discardUnlaunchedVocabulary(vocabularyDirectory) }
            throw ParakeetSidecarError.launchFailed(error.localizedDescription)
        }

        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        let outputReadCheckpoint = self.outputReadCheckpoint
        let configurationContext = VerificationTiming.enabled
            ? (sessionID: config.sessionID, captureMode: config.captureMode.rawValue,
                helperPID: process.processIdentifier, generation: generation) : nil
        output.continuation.onTermination = { [weak self] _ in
            // Register cleanup synchronously. Later explicit stop/start
            // joins this owned task even after the output stream ends.
            _ = self?.beginStop(generation: generation)
        }
        let attached = withInputStateLock { state in
            guard state.process === process, state.processGeneration == generation, state.acceptsAudio else { return false }
            stdoutHandle.readabilityHandler = { [weak self] handle in
                guard outputState.beginReadCallback(.stdout) else { return }
                defer { outputState.endReadCallback(.stdout) }
                do {
                    guard let data = try Self.readAvailableOutput(handle) else { return }
                    outputState.receive(data, from: handle)
                    outputReadCheckpoint?(generation, "stdout", data.count, outputState.isFinished)
                    if data.isEmpty {
                        // Request exact owned cleanup at stdout EOF without
                        // declaring business success. Some helpers wait for the
                        // stop command before closing stderr or exiting.
                        _ = self?.beginStop(generation: generation)
                    }
                } catch { outputState.finish(error) }
            }
            stderrHandle.readabilityHandler = { handle in
                guard outputState.beginReadCallback(.stderr) else { return }
                defer { outputState.endReadCallback(.stderr) }
                var bytesRead: Int?
                defer {
                    if let bytesRead {
                        outputReadCheckpoint?(generation, "stderr", bytesRead, outputState.isFinished)
                    }
                }
                do {
                    guard let data = try Self.readAvailableOutput(handle) else { return }
                    bytesRead = data.count
                    outputState.receiveStderr(data, from: handle, configurationContext: configurationContext)
                } catch { outputState.finish(error) }
            }
            return true
        }
        if !attached { outputState.finish() }
        return output.stream
    }

    // Accept only the helper's public submitted-config scalars; never raw stderr.
    static func redactedConfigurationAcknowledgement(_ line: String, sessionID: String,
        captureMode: String, helperPID: Int32) -> String? {
        let expected: [String: LocalJSONValue] = [
            "type": .string("recognizer_configuration"), "schemaVersion": .number(1),
            "configurationScope": .string("submitted_after_successful_create"), "creationSucceeded": .boolean(true),
            "sessionID": .string(sessionID), "captureMode": .string(captureMode),
            "helperPID": .number(Double(helperPID)), "modelType": .string("nemo_transducer"), "maxActivePaths": .number(4)]
        let variableKeys = ["decodingMethod", "numThreads", "modelingUnit", "hotwordsScore",
            "hasHotwordsConfiguration", "hasBPEVocabulary"]
        guard helperPID > 0, line.utf8.count <= 2_048, let data = line.data(using: .utf8),
              case let .object(fields)? = try? JSONDecoder().decode(LocalJSONValue.self, from: data),
              Set(fields.keys) == Set(expected.keys).union(variableKeys),
              expected.allSatisfy({ fields[$0.key] == $0.value }),
              case let .string(method)? = fields["decodingMethod"], ["greedy_search", "modified_beam_search"].contains(method),
              case let .number(threads)? = fields["numThreads"], threads.isFinite,
              threads >= 1, threads <= Double(Int32.max), threads.rounded(.towardZero) == threads,
              case let .number(score)? = fields["hotwordsScore"], score.isFinite, (0...3).contains(score),
              case let .boolean(biased)? = fields["hasHotwordsConfiguration"],
              fields["hasBPEVocabulary"] == .boolean(biased),
              fields["modelingUnit"] == (biased ? .string("bpe") : .null),
              biased ? method == "modified_beam_search" : score == 0,
              let safeData = try? JSONEncoder().encode(LocalJSONValue.object(fields)),
              safeData.count <= 2_048 else { return nil }
        return String(data: safeData, encoding: .utf8)
    }

    private static func configureOutputReader(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// One bounded syscall per readability callback. Foundation's synchronous
    /// read(upToCount:) can wait to fill its count while a live helper keeps the
    /// pipe open. A temporary lack of bytes is distinct from an actual EOF.
    private static func readAvailableOutput(_ handle: FileHandle) throws -> Data? {
        var data = Data(count: maximumOutputReadBytes)
        let count = data.withUnsafeMutableBytes { bytes in
            Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count >= 0 {
            data.count = count
            return data
        }
        let failure = errno
        if failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        appendAudioBuffer(buffer, at: time, source: .systemAudio)
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType) {
        // This SDK borrow is bounded before allocation and never escapes the
        // callback. Registration shares one lock with epoch invalidation, so a
        // stop command cannot overtake a snapshot that was accepted here.
        let admitted = inputState.withLockUnchecked { state in
            guard state.acceptsAudio, let stdinHandle = state.stdinHandle,
                  buffer.floatChannelData != nil, buffer.frameLength > 0 else { return false }
            guard let byteBudget = Self.audioWriteByteBudget(frameLength: Int(buffer.frameLength),
                      channelCount: Int(buffer.format.channelCount)),
                  state.pendingAudioChunks < Self.maximumPendingAudioChunks,
                  state.pendingAudioBytes <= Self.maximumPendingAudioBytes - byteBudget else {
                state.droppedAudioChunks += 1
                return false
            }
            guard let snapshot = Self.monoAudioSnapshot(from: buffer) else { return false }
            state.audioSequence += 1
            let sequence = state.audioSequence
            let generation = state.streamGeneration
            state.pendingAudioChunks += 1
            state.pendingAudioBytes += byteBudget
            // Only immutable samples/metadata and the exact owned handle enter
            // the writer. Base64, JSON and pipe writes run outside every lock.
            inputQueue.async { [self] in
                defer { self.releaseAudioWrite(byteCount: byteBudget) }
                guard let audioEvent = Self.audioEventData(from: snapshot, sequence: sequence, source: source,
                          serializationCheckpoint: audioSerializationCheckpoint) else {
                    recordDroppedAudioChunk()
                    return
                }
                var audioLine = audioEvent
                audioLine.append(0x0A)
                guard audioLine.count <= byteBudget else {
                    recordDroppedAudioChunk()
                    return
                }
                do {
                    try stdinHandle.write(contentsOf: audioLine)
                    retainVerificationPCM(audioLine, generation: generation, input: stdinHandle, source: source)
                } catch {
                    let currentStreamStillOwnsInput = self.withInputStateLock {
                        $0.acceptsAudio && generation == $0.streamGeneration
                    }
                    if currentStreamStillOwnsInput {
                        print("[ParakeetSidecar] Failed to write audio chunk: code=\((error as NSError).code)")
                    }
                }
            }
            return true
        }
        // This hook observes completed queue admission, not a tentative slot.
        if admitted { audioWriteAdmissionHook?() }
    }

    @MainActor func stop() async {
        await beginStop(generation: nil)?.value
    }

    func revokeVerificationPCM() {
        verificationPCMConsent.invalidate()
        withInputStateLock { $0.verificationPCM = nil }
    }

    private func retainVerificationPCM(_ line: Data, generation: Int, input: FileHandle, source: AudioSourceType) {
        guard verificationPCMCommit != nil, source == .systemAudio else { return }
        guard verificationPCMIsCurrent() else { revokeVerificationPCM(); return }
        try? verificationPCMConsent.write(ticket: 0) {
            withInputStateLock { state in
                // Stop revokes stream admission; already submitted bytes still belong to this process.
                guard state.processGeneration == generation, state.stdinHandle === input,
                      state.verificationPCM != nil, !state.verificationPCMTruncated else { return }
                guard state.verificationPCMRecords < Self.maximumVerificationPCMRecords,
                      line.count <= Self.maximumVerificationPCMBytes - (state.verificationPCM?.count ?? 0) else {
                    state.verificationPCMTruncated = true
                    return
                }
                state.verificationPCM?.append(line)
                state.verificationPCMRecords += 1
            }
        }
    }

    private func finishVerificationPCM(generation: Int, process: Process) {
        guard let commit = verificationPCMCommit else { return }
        do {
            try verificationPCMConsent.write(ticket: 0) {
                let retained = withInputStateLock { state -> (Data, Bool)? in
                    guard state.processGeneration == generation, state.process === process,
                          let data = state.verificationPCM else { return nil }
                    state.verificationPCM = nil
                    return (data, state.verificationPCMTruncated)
                }
                guard let (data, truncated) = retained, !data.isEmpty else { return }
                try commit(data, generation, truncated, audioWriterDiagnostics())
            }
        } catch is CancellationError {
            print("[VerificationPCM] discarded revoked generation=\(generation)")
        } catch {
            print("[VerificationPCM] commit failed generation=\(generation) code=\((error as NSError).code)")
        }
    }

    @MainActor var cleanupFailure: Error? {
        withInputStateLock { state in
            !state.acceptsAudio && state.cleanupTask == nil &&
                (state.process != nil || state.vocabularyDirectory != nil)
                ? ParakeetSidecarError.resourceCleanupIncomplete : nil
        }
    }

    private func discardUnlaunchedVocabulary(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { withInputStateLock { $0.vocabularyDirectory = directory } }
    }

    private func beginStop(generation ownerGeneration: Int?) -> Task<Void, Never>? {
        withInputStateLock { state in
            if let ownerGeneration, ownerGeneration != state.processGeneration { return nil }
            if let cleanupTask = state.cleanupTask { return cleanupTask }
            guard let stoppingProcess = state.process, let generation = state.processGeneration else {
                guard let directory = state.vocabularyDirectory else { return nil }
                let cleanup = Task { [self] in
                    discardUnlaunchedVocabulary(directory)
                    let removed = !FileManager.default.fileExists(atPath: directory.path)
                    withInputStateLock { state in
                        if state.process == nil, state.vocabularyDirectory == directory, removed {
                            state.vocabularyDirectory = nil
                        }
                        state.cleanupTask = nil
                    }
                }
                state.cleanupTask = cleanup
                return cleanup
            }
            state.acceptsAudio = false
            state.streamGeneration += 1
            let stoppingInput = state.stdinHandle
            let stoppingOutput = state.stdoutHandle
            let stoppingError = state.stderrHandle
            let stoppingVocabulary = state.vocabularyDirectory
            let cleanup = Task { [self] in
                let exited = await stopOwnedProcess(stoppingProcess, input: stoppingInput)
                let drained = exited ? await waitForInputDrain() : false
                var outputDrained = false
                if exited && drained {
                    let output = withInputStateLock { $0.processGeneration == generation ? $0.outputState : nil }
                    output?.closeReadAdmission()
                    stoppingOutput?.readabilityHandler = nil
                    stoppingError?.readabilityHandler = nil
                    // Removing handlers prevents future notifications, but
                    // does not join a callback already borrowing this fd.
                    await output?.finishReadCallbacks(didWait: {
                        self.outputReaderDrainDidWait?(generation)
                    })
                    if let output, let stoppingOutput, let stoppingError {
                        // All native borrows have exited. The same cleanup
                        // owner now drains both exact nonblocking pipe handles.
                        let stdoutDrained = Self.drainExitedOutput(stoppingOutput,
                            channel: .stdout, output: output)
                        let stderrDrained = Self.drainExitedOutput(stoppingError,
                            channel: .stderr, output: output)
                        output.recordProcessExit(stoppingProcess.terminationStatus)
                        outputDrained = stdoutDrained && stderrDrained
                        if !outputDrained { output.finish(ParakeetSidecarError.outputReaderCleanupIncomplete) }
                    }
                    // Do not manufacture normal EOF after a timer. A failed
                    // finite drain retains this exact Process/handle ownership.
                    if !outputDrained {
                        print("[ParakeetSidecar] exited helper output drain incomplete generation=\(generation)")
                    }
                } else {
                    print("[ParakeetSidecar] helper cleanup incomplete pid=\(stoppingProcess.processIdentifier) exited=\(exited) writerDrained=\(drained)")
                }
                let vocabularyRemoved: Bool
                if exited && drained && outputDrained, let stoppingVocabulary {
                    do { try FileManager.default.removeItem(at: stoppingVocabulary) }
                    catch {
                        print("[ParakeetSidecar] vocabulary cleanup incomplete generation=\(generation)")
                    }
                    vocabularyRemoved = !FileManager.default.fileExists(atPath: stoppingVocabulary.path)
                } else { vocabularyRemoved = stoppingVocabulary == nil }
                let cleanupComplete = exited && drained && outputDrained && vocabularyRemoved
                if exited && drained { finishVerificationPCM(generation: generation, process: stoppingProcess) }
                withInputStateLock { state in
                    guard state.processGeneration == generation, state.process === stoppingProcess else { return }
                    if cleanupComplete {
                        stoppingProcess.terminationHandler = nil
                        state.process = nil
                        state.processGeneration = nil
                        state.stdinHandle = nil
                        state.stdoutHandle = nil
                        state.stderrHandle = nil
                        state.outputState = nil
                        state.vocabularyDirectory = nil
                    }
                    state.cleanupTask = nil
                }
            }
            state.cleanupTask = cleanup
            return cleanup
        }
    }

    private static func drainExitedOutput(_ handle: FileHandle,
        channel: ParakeetOutputStreamState.ReaderChannel, output: ParakeetOutputStreamState) -> Bool {
        for _ in 0..<maximumOutputDrainReads {
            do {
                // nil means EINTR/EAGAIN, never EOF. Retain ownership so an
                // explicit stop can retry instead of closing an unread pipe.
                guard let data = try readAvailableOutput(handle) else { return false }
                switch channel {
                case .stdout: output.receive(data, from: handle)
                case .stderr: output.receiveStderr(data, from: handle)
                }
                if data.isEmpty { return true }
            } catch { output.finish(error); return false }
        }
        return false
    }

    private func stopOwnedProcess(_ stoppingProcess: Process, input stoppingInput: FileHandle?) async -> Bool {
        if let stoppingInput {
            inputQueue.async {
                var stopLine = (try? JSONSerialization.data(withJSONObject: ["type": "stop"])) ?? Data()
                stopLine.append(0x0A)
                try? stoppingInput.write(contentsOf: stopLine)
                try? stoppingInput.close()
            }
        }

        if stoppingProcess.isRunning {
            _ = await waitForExit(stoppingProcess, timeout: .seconds(3))
            if stoppingProcess.isRunning {
                stoppingProcess.terminate()
            }
            _ = await waitForExit(stoppingProcess, timeout: .milliseconds(500))
            if stoppingProcess.isRunning {
                _ = Darwin.kill(stoppingProcess.processIdentifier, SIGKILL)
            }
            _ = await waitForExit(stoppingProcess, timeout: .milliseconds(500))
        }
        guard !stoppingProcess.isRunning else { return false }
        return true
    }

    private func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
        }
        return !process.isRunning
    }

    private func waitForInputDrain() async -> Bool {
        let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        inputQueue.async {
            pair.continuation.yield(true)
            pair.continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            pair.continuation.yield(false)
            pair.continuation.finish()
        }
        var drained = false
        for await result in pair.stream { drained = result }
        deadline.cancel()
        await deadline.value
        return drained
    }

    @MainActor var audioWriterSnapshot: ParakeetAudioWriterDiagnostics? { audioWriterDiagnostics() }

    func audioWriterDiagnostics() -> ParakeetAudioWriterDiagnostics {
        withInputStateLock { state in
            ParakeetAudioWriterDiagnostics(
                maximumPendingChunks: Self.maximumPendingAudioChunks,
                maximumPendingBytes: Self.maximumPendingAudioBytes,
                pendingChunks: state.pendingAudioChunks,
                pendingBytes: state.pendingAudioBytes,
                droppedChunks: state.droppedAudioChunks
            )
        }
    }

    private func recordDroppedAudioChunk() {
        withInputStateLock { $0.droppedAudioChunks += 1 }
    }

    private func releaseAudioWrite(byteCount: Int) {
        withInputStateLock {
            $0.pendingAudioChunks = max(0, $0.pendingAudioChunks - 1)
            $0.pendingAudioBytes = max(0, $0.pendingAudioBytes - byteCount)
        }
    }

    private func withInputStateLock<T: Sendable>(
        _ operation: @Sendable (inout InputState) throws -> T
    ) rethrows -> T {
        try inputState.withLock(operation)
    }

    /// Conservative admission cost for mono scratch/snapshot and an escaped
    /// JSON/base64 representation. It bounds queued values and snapshot work;
    /// it is not a claim about Foundation allocator overhead or process RSS.
    static func audioWriteByteBudget(frameLength: Int, channelCount: Int) -> Int? {
        guard frameLength > 0, channelCount > 0,
              frameLength <= (maximumPendingAudioBytes / MemoryLayout<Float>.size) / channelCount else { return nil }
        // The division guard bounds every following multiplication/addition,
        // including pathological dimensions, before any sample is copied.
        let monoBytes = frameLength * MemoryLayout<Float>.size
        let base64Bytes = ((monoBytes + 2) / 3) * 4
        let byteBudget = monoBytes * 2 + base64Bytes * 2 + 2_048
        return byteBudget <= maximumPendingAudioBytes ? byteBudget : nil
    }

    private static func monoAudioSnapshot(from buffer: AVAudioPCMBuffer) -> MonoAudioSnapshot? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0,
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else { return nil }
        var monoSamples = [Float]()
        monoSamples.reserveCapacity(frameLength)
        for frame in 0..<frameLength {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channelData[channel][frame * buffer.stride]
            }
            monoSamples.append(sample / Float(channelCount))
        }
        let samples = monoSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        return MonoAudioSnapshot(samples: samples, sampleRate: buffer.format.sampleRate)
    }

    // The pure serialization entry remains available to existing stride tests.
    // Live PCM uses the queued immutable-value overload below.
    static func audioEventData(from buffer: AVAudioPCMBuffer, sequence: Int, source: AudioSourceType,
        serializationCheckpoint: (@Sendable () -> Void)? = nil) -> Data? {
        guard let snapshot = monoAudioSnapshot(from: buffer) else { return nil }
        return audioEventData(from: snapshot, sequence: sequence, source: source,
            serializationCheckpoint: serializationCheckpoint)
    }

    private static func audioEventData(from snapshot: MonoAudioSnapshot, sequence: Int, source: AudioSourceType,
        serializationCheckpoint: (@Sendable () -> Void)?) -> Data? {
        serializationCheckpoint?()
        let payload: [String: Any] = [
            "type": "audio",
            "sequence": sequence,
            "sampleRate": snapshot.sampleRate,
            "channels": 1,
            "encoding": "float32le",
            "audioSource": source.rawValue,
            "audio": snapshot.samples.base64EncodedString()
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private enum HealthEvent: Sendable {
        case output(Data, isError: Bool)
        case pipeClosed(isError: Bool)
        case exited(Int32)
        case deadline
    }

    private enum HealthCheckFailure: LocalizedError {
        case timedOut, outputLimit, eventOverflow, incompleteOutput, readerCleanupTimeout

        var errorDescription: String? {
            switch self {
            case .timedOut: return "Health check timed out"
            case .outputLimit: return "Health check output exceeded 1048576 bytes"
            case .eventOverflow: return "Health check output event buffer overflow"
            case .incompleteOutput: return "Health check ended before process exit and pipe drain"
            case .readerCleanupTimeout: return "Health check readers did not finish within the cleanup deadline"
            }
        }
    }

    private static func runHealthCheck(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        delayProvider: any DelayProvider
    ) async -> ParakeetRuntimeDiagnostics {
        guard !Task.isCancelled else {
            return .unavailable(path: executableURL.path, error: "Health check cancelled")
        }
        // This process and its callbacks belong only to this invocation. They
        // never share the live transcription process or stop a later check.
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = minimalRuntimeEnvironment()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let pair = AsyncThrowingStream<HealthEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        // Reader completion is independent of the business stream, which may
        // already be terminated by cancellation or output overflow. Each
        // reader has one bounded completion slot and closes it after its last
        // read and handler release.
        let outputReader = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let errorReader = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        attachHealthReader(stdoutHandle, isError: false, continuation: pair.continuation,
            completion: outputReader.continuation)
        attachHealthReader(stderrHandle, isError: true, continuation: pair.continuation,
            completion: errorReader.continuation)
        process.terminationHandler = { exitedProcess in
            if case .dropped = pair.continuation.yield(.exited(exitedProcess.terminationStatus)) {
                pair.continuation.finish(throwing: HealthCheckFailure.eventOverflow)
            }
        }
        defer {
            // Let an in-flight callback retain its own FileHandle; never close
            // a handle concurrently with its read callback.
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            process.terminationHandler = nil
            pair.continuation.finish()
            outputReader.continuation.finish()
            errorReader.continuation.finish()
        }
        do {
            try Task.checkCancellation()
            try process.run()
        } catch {
            let reason = error is CancellationError ? "Health check cancelled" : error.localizedDescription
            return .unavailable(path: executableURL.path, error: reason)
        }

        let deadline = Task<Void, Never> {
            do {
                try await delayProvider.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                try Task.checkCancellation()
                if case .dropped = pair.continuation.yield(.deadline) {
                    pair.continuation.finish(throwing: HealthCheckFailure.eventOverflow)
                }
            } catch is CancellationError {
                // The retained caller cancels and joins this exact deadline.
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        var output = Data()
        var errorOutput = Data()
        var exitStatus: Int32?
        var outputClosed = false
        var errorClosed = false
        var failure: Error?
        await withTaskCancellationHandler {
            do {
                for try await event in pair.stream {
                    try Task.checkCancellation()
                    switch event {
                    case .output(let data, let isError):
                        guard data.count <= 1_048_576 - output.count - errorOutput.count else {
                            throw HealthCheckFailure.outputLimit
                        }
                        if isError { errorOutput.append(data) }
                        else { output.append(data) }
                    case .pipeClosed(let isError):
                        if isError { errorClosed = true }
                        else { outputClosed = true }
                    case .exited(let status):
                        exitStatus = status
                    case .deadline:
                        throw HealthCheckFailure.timedOut
                    }
                    if exitStatus != nil, outputClosed, errorClosed { break }
                }
                try Task.checkCancellation()
                guard exitStatus != nil, outputClosed, errorClosed else {
                    throw HealthCheckFailure.incompleteOutput
                }
            } catch {
                failure = error
            }
        } onCancel: {
            // Continuation termination is executor-safe and wakes an empty
            // pipe stream. Cleanup remains with this invocation's owner.
            pair.continuation.finish(throwing: CancellationError())
        }
        deadline.cancel()
        await deadline.value
        pair.continuation.finish()
        // Parent cancellation must not skip the real TERM/KILL exit budget.
        // This local task is retained and always joined before returning.
        let cleanup = Task {
            let exited = await stopHealthCheckProcess(process)
            let readersFinished = await joinHealthReaders(outputReader: outputReader, errorReader: errorReader)
            return (exited, readersFinished)
        }
        let (exited, readersFinished) = await cleanup.value
        guard exited else {
            let reason = failure?.localizedDescription ?? "Health check failed"
            return .unavailable(path: executableURL.path,
                error: "\(reason); helper cleanup incomplete pid=\(process.processIdentifier)")
        }
        guard readersFinished else {
            let reason = failure?.localizedDescription ?? "Health check failed"
            return .unavailable(path: executableURL.path,
                error: "\(reason); \(HealthCheckFailure.readerCleanupTimeout.localizedDescription)")
        }
        if Task.isCancelled || failure.map({ $0 is CancellationError }) == true {
            return .unavailable(path: executableURL.path, error: "Health check cancelled")
        }
        if let failure {
            return .unavailable(path: executableURL.path, error: failure.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(
                path: executableURL.path,
                error: message?.isEmpty == false ? message : "Helper exited with \(process.terminationStatus)"
            )
        }
        guard let health = try? JSONDecoder().decode(HelperHealth.self, from: output),
              health.status == "ok",
              health.source == ASRSource.localParakeetASR.rawValue,
              health.runtimeMode == "bundled_native" else {
            return .unavailable(path: executableURL.path, error: "Invalid helper health response")
        }
        guard health.architecture == currentArchitecture else {
            return .unavailable(
                path: executableURL.path,
                error: "Helper architecture \(health.architecture) does not match \(currentArchitecture)"
            )
        }
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let helperPath = executableURL.standardizedFileURL.path
        let bundled = helperPath.hasPrefix(bundlePath + "/Contents/Helpers/")
        return ParakeetRuntimeDiagnostics(
            runtimeMode: health.runtimeMode,
            helperPath: helperPath,
            helperBundled: bundled,
            helperExecutable: true,
            helperArchitecture: health.architecture,
            runtimeVersion: health.runtimeVersion,
            sherpaVersion: health.sherpaVersion,
            onnxRuntimeVersion: health.onnxRuntimeVersion,
            healthStatus: health.status,
            modelStatus: health.modelStatus,
            lastHealthError: nil
        )
    }

    private static func attachHealthReader(
        _ handle: FileHandle, isError: Bool,
        continuation: AsyncThrowingStream<HealthEvent, Error>.Continuation,
        completion: AsyncThrowingStream<Void, Error>.Continuation
    ) {
        handle.readabilityHandler = { handle in
            do {
                // A bounded chunk also bounds the sixteen queued data events.
                let data = try handle.read(upToCount: 65_536) ?? Data()
                let event: HealthEvent
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    event = .pipeClosed(isError: isError)
                } else {
                    event = .output(data, isError: isError)
                }
                if case .dropped = continuation.yield(event) {
                    continuation.finish(throwing: HealthCheckFailure.eventOverflow)
                }
                if data.isEmpty {
                    completion.yield(())
                    completion.finish()
                }
            } catch {
                handle.readabilityHandler = nil
                continuation.finish(throwing: error)
                completion.yield(())
                completion.finish()
            }
        }
    }

    private static func joinHealthReaders(
        outputReader: (stream: AsyncThrowingStream<Void, Error>, continuation: AsyncThrowingStream<Void, Error>.Continuation),
        errorReader: (stream: AsyncThrowingStream<Void, Error>, continuation: AsyncThrowingStream<Void, Error>.Continuation)
    ) async -> Bool {
        // Resource cleanup uses its own real deadline. An injected business
        // clock must never prevent releasing the process or its pipe readers.
        let deadline = Task<Void, Never> {
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                outputReader.continuation.finish(throwing: HealthCheckFailure.readerCleanupTimeout)
                errorReader.continuation.finish(throwing: HealthCheckFailure.readerCleanupTimeout)
            } catch is CancellationError {} catch {
                outputReader.continuation.finish(throwing: error)
                errorReader.continuation.finish(throwing: error)
            }
        }
        var outputFinished = false
        var errorFinished = false
        do {
            for try await _ in outputReader.stream { outputFinished = true }
            for try await _ in errorReader.stream { errorFinished = true }
        } catch {}
        deadline.cancel()
        await deadline.value
        return outputFinished && errorFinished
    }

    private static func stopHealthCheckProcess(_ process: Process) async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if await waitForHealthCheckExit(process) { return true }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        return await waitForHealthCheckExit(process)
    }

    private static func waitForHealthCheckExit(_ process: Process) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while process.isRunning, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }
        return !process.isRunning
    }

    private static func minimalRuntimeEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        var result = [
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_CTYPE": "UTF-8"
        ]
        if let temporaryDirectory = environment["TMPDIR"] {
            result["TMPDIR"] = temporaryDirectory
        }
        return result
    }

    private static var currentArchitecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}

/// MainActor owns capture control and task identities. PCM forwarding retains
/// the capture callback's executor and the runtime's existing bounded writer.
@MainActor
final class LocalParakeetASRProvider: ASRProvider {
    nonisolated let id: ASRProviderID = .localParakeet
    nonisolated let displayName = ASRProviderID.localParakeet.displayName

    private let modelManager: any LocalModelManager
    private let model: LocalModelDescriptor
    private let runtimeClient: any ParakeetRuntimeClient

    func revokeVerificationPCM() {
        (runtimeClient as? ParakeetSidecarRuntimeClient)?.revokeVerificationPCM()
    }
    private let systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService
    @MainActor private var captureMode: AudioCaptureMode?
    @MainActor private var registeredReceiver: ParakeetCaptureReceiver?
    @MainActor private var lastRoundOutcome: CaptureRoundOutcome?
    #if DEBUG
    @MainActor var onRoundRequestedForTesting: (@MainActor (UUID) -> Void)?
    #endif
    @MainActor private var requestedRoundID: UUID?
    @MainActor private var activeRoundID: UUID?
    @MainActor private var activeRoundOutcome: CaptureRoundOutcome?

    // Startup and the bridge retain this exact round after it is invalidated.
    // A source failure is distinct from failure to release native resources.
    @MainActor
    private final class CaptureRoundOutcome {
        let receiver: ParakeetCaptureReceiver
        let config: ASRConfig
        var terminalRoundID: UUID?
        var startupCompleted = false
        var microphoneControl: Task<Void, Never>?
        var failedSystemCleanup: Task<Void, Never>?
        var systemAudioStop: SystemAudioCaptureStopReceipt?
        var cleanupFailure: Error?
        init(roundID: UUID, receiver: ParakeetCaptureReceiver, config: ASRConfig) {
            self.receiver = receiver
            self.config = config
            terminalRoundID = roundID
        }
        var sourceFailure: Error? {
            guard !startupCompleted || receiver.allSelectedSourcesFailed else { return nil }
            return receiver.firstFailure
        }
    }
    @MainActor var onCaptureSourceFailure: (@MainActor (LocalParakeetASRProvider, AudioSourceType, Error) -> Void)?
    @MainActor var hasHealthyCaptureSource: Bool { activeRoundOutcome?.receiver.hasHealthySource == true }
    @MainActor
    func ownsCurrentSystemAudioCapture(_ capture: ScreenCaptureKitSystemAudioCaptureService) -> Bool {
        guard capture === systemAudioCaptureService,
            let receipt = (activeRoundOutcome ?? lastRoundOutcome)?.systemAudioStop else { return false }
        return capture.isCurrentCaptureOwner(receipt)
    }
    @MainActor
    func hasMostRecentSystemAudioCaptureReceipt(_ capture: ScreenCaptureKitSystemAudioCaptureService) -> Bool {
        guard capture === systemAudioCaptureService,
            let outcome = activeRoundOutcome ?? lastRoundOutcome,
            let terminalRoundID = outcome.terminalRoundID,
            requestedRoundID == nil || requestedRoundID == terminalRoundID,
            let receipt = outcome.systemAudioStop else { return false }
        return capture.isMostRecentCaptureReceipt(receipt)
    }
    /// Counts entry into the synchronous runtime append call, not successful
    /// pipe writes or model consumption. Bounded writer loss stays separate.
    struct CaptureIngressSnapshot: Sendable {
        struct SourceCounters: Sendable {
            var bufferCount = 0
            var frameCount = 0
            var lastBufferAt: Date?
        }
        let roundID: UUID
        let sources: [AudioSourceType: SourceCounters]
    }

    func captureIngressSnapshot(forSessionID sessionID: String) -> CaptureIngressSnapshot? {
        guard let roundID = activeRoundID, requestedRoundID == roundID,
            let outcome = activeRoundOutcome, outcome.startupCompleted,
            outcome.config.sessionID == sessionID else { return nil }
        return .init(roundID: roundID, sources: outcome.receiver.ingressCounters)
    }

    func isTranscriptionActive(source: AudioSourceType, sessionID: String?) -> Bool {
        guard let sessionID, let roundID = activeRoundID, requestedRoundID == roundID,
            let outcome = activeRoundOutcome, outcome.startupCompleted,
            outcome.config.sessionID == sessionID,
            let bridgeTask, !bridgeTask.isCancelled else { return false }
        return outcome.receiver.admits(source)
    }

    // Sole writer counters are projected on demand; no mirrored UI state.
    var audioWriterSnapshot: ParakeetAudioWriterDiagnostics? { runtimeClient.audioWriterSnapshot }
    @MainActor var captureSourceFailures: [AudioSourceType: Error] {
        (activeRoundOutcome ?? lastRoundOutcome)?.receiver.failures ?? [:]
    }
    @MainActor private var startupTask: Task<AsyncThrowingStream<ParakeetTranscriptEvent, Error>, Error>?
    @MainActor private var bridgeTask: Task<Void, Never>?
    @MainActor private var outputContinuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?
    @MainActor private var teardownTask: (id: UUID, task: Task<Void, Never>)?
    private let startCaptureOverride: ((AudioCaptureMode) async throws -> Void)?
    private let startOwnedCaptureOverride: (@MainActor (AudioCaptureMode,
        @escaping @MainActor (SystemAudioCaptureStopReceipt) -> Void) async throws -> Void)?
    private let stopCaptureOverride: (() -> Void)?
    private let captureDelegatesObserver: (@MainActor (any AudioEngineBufferDelegate, any SystemAudioBufferDelegate) -> Void)?

    // ASR stop is a legacy Void contract. Failed native cleanup remains visible
    // to lifecycle callers and blocks a new round rather than reporting release.
    @MainActor var captureCleanupFailure: Error? {
        (activeRoundOutcome ?? lastRoundOutcome)?.cleanupFailure ?? runtimeClient.cleanupFailure
    }

    @MainActor
    var hasOwnedTranscriptionWork: Bool {
        activeRoundID != nil || startupTask != nil || bridgeTask != nil ||
            teardownTask != nil || captureCleanupFailure != nil
    }

    init(
        model: LocalModelDescriptor = .defaultParakeetASR,
        modelManager: any LocalModelManager = FileLocalModelManager(),
        runtimeClient: (any ParakeetRuntimeClient)? = nil,
        systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService? = nil,
        startCapture: ((AudioCaptureMode) async throws -> Void)? = nil,
        startOwnedCapture: (@MainActor (AudioCaptureMode,
            @escaping @MainActor (SystemAudioCaptureStopReceipt) -> Void) async throws -> Void)? = nil,
        stopCapture: (() -> Void)? = nil,
        captureDelegatesObserver: (@MainActor (any AudioEngineBufferDelegate, any SystemAudioBufferDelegate) -> Void)? = nil
    ) {
        self.model = model
        self.modelManager = modelManager
        self.runtimeClient = runtimeClient ?? ParakeetSidecarRuntimeClient()
        self.systemAudioCaptureService = systemAudioCaptureService ?? .shared
        startCaptureOverride = startCapture
        startOwnedCaptureOverride = startOwnedCapture
        stopCaptureOverride = stopCapture
        self.captureDelegatesObserver = captureDelegatesObserver
    }

    func isAvailable() async -> Bool {
        let modelReady = (await modelManager.modelStatus(model)).isReady
        let runtimeReady = await runtimeClient.isRuntimeAvailable()
        return modelReady && runtimeReady
    }

    func isRuntimeAvailable() async -> Bool {
        await runtimeClient.isRuntimeAvailable()
    }

    @MainActor
    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        let roundID = UUID()
        requestedRoundID = roundID
        // New submission permanently revokes the older presentation ticket.
        // Its exact resources and cleanup failure remain in the same outcome.
        activeRoundOutcome?.terminalRoundID = nil
        lastRoundOutcome?.terminalRoundID = nil
        #if DEBUG
        onRoundRequestedForTesting?(roundID)
        #endif
        retireActiveRound()
        await teardownTask?.task.value
        guard requestedRoundID == roundID else { throw CancellationError() }
        try Task.checkCancellation()
        if let captureCleanupFailure { throw captureCleanupFailure }
        activeRoundID = roundID
        lastRoundOutcome = nil
        let receiver = ParakeetCaptureReceiver(mode: config.captureMode, runtime: runtimeClient,
            system: systemAudioCaptureService, onSystemFailure: { [weak self] error in
                self?.captureSourceDidFail(.systemAudio, error: error, roundID: roundID)
            })
        let outcome = CaptureRoundOutcome(roundID: roundID, receiver: receiver, config: config)
        activeRoundOutcome = outcome
        outcome.microphoneControl = Task { @MainActor [weak self] in
            for await error in receiver.microphoneFailures.stream {
                self?.captureSourceDidFail(.microphone, error: error, roundID: roundID)
            }
        }
        let startup = Task { @MainActor [self] in
            let ready = await modelManager.modelStatus(model).isReady
            try requireCurrentRound(roundID)
            guard ready else { throw ASRProviderError.modelNotReady(.localParakeet) }
            let runtimeHealth = await runtimeClient.runtimeDiagnostics()
            try requireCurrentRound(roundID)
            guard runtimeHealth.healthStatus == "ok" else {
                throw ASRProviderError.providerUnavailable(runtimeHealth.lastHealthError ?? "The Parakeet runtime is unavailable.")
            }
            let modelDirectory = modelManager.fileURL(for: model)
            let modelReady = await runtimeClient.probeModel(at: modelDirectory)
            try requireCurrentRound(roundID)
            guard modelReady else {
                throw ASRProviderError.providerUnavailable(
                    "The Parakeet runtime could not load the verified model. Repair the model before retrying."
                )
            }
            let events = try await runtimeClient.startTranscription(modelDirectory: modelDirectory, config: config)
            try requireCurrentRound(roundID)
            try await startAudioCapture(config.captureMode, receiver: receiver, outcome: outcome)
            try requireCurrentRound(roundID)
            return events
        }
        startupTask = startup
        do {
            let eventStream = try await withTaskCancellationHandler {
                try await startup.value
            } onCancel: {
                startup.cancel()
            }
            try requireCurrentRound(roundID)
            outcome.startupCompleted = true
            startupTask = nil
            let pair = AsyncThrowingStream<TranscriptSegment, Error>.makeStream(
                bufferingPolicy: .bufferingOldest(ParakeetSidecarRuntimeClient.maximumPendingTranscriptEvents))
            outputContinuation = pair.continuation
            let bridge = Task { @MainActor [weak self, runtimeClient] in
                var failure: Error?
                do {
                    for try await event in eventStream {
                        guard !Task.isCancelled, self?.activeRoundID == roundID else { break }
                        let segment = try ParakeetTranscriptMapper.map(event, config: config)
                        guard !segment.text.isEmpty, receiver.admits(segment.source) else { continue }
                        guard segment.text.utf8.count <= ParakeetSidecarRuntimeClient.maximumTranscriptTextBytes else {
                            throw ParakeetSidecarError.transcriptTooLarge(
                                maximumBytes: ParakeetSidecarRuntimeClient.maximumTranscriptTextBytes)
                        }
                        if case .dropped = pair.continuation.yield(segment) {
                            // The existing bridge owns exact native/runtime
                            // cleanup before presenting this overflow error.
                            throw ParakeetSidecarError.transcriptBufferOverflow(
                                maximumEvents: ParakeetSidecarRuntimeClient.maximumPendingTranscriptEvents)
                        }
                    }
                } catch {
                    if !Task.isCancelled { failure = error }
                }
                guard let self, self.activeRoundID == roundID else {
                    pair.continuation.finish()
                    return
                }
                // Async runtime stop owns a teardown fence before suspension.
                // A new start cannot adopt the helper while this round exits.
                receiver.close()
                let microphoneControl = outcome.microphoneControl
                microphoneControl?.cancel()
                let failedSystemCleanup = outcome.failedSystemCleanup
                self.activeRoundID = nil
                self.lastRoundOutcome = outcome
                self.activeRoundOutcome = nil
                self.outputContinuation = nil
                let capturedStop = self.stopAudioCapture(outcome: outcome)
                let previousTeardown = self.teardownTask?.task
                let cleanup = self.ownTeardown { [self, runtimeClient] in
                    await previousTeardown?.value
                    await runtimeClient.stop()
                    await self.joinCapturedSystemAudioStop(capturedStop, outcome: outcome)
                    await failedSystemCleanup?.value
                    await microphoneControl?.value
                }
                await cleanup.value
                if self.requestedRoundID == roundID {
                    self.bridgeTask = nil
                }
                pair.continuation.finish(throwing: outcome.sourceFailure ?? failure ?? outcome.cleanupFailure)
            }
            bridgeTask = bridge
            pair.continuation.onTermination = { [bridge] termination in
                if case .cancelled = termination { bridge.cancel() }
            }
            return pair.stream
        } catch {
            if activeRoundID == roundID { retireActiveRound() }
            await teardownTask?.task.value
            throw outcome.sourceFailure ?? error
        }
    }

    @MainActor
    func stopTranscription() async { await stopTranscription(retryFailedResource: true) }

    @MainActor
    func stopTranscription(retryFailedResource retryAuthorized: Bool) async {
        // Only an authorized explicit request retries. An initial application
        // cleanup joins a failure already initiated by startup/source retirement.
        let retryFailedResource = retryAuthorized && captureCleanupFailure != nil && teardownTask == nil
        requestedRoundID = nil
        retireActiveRound(retryFailedResource: retryAuthorized)
        await teardownTask?.task.value
        if retryAuthorized, runtimeClient.cleanupFailure != nil, teardownTask == nil {
            let retry = ownTeardown { [runtimeClient] in await runtimeClient.stop() }
            await retry.value
        }
        if retryFailedResource, captureCleanupFailure != nil,
           let outcome = lastRoundOutcome, let receipt = outcome.systemAudioStop {
            // Another explicit caller may have installed this same resource's
            // retry while the initial join suspended. Join it, never replace it.
            if let inFlight = teardownTask {
                await inFlight.task.value
                return
            }
            let retry = ownTeardown { [self] in
                _ = systemAudioCaptureService.retryStoppingSystemAudioCapture(capturedReceipt: receipt)
                await joinCapturedSystemAudioStop(receipt, outcome: outcome)
            }
            await retry.value
        }
    }

    @MainActor
    func waitForCurrentTranscriptionEnd() async {
        await bridgeTask?.value
        await teardownTask?.task.value
    }

    @MainActor
    private func requireCurrentRound(_ roundID: UUID) throws {
        guard activeRoundID == roundID, requestedRoundID == roundID else { throw CancellationError() }
        try Task.checkCancellation()
    }

    @MainActor
    private func retireActiveRound(retryFailedResource: Bool = false) {
        guard activeRoundID != nil || startupTask != nil || bridgeTask != nil else { return }
        let startup = startupTask
        let bridge = bridgeTask
        let output = outputContinuation
        let outcome = activeRoundOutcome
        let microphoneControl = outcome?.microphoneControl
        let failedSystemCleanup = outcome?.failedSystemCleanup
        outcome?.receiver.close()
        microphoneControl?.cancel()
        let previousTeardown = teardownTask?.task
        activeRoundID = nil
        if let outcome { lastRoundOutcome = outcome }
        activeRoundOutcome = nil
        startupTask = nil
        bridgeTask = nil
        outputContinuation = nil
        startup?.cancel()
        bridge?.cancel()
        output?.finish(throwing: outcome?.sourceFailure)
        let capturedStop = stopAudioCapture(outcome: outcome, retryFailedResource: retryFailedResource)
        _ = ownTeardown { [self, runtimeClient] in
            await previousTeardown?.value
            await runtimeClient.stop()
            await self.joinCapturedSystemAudioStop(capturedStop, outcome: outcome)
            _ = try? await startup?.value
            // A cancelled capture startup can return after the first stop.
            // Capture and join that exact late stop before adopting another round.
            let lateCapturedStop = stopAudioCapture(outcome: outcome)
            await runtimeClient.stop()
            await joinCapturedSystemAudioStop(lateCapturedStop, outcome: outcome)
            await failedSystemCleanup?.value
            await microphoneControl?.value
            await bridge?.value
        }
    }

    @MainActor
    private func ownTeardown(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [self] in
            await operation()
            // Retirement belongs to this exact task before any waiter returns.
            if teardownTask?.id == id { teardownTask = nil }
        }
        teardownTask = (id, task)
        return task
    }

    @MainActor
    private func startAudioCapture(_ mode: AudioCaptureMode, receiver: ParakeetCaptureReceiver, outcome: CaptureRoundOutcome) async throws {
        captureMode = mode
        registeredReceiver = receiver
        captureDelegatesObserver?(receiver, receiver)
        if let startOwnedCaptureOverride {
            // A mixed injected capture which starts a real controlled SCK
            // stream publishes its exact lease before the first suspension.
            // The existing void override remains for no-native adapters.
            try await startOwnedCaptureOverride(mode) { outcome.systemAudioStop = $0 }
            return
        }
        if let startCaptureOverride {
            try await startCaptureOverride(mode)
            return
        }
        switch mode {
        case .microphoneOnly:
            try AudioEngineManager.shared.register(receiver).get()
        case .systemAudioOnly:
            let owned = systemAudioCaptureService.beginSystemAudioCapture(onOwned: { [self] receipt in
                outcome.systemAudioStop = receipt
                systemAudioCaptureService.register(receiver, capturedReceipt: receipt)
            })
            try await systemAudioCaptureService.finishStartingSystemAudioCapture(
                capturedStart: owned.startup, capturedReceipt: owned.receipt)
        case .microphoneAndSystem:
            try AudioEngineManager.shared.register(receiver).get()
            let owned = systemAudioCaptureService.beginSystemAudioCapture(onOwned: { [self] receipt in
                outcome.systemAudioStop = receipt
                systemAudioCaptureService.register(receiver, capturedReceipt: receipt)
            })
            try await systemAudioCaptureService.finishStartingSystemAudioCapture(
                capturedStart: owned.startup, capturedReceipt: owned.receipt)
        }
    }

    @MainActor
    private func stopAudioCapture(outcome: CaptureRoundOutcome?, retryFailedResource: Bool = false)
        -> SystemAudioCaptureStopReceipt? {
        guard let captureMode, let receiver = registeredReceiver else { return outcome?.systemAudioStop }
        if let outcome, outcome.receiver !== receiver { return outcome.systemAudioStop }
        registeredReceiver = nil
        if let stopCaptureOverride {
            stopCaptureOverride()
            self.captureMode = nil
            return nil
        }
        let capturedStop: SystemAudioCaptureStopReceipt?
        switch captureMode {
        case .microphoneOnly:
            AudioEngineManager.shared.unregister(receiver)
            capturedStop = nil
        case .systemAudioOnly:
            systemAudioCaptureService.unregister(receiver)
            capturedStop = (outcome?.systemAudioStop).map {
                systemAudioCaptureService.stopSystemAudioCapture(capturedReceipt: $0, retryFailed: retryFailedResource)
            }
        case .microphoneAndSystem:
            AudioEngineManager.shared.unregister(receiver)
            systemAudioCaptureService.unregister(receiver)
            capturedStop = (outcome?.systemAudioStop).map {
                systemAudioCaptureService.stopSystemAudioCapture(capturedReceipt: $0, retryFailed: retryFailedResource)
            }
        }
        self.captureMode = nil
        if let capturedStop { outcome?.systemAudioStop = capturedStop }
        return capturedStop
    }

    @MainActor
    private func joinCapturedSystemAudioStop(_ receipt: SystemAudioCaptureStopReceipt?, outcome: CaptureRoundOutcome?) async {
        guard let receipt else { return }
        do {
            try await systemAudioCaptureService.finishStoppingSystemAudioCapture(capturedReceipt: receipt)
            outcome?.cleanupFailure = nil
        } catch { outcome?.cleanupFailure = error }
        // The diagnostic is derived from the actual current/last outcome.
        // A late old outcome cannot publish a failure into a replacement round.
    }

    @MainActor
    private func captureSourceDidFail(_ source: AudioSourceType, error: Error, roundID: UUID) {
        guard activeRoundID == roundID, requestedRoundID == roundID,
              let outcome = activeRoundOutcome else { return }
        // Initial setup retains its existing all-selected-sources contract.
        // Runtime Combined failure revokes only the failed source's admission.
        guard outcome.startupCompleted, outcome.receiver.hasHealthySource else {
            retireActiveRound()
            return
        }
        switch source {
        case .systemAudio:
            systemAudioCaptureService.unregister(outcome.receiver)
            if let owned = outcome.systemAudioStop {
                let stop = systemAudioCaptureService.stopSystemAudioCapture(capturedReceipt: owned)
                outcome.failedSystemCleanup = Task { @MainActor [self] in
                    await joinCapturedSystemAudioStop(stop, outcome: outcome)
                }
            }
        case .microphone:
            // The callback that delivered this event has returned to the audio
            // manager queue. Unregister only this round's failed mic delegate.
            if startCaptureOverride == nil { AudioEngineManager.shared.unregister(outcome.receiver) }
        default: return
        }
        onCaptureSourceFailure?(self, source, error)
    }

    // Existing diagnostic fixtures call this source-error entry directly.
    // Native capture registers the immutable per-round receiver instead.
    @MainActor
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error) {
        activeRoundOutcome?.receiver.systemAudioCaptureService(service, didFailWithError: error)
    }

}

/// One capture epoch's immutable delegates and source admission. PCM retains
/// its callback executor. Closing a source and enqueueing PCM share this lock,
/// so a failed/retired delegate cannot append to the helper's later stream.
private final class ParakeetCaptureReceiver: AudioEngineBufferDelegate, SystemAudioBufferDelegate {
    private struct SourceFailure: Sendable {
        let source: String
        let error: Error
    }
    private struct Admission: Sendable {
        let microphoneSelected: Bool
        let systemSelected: Bool
        var closed = false
        var failures: [SourceFailure] = []
        var ingressCounters: [AudioSourceType: LocalParakeetASRProvider.CaptureIngressSnapshot.SourceCounters] = [:]
    }
    private let admission: OSAllocatedUnfairLock<Admission>
    private let systemIdentity: ObjectIdentifier
    private let runtime: any ParakeetRuntimeClient
    private let onSystemFailure: @MainActor (Error) -> Void
    let microphoneFailures = AsyncStream<Error>.makeStream(bufferingPolicy: .bufferingOldest(1))

    init(mode: AudioCaptureMode, runtime: any ParakeetRuntimeClient,
        system: ScreenCaptureKitSystemAudioCaptureService,
        onSystemFailure: @escaping @MainActor (Error) -> Void) {
        admission = OSAllocatedUnfairLock(initialState: Admission(
            microphoneSelected: mode != .systemAudioOnly,
            systemSelected: mode != .microphoneOnly))
        systemIdentity = ObjectIdentifier(system)
        self.runtime = runtime
        self.onSystemFailure = onSystemFailure
    }
    private static func selected(_ source: AudioSourceType, in state: Admission) -> Bool {
        source == .microphone ? state.microphoneSelected : source == .systemAudio && state.systemSelected
    }
    private static func failed(_ source: AudioSourceType, in state: Admission) -> Bool {
        state.failures.contains { $0.source == source.rawValue }
    }
    func admits(_ source: AudioSourceType) -> Bool {
        admission.withLock { !$0.closed && Self.selected(source, in: $0) && !Self.failed(source, in: $0) }
    }
    var hasHealthySource: Bool {
        admission.withLock { state in
            !state.closed && ((state.microphoneSelected && !Self.failed(.microphone, in: state)) ||
                (state.systemSelected && !Self.failed(.systemAudio, in: state)))
        }
    }
    var allSelectedSourcesFailed: Bool {
        admission.withLock { state in
            (!state.microphoneSelected || Self.failed(.microphone, in: state)) &&
                (!state.systemSelected || Self.failed(.systemAudio, in: state))
        }
    }
    var ingressCounters: [AudioSourceType: LocalParakeetASRProvider.CaptureIngressSnapshot.SourceCounters] {
        admission.withLock { $0.ingressCounters }
    }
    var firstFailure: Error? { admission.withLock { $0.failures.first?.error } }
    var failures: [AudioSourceType: Error] {
        admission.withLock { state in
            Dictionary(uniqueKeysWithValues: state.failures.compactMap {
                guard let source = AudioSourceType(rawValue: $0.source) else { return nil }
                return (source, $0.error)
            })
        }
    }
    func close() {
        let failures = microphoneFailures.continuation
        admission.withLock { state in
            state.closed = true
            failures.finish()
        }
    }
    private func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType) {
        let runtime = runtime
        // SDK buffers and the existing runtime are borrowed synchronously in
        // this scope. They never enter a Task/actor; the checked state guards
        // epoch/source admission atomically with the actual bounded enqueue.
        admission.withLockUnchecked { state in
            guard !state.closed, Self.selected(source, in: state), !Self.failed(source, in: state) else { return }
            runtime.appendAudioBuffer(buffer, at: time, source: source)
            // No Task, actor hop, text processing or file I/O is introduced.
            // The aggregate belongs to this exact callback admission epoch.
            var counters = state.ingressCounters[source, default: .init()]
            counters.bufferCount += 1
            counters.frameCount += Int(buffer.frameLength)
            counters.lastBufferAt = Date()
            state.ingressCounters[source] = counters
        }
    }
    private func recordFailure(_ error: Error, source: AudioSourceType) -> Bool {
        let failures = microphoneFailures.continuation
        return admission.withLock { state in
            guard !state.closed, Self.selected(source, in: state), !Self.failed(source, in: state) else { return false }
            state.failures.append(.init(source: source.rawValue, error: error))
            if source == .microphone { failures.yield(error) }
            return true
        }
    }
    func audioEngineManager(_ manager: AudioEngineManager, didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        append(buffer, at: time, source: .microphone)
    }
    func audioEngineManager(_ manager: AudioEngineManager, didFailWith error: Error) {
        // AudioEngineManager invokes this on its own serial queue. Only source
        // admission and its bounded event are touched here; control is owned.
        _ = recordFailure(error, source: .microphone)
    }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard ObjectIdentifier(service) == systemIdentity else { return }
        append(buffer, at: time, source: .systemAudio)
    }
    @MainActor
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService, didFailWithError error: Error) {
        guard ObjectIdentifier(service) == systemIdentity,
              recordFailure(error, source: .systemAudio) else { return }
        onSystemFailure(error)
    }
}

enum ParakeetTranscriptMapper {
    static func map(_ event: ParakeetTranscriptEvent, config: ASRConfig) throws -> TranscriptSegment {
        guard event.source == ASRSource.localParakeetASR.rawValue else {
            throw ASRProviderError.providerUnavailable(
                "Parakeet helper emitted an untrusted or missing ASR source."
            )
        }
        guard event.isFinal else {
            throw ASRProviderError.providerUnavailable(
                "Local Parakeet is final-only but emitted a partial transcript."
            )
        }

        let audioSource: AudioSourceType
        if let rawSource = event.audioSource {
            guard let emittedSource = AudioSourceType(rawValue: rawSource),
                  emittedSource == .microphone || emittedSource == .systemAudio else {
                throw ASRProviderError.providerUnavailable(
                    "Parakeet helper emitted invalid audio-source metadata."
                )
            }
            let allowed = switch config.captureMode {
            case .microphoneOnly: emittedSource == .microphone
            case .systemAudioOnly: emittedSource == .systemAudio
            case .microphoneAndSystem: true
            }
            guard allowed else {
                throw ASRProviderError.providerUnavailable(
                    "Parakeet helper emitted a transcript for a disabled audio source."
                )
            }
            audioSource = emittedSource
        } else {
            switch config.captureMode {
            case .microphoneOnly: audioSource = .microphone
            case .systemAudioOnly: audioSource = .systemAudio
            case .microphoneAndSystem:
                throw ASRProviderError.providerUnavailable(
                    "Parakeet mixed capture emitted a transcript without channel attribution."
                )
            }
        }

        let expectedSpeaker: SpeakerRole = audioSource == .microphone ? .candidate : .interviewer
        if let rawSpeaker = event.speaker {
            guard let emittedSpeaker = SpeakerRole(rawValue: rawSpeaker),
                  emittedSpeaker == expectedSpeaker else {
                throw ASRProviderError.providerUnavailable(
                    "Parakeet helper emitted speaker metadata that conflicts with its audio channel."
                )
            }
        }

        return TranscriptSegment(
            id: event.segmentId,
            sessionID: config.sessionID,
            source: audioSource,
            speaker: .unknown, // Channel metadata is not speaker diarization.
            text: event.text.trimmingCharacters(in: .whitespacesAndNewlines),
            startTime: event.startTime,
            endTime: event.endTime,
            createdAt: Date(),
            confidence: event.confidence,
            asrSource: .localParakeetASR,
            asrFinalizationReason: "final",
            recognitionIsFinal: true,
            verificationFinalHostTicks: VerificationTiming.hostTicks()
        )
    }
}
