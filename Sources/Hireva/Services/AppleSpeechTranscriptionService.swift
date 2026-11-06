import AVFoundation
import Foundation
import Speech

enum TranscriptionServiceState: String, Codable, Sendable {
    case idle
    case starting
    case running
    case recoveringRoute
    case stopped
    case failed
}

struct AudioTranscriptionSessionID: Hashable, Equatable, Sendable {
    let source: AudioSourceType
}

/// Utterance-level ASR latency tracking (per speech segment, not per session)
struct UtteranceLatency: Sendable {
    let utteranceID: String
    var utteranceStartedAt: Date
    var firstPartialAt: Date?
    var firstFinalAt: Date?
    var bestTranscriptSelectedAt: Date?
    var finalizationReason: String?

    var asrFirstPartialMS: Int? {
        guard let firstPartialAt else { return nil }
        return Int(firstPartialAt.timeIntervalSince(utteranceStartedAt) * 1000)
    }

    var asrFinalMS: Int? {
        guard let firstFinalAt else { return nil }
        return Int(firstFinalAt.timeIntervalSince(utteranceStartedAt) * 1000)
    }

    var asrBestSelectedMS: Int? {
        guard let bestTranscriptSelectedAt else { return nil }
        return Int(bestTranscriptSelectedAt.timeIntervalSince(utteranceStartedAt) * 1000)
    }
}

@MainActor
final class AppleSpeechTranscriptionSession: NSObject {
    let sessionID: AudioTranscriptionSessionID
    let parentSessionID: String
    private let requiresOnDeviceRecognition: Bool
    
    private let recognizer: SFSpeechRecognizer?
    private(set) var request: SFSpeechAudioBufferRecognitionRequest?
    private(set) var recognitionTask: SFSpeechRecognitionTask?
    var isRecognitionActive: Bool {
        guard serviceState == .running else { return false }
        if simulatedTaskActive { return true }
        return recognitionTask?.state == .starting || recognitionTask?.state == .running
    }
    
    var partialTranscriptBuffer: String = ""
    var lastFinalTranscriptTimestamp: Date?
    nonisolated private let pcmInputs = AppleSpeechPCMInputSlot()
    private let pcmTestingOperations: AppleSpeechPCMTestingOperations?
    var totalBuffersAppended: Int { pcmInputs.current?.snapshot.bufferCount ?? 0 }
    var lastBufferReceivedAt: Date? { pcmInputs.current?.snapshot.lastBufferAt }
    var inFlightPCMAppendsForTesting: Int { pcmInputs.current?.inFlightAppendCount ?? 0 }
    var pcmCloseTaskForTesting: Task<Void, Never>? { pcmInputs.current?.ownedCloseTask }
    private var pcmDisplayTasks: [UUID: Task<Void, Never>] = [:]
    var ownedPCMDisplayTasksForTesting: [Task<Void, Never>] { Array(pcmDisplayTasks.values) }
    var nativePCMInput: AppleSpeechPCMInput? { pcmInputs.current }
    var pendingPCMDisplaySnapshotsForTesting: Int { pcmInputs.current?.pendingDisplaySnapshotCount ?? 0 }
    var hasUnreleasedAudioInput: Bool { pcmInputs.hasUnreleasedInput || !pcmDisplayTasks.isEmpty }
    func finishStoppingAudioInput() async {
        let displays = Array(pcmDisplayTasks.values)
        await pcmInputs.finishStopping()
        for task in displays { await task.value }
    }
    var lastError: Error?
    
    // ASR Finalization quality fix properties
    private(set) var lastPartialTranscript: String = ""
    private(set) var lastPartialTranscriptUpdatedAt: Date?
    private(set) var lastFinalTranscript: String = ""
    private(set) var bestTranscriptUsed: String = ""
    private(set) var finalizationReason: String = ""
    
    // Current utterance ID to prevent duplication in transcript feed
    private var utteranceID: String = UUID().uuidString
    private var recognitionTaskID: String = UUID().uuidString
    var recognitionTaskIDForTesting: String { recognitionTaskID }
    private var recognitionEventSequence: Int = 0
    private let recognitionFence = CaptureStartFence()
    
    // Session-level ASR timestamps
    private(set) var sessionStartedAt: Date?
    private(set) var firstPartialReceivedAt: Date?
    private(set) var firstFinalReceivedAt: Date?
    
    // Utterance-level ASR latency (tracks per-utterance, not per-session)
    private(set) var currentUtteranceLatency: UtteranceLatency?
    private(set) var lastCompletedUtteranceLatency: UtteranceLatency?
    
    private let onEmit: @MainActor (TranscriptSegment) -> Void
    private let onStateChange: @MainActor () -> Void
    private let onRuntimeEvent: (@MainActor (TranscriptRuntimeEvent) -> Void)?
    private let onFailure: (@MainActor (Error) -> Void)?
    
    // Test simulation hooks
    var simulatedTaskActive = false
    
    private(set) var serviceState: TranscriptionServiceState = .idle {
        didSet {
            onStateChange()
        }
    }
    
    init(
        sessionID: AudioTranscriptionSessionID,
        parentSessionID: String,
        requiresOnDeviceRecognition: Bool = false,
        onEmit: @escaping @MainActor (TranscriptSegment) -> Void,
        onStateChange: @escaping @MainActor () -> Void,
        onRuntimeEvent: (@MainActor (TranscriptRuntimeEvent) -> Void)? = nil,
        onFailure: (@MainActor (Error) -> Void)? = nil,
        pcmTestingOperations: AppleSpeechPCMTestingOperations? = nil
    ) {
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        self.onEmit = onEmit
        self.onStateChange = onStateChange
        self.onRuntimeEvent = onRuntimeEvent
        self.onFailure = onFailure
        self.pcmTestingOperations = pcmTestingOperations
        // Initialize isolated SFSpeechRecognizer for this session
        self.recognizer = SFSpeechRecognizer()
        super.init()
    }
    
    private func getWordCount(_ text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }
    
    private func resetUtteranceLatency() {
        let newID = utteranceID
        currentUtteranceLatency = UtteranceLatency(
            utteranceID: newID,
            utteranceStartedAt: Date()
        )
    }
    
    func start() async throws {
        // Test environment safety bypass
        #if DEBUG
        let isTesting = ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("test") ||
                        ProcessInfo.processInfo.environment["SWIFT_TESTING"] != nil ||
                        NSClassFromString("XCTestCase") != nil
        if isTesting {
            stop()
            await finishStoppingAudioInput()
            self.partialTranscriptBuffer = ""
            self.lastError = nil
            self.lastPartialTranscript = ""
            self.lastPartialTranscriptUpdatedAt = nil
            self.lastFinalTranscript = ""
            self.bestTranscriptUsed = ""
            self.finalizationReason = ""
            self.utteranceID = UUID().uuidString
            self.recognitionTaskID = UUID().uuidString
            self.recognitionEventSequence = 0
            self.sessionStartedAt = Date()
            self.firstPartialReceivedAt = nil
            self.firstFinalReceivedAt = nil
            resetUtteranceLatency()
            self.serviceState = .running
            self.simulatedTaskActive = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            self.request = request
            installPCMInput(AppleSpeechPCMInput(request: request, simulated: true, operations: pcmTestingOperations))
            self.onRuntimeEvent?(.audioStarted(sessionID: parentSessionID, timestamp: Date()))
            print("[DualAudio] [TestMock] \(sessionID.source == .microphone ? "mic" : "system") ASR session created successfully.")
            return
        }
        #endif
        
        guard let recognizer, recognizer.isAvailable else {
            self.serviceState = .failed
            throw TranscriptionError.unavailable("Apple Speech recognition is not available for the locale.")
        }
        
        stop()
        await finishStoppingAudioInput()
        self.partialTranscriptBuffer = ""
        self.lastError = nil
        self.lastPartialTranscript = ""
        self.lastPartialTranscriptUpdatedAt = nil
        self.lastFinalTranscript = ""
        self.bestTranscriptUsed = ""
        self.finalizationReason = ""
        self.utteranceID = UUID().uuidString
        self.recognitionTaskID = UUID().uuidString
        self.recognitionEventSequence = 0
        self.sessionStartedAt = Date()
        self.firstPartialReceivedAt = nil
        self.firstFinalReceivedAt = nil
        resetUtteranceLatency()
        self.serviceState = .starting
        
        let request: SFSpeechAudioBufferRecognitionRequest
        do {
            request = try AppleSpeechRequestFactory.make(
                requiresOnDeviceRecognition: requiresOnDeviceRecognition,
                supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition)
        } catch {
            self.serviceState = .failed
            throw error
        }
        self.request = request
        installPCMInput(AppleSpeechPCMInput(request: request, simulated: false, operations: pcmTestingOperations))
        
        print("[DualAudio] \(sessionID.source == .microphone ? "mic" : "system") ASR session created: \(sessionID.source.rawValue)")
        
        self.serviceState = .running
        self.onRuntimeEvent?(.audioStarted(sessionID: parentSessionID, timestamp: Date()))

        let recognitionRevision = recognitionFence.begin()
        let capturedRecognitionTaskID = recognitionTaskID
        // SDK result/error objects are borrowed synchronously on the documented
        // main OperationQueue; no native result crosses an unowned Swift Task.
        recognizer.queue = .main
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self, self.recognitionFence.isCurrent(recognitionRevision),
                    self.serviceState == .running else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.recognitionEventSequence += 1
                    self.partialTranscriptBuffer = text

                    if !result.isFinal {
                        // Track partial transcript and its timestamp
                        self.lastPartialTranscript = text
                        self.lastPartialTranscriptUpdatedAt = Date()

                        // Utterance-level ASR latency: record first partial
                        if self.firstPartialReceivedAt == nil {
                            self.firstPartialReceivedAt = Date()
                        }
                        if self.currentUtteranceLatency?.firstPartialAt == nil {
                            self.currentUtteranceLatency?.firstPartialAt = Date()
                        }

                        if self.sessionID.source == .microphone {
                            print("[DualAudio] mic partial characters=\(text.count)")
                        } else {
                            print("[DualAudio] system partial characters=\(text.count)")
                        }

                        // Emit partial using current utteranceID to overwrite in place
                        self.emit(text: text, id: self.utteranceID)
                        self.onStateChange()
                    } else {
                        // Final result arrived!
                        let finalReceivedAt = Date()
                        self.lastFinalTranscriptTimestamp = finalReceivedAt
                        self.lastFinalTranscript = text

                        // Session-level: record first final
                        if self.firstFinalReceivedAt == nil {
                            self.firstFinalReceivedAt = finalReceivedAt
                        }
                        // Utterance-level: record first final
                        if self.currentUtteranceLatency?.firstFinalAt == nil {
                            self.currentUtteranceLatency?.firstFinalAt = finalReceivedAt
                        }

                        if self.sessionID.source == .microphone {
                            print("[DualAudio] mic final segment source=microphone characters=\(text.count)")
                        } else {
                            print("[DualAudio] system final segment source=systemAudio characters=\(text.count)")
                        }

                        // Finalization Quality Logic
                        let bestTranscript: String
                        let wordCountFinal = self.getWordCount(text)
                        let wordCountPartial = self.getWordCount(self.lastPartialTranscript)
                        let timeSincePartialUpdate = self.lastPartialTranscriptUpdatedAt.map { Date().timeIntervalSince($0) } ?? Double.greatestFiniteMagnitude

                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.lastPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            bestTranscript = self.lastPartialTranscript
                            self.bestTranscriptUsed = self.lastPartialTranscript
                            self.finalizationReason = "final empty but partial meaningful"
                        } else if wordCountFinal < (wordCountPartial + 1) / 2 && timeSincePartialUpdate <= 5.0 && !self.lastPartialTranscript.isEmpty {
                            bestTranscript = self.lastPartialTranscript
                            self.bestTranscriptUsed = self.lastPartialTranscript
                            self.finalizationReason = "final much shorter than recent partial"
                        } else {
                            bestTranscript = text
                            self.bestTranscriptUsed = text
                            self.finalizationReason = "final is longer or similar"
                        }

                        // Record best-transcript-selected timestamp and finalization reason
                        let bestSelectedAt = Date()
                        self.currentUtteranceLatency?.bestTranscriptSelectedAt = bestSelectedAt
                        self.currentUtteranceLatency?.finalizationReason = self.finalizationReason

                        print("[DualAudio] finalization resolved. reason: \"\(self.finalizationReason)\" | characters=\(bestTranscript.count) | asrFirstPartialMS=\(self.currentUtteranceLatency?.asrFirstPartialMS ?? -1) asrFinalMS=\(self.currentUtteranceLatency?.asrFinalMS ?? -1) asrBestSelectedMS=\(self.currentUtteranceLatency?.asrBestSelectedMS ?? -1)")

                        // Complete utterance latency and archive it
                        self.lastCompletedUtteranceLatency = self.currentUtteranceLatency

                        // Emit the finalized best transcript using the SAME utteranceID to overwrite any partials
                        self.emitWithLatency(text: bestTranscript, id: self.utteranceID)
                        self.onStateChange()

                        // Rotate to a new utterance ID for subsequent inputs
                        self.utteranceID = UUID().uuidString
                        self.resetUtteranceLatency()
                    }
                } else if let error {
                    self.receiveRecognitionError(error, recognitionTaskID: capturedRecognitionTaskID)
                }
            }
        }
    }

    /// Native error callbacks and deterministic tests enter this same boundary.
    /// The already existing recognition task identity prevents an old callback
    /// from affecting a replacement request on this Session.
    func receiveRecognitionError(_ error: Error, recognitionTaskID expectedID: String) {
        guard recognitionTaskID == expectedID, serviceState == .running else { return }
        print("[DualAudio] \(sessionID.source.rawValue) recognition task error: code=\((error as NSError).code)")
        // Revoke recognition delivery and capture old resources before any
        // synchronous observer can start a replacement. Never re-read its input.
        recognitionFence.invalidate()
        let capturedInput = pcmInputs.current
        let capturedTask = recognitionTask
        recognitionTask = nil
        request = nil
        simulatedTaskActive = false
        capturedInput?.close()
        capturedTask?.cancel()
        lastError = error
        serviceState = .failed
        // onStateChange may synchronously start another recognition round.
        guard recognitionTaskID == expectedID, serviceState == .failed else { return }
        onFailure?(error)
    }

    #if DEBUG
    @MainActor
    func startSimulatedRecognitionForDiagnostic() {
        stop()
        self.partialTranscriptBuffer = ""
        self.lastError = nil
        self.lastPartialTranscript = ""
        self.lastPartialTranscriptUpdatedAt = nil
        self.lastFinalTranscript = ""
        self.bestTranscriptUsed = ""
        self.finalizationReason = ""
        self.utteranceID = UUID().uuidString
        self.recognitionTaskID = UUID().uuidString
        self.recognitionEventSequence = 0
        self.sessionStartedAt = Date()
        self.firstPartialReceivedAt = nil
        self.firstFinalReceivedAt = nil
        resetUtteranceLatency()
        self.serviceState = .running
        self.simulatedTaskActive = true
        let request = SFSpeechAudioBufferRecognitionRequest()
        self.request = request
        installPCMInput(AppleSpeechPCMInput(request: request, simulated: true, operations: pcmTestingOperations))
        self.onRuntimeEvent?(.audioStarted(sessionID: parentSessionID, timestamp: Date()))
    }
    #endif
    
    /// The native caller sees only the checked input slot. Presentation and
    /// recognizer state remain MainActor; a PCM callback never waits for it.
    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        _ = pcmInputs.current?.append(buffer)
    }

    private func installPCMInput(_ input: AppleSpeechPCMInput) {
        pcmInputs.replace(input)
        let id = UUID()
        let task = Task { @MainActor [weak self, input] in
            defer { self?.pcmDisplayTasks[id] = nil }
            for await _ in input.displaySignals {
                guard let batch = input.takePendingDisplayBatch(), let self else { continue }
                self.onRuntimeEvent?(.audioBufferReceived(sessionID: self.parentSessionID,
                    frameCount: batch.frameCount, timestamp: batch.timestamp, bufferCount: batch.bufferCount,
                    source: self.sessionID.source))
                self.onStateChange()
            }
        }
        pcmDisplayTasks[id] = task
    }

    func stop() {
        recognitionFence.invalidate()
        recognitionTask?.cancel()
        recognitionTask = nil
        pcmInputs.current?.close()
        request = nil
        simulatedTaskActive = false
        self.serviceState = .stopped
    }
    
    @MainActor
    func simulateEmit(text: String, isFinal: Bool = false) {
        guard serviceState == .running else { return }
        recognitionEventSequence += 1
        self.partialTranscriptBuffer = text
        if !isFinal {
            self.lastPartialTranscript = text
            self.lastPartialTranscriptUpdatedAt = Date()
            // Track utterance-level partial latency
            if self.currentUtteranceLatency?.firstPartialAt == nil {
                self.currentUtteranceLatency?.firstPartialAt = Date()
            }
            if self.firstPartialReceivedAt == nil {
                self.firstPartialReceivedAt = Date()
            }
            self.emit(text: text, id: self.utteranceID)
        } else {
            let finalAt = Date()
            self.lastFinalTranscriptTimestamp = finalAt
            self.lastFinalTranscript = text
            
            // Track utterance-level final latency
            if self.currentUtteranceLatency?.firstFinalAt == nil {
                self.currentUtteranceLatency?.firstFinalAt = finalAt
            }
            if self.firstFinalReceivedAt == nil {
                self.firstFinalReceivedAt = finalAt
            }
            
            let bestTranscript: String
            let wordCountFinal = self.getWordCount(text)
            let wordCountPartial = self.getWordCount(self.lastPartialTranscript)
            let timeSincePartialUpdate = self.lastPartialTranscriptUpdatedAt.map { Date().timeIntervalSince($0) } ?? Double.greatestFiniteMagnitude
            
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.lastPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bestTranscript = self.lastPartialTranscript
                self.bestTranscriptUsed = self.lastPartialTranscript
                self.finalizationReason = "final empty but partial meaningful"
            } else if wordCountFinal < (wordCountPartial + 1) / 2 && timeSincePartialUpdate <= 5.0 && !self.lastPartialTranscript.isEmpty {
                bestTranscript = self.lastPartialTranscript
                self.bestTranscriptUsed = self.lastPartialTranscript
                self.finalizationReason = "final much shorter than recent partial"
            } else {
                bestTranscript = text
                self.bestTranscriptUsed = text
                self.finalizationReason = "final is longer or similar"
            }
            
            self.currentUtteranceLatency?.bestTranscriptSelectedAt = Date()
            self.currentUtteranceLatency?.finalizationReason = self.finalizationReason
            self.lastCompletedUtteranceLatency = self.currentUtteranceLatency
            
            self.emitWithLatency(text: bestTranscript, id: self.utteranceID)
            self.utteranceID = UUID().uuidString
            self.resetUtteranceLatency()
        }
        self.onStateChange()
    }
    
    @MainActor
    private func emit(text: String, id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let (deviceName, outputDeviceName, deviceID, speaker) = deviceInfo()
        
        let segment = TranscriptSegment(
            id: id,
            sessionID: parentSessionID,
            source: sessionID.source,
            speaker: speaker,
            text: trimmed,
            startTime: nil,
            endTime: nil,
            createdAt: Date(),
            inputDeviceName: deviceName,
            outputDeviceName: outputDeviceName,
            deviceID: deviceID,
            confidence: 1.0,
            asrSource: .appleASR,
            asrFinalizationReason: "partial",
            recognitionTaskID: recognitionTaskID,
            recognitionEventSequence: recognitionEventSequence,
            sourceTextStartUTF16: 0,
            sourceTextEndUTF16: (trimmed as NSString).length,
            recognitionIsFinal: false
        )
        onEmit(segment)
    }
    
    /// Emit with ASR latency data from the completed utterance
    @MainActor
    private func emitWithLatency(text: String, id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let (deviceName, outputDeviceName, deviceID, speaker) = deviceInfo()
        let latency = lastCompletedUtteranceLatency
        
        let segment = TranscriptSegment(
            id: id,
            sessionID: parentSessionID,
            source: sessionID.source,
            speaker: speaker,
            text: trimmed,
            startTime: nil,
            endTime: nil,
            createdAt: Date(),
            inputDeviceName: deviceName,
            outputDeviceName: outputDeviceName,
            deviceID: deviceID,
            confidence: 1.0,
            asrSource: .appleASR,
            asrFirstPartialMS: latency?.asrFirstPartialMS,
            asrFinalMS: latency?.asrFinalMS,
            asrBestSelectedMS: latency?.asrBestSelectedMS,
            asrFinalizationReason: latency?.finalizationReason,
            recognitionTaskID: recognitionTaskID,
            recognitionEventSequence: recognitionEventSequence,
            sourceTextStartUTF16: 0,
            sourceTextEndUTF16: (trimmed as NSString).length,
            recognitionIsFinal: true
        )
        onEmit(segment)
    }
    
    @MainActor
    private func deviceInfo() -> (String?, String?, String?, SpeakerRole) {
        if sessionID.source == .microphone {
            return (
                AudioDeviceManager.shared.currentInputDeviceName,
                nil,
                AudioDeviceManager.shared.currentInputDeviceID,
                .unknown
            )
        } else {
            return (
                nil,
                "System Audio Capture",
                "system_audio",
                .unknown
            )
        }
    }
}

/// Per-instance stop boundary for deterministic service callback tests. Live
/// construction uses nil and retains the existing native cleanup calls.
struct AppleSpeechStopTestingOperations {
    let unregisterMicrophone: (any AudioEngineBufferDelegate) -> Void
    let unregisterSystemAudio: (any SystemAudioBufferDelegate) -> Void
    let stopSystemAudio: () -> Void
}

@MainActor
final class AppleSpeechTranscriptionService: NSObject, TranscriptionProvider {
    let providerName = "Apple Speech Session Manager"
    
    static let maximumPendingTranscriptEvents = 64
    static let maximumTranscriptTextBytes = 64 * 1_024

    // One record owns this stream's continuation and terminal cause. A Live
    // consumer may retain its read-only cause after this service starts a new
    // stream; no newer reset/error can rewrite the captured older terminal.
    @MainActor
    final class TranscriptOutput {
        fileprivate let stream: AsyncStream<TranscriptSegment>
        fileprivate let continuation: AsyncStream<TranscriptSegment>.Continuation
        // Immutable aliases after binding: the native owner remains the sole
        // authority for this receipt's stop attempts and release outcome.
        fileprivate private(set) var systemCaptureReceipt: SystemAudioCaptureStopReceipt?
        fileprivate func bindSystemCapture(_ receipt: SystemAudioCaptureStopReceipt) {
            precondition(systemCaptureReceipt == nil)
            systemCaptureReceipt = receipt
        }
        private enum Terminal { case open, finished(Error?) }
        private var terminal: Terminal = .open
        fileprivate var terminalError: Error? {
            if case .finished(let error) = terminal { return error }
            return nil
        }
        fileprivate func finish(_ error: Error? = nil) {
            guard case .open = terminal else { return }
            terminal = .finished(error)
            continuation.finish()
        }
        fileprivate init() {
            let pair = AsyncStream<TranscriptSegment>.makeStream(
                bufferingPolicy: .bufferingOldest(AppleSpeechTranscriptionService.maximumPendingTranscriptEvents))
            stream = pair.stream
            continuation = pair.continuation
        }
    }
    private var transcriptOutput: TranscriptOutput?
    private let captureFence = CaptureStartFence()
    private var currentCaptureRevision: UInt64?
    private var routeRecoveryTask: Task<Void, Never>?
    private var routeRecoveryID: UUID?
    private var retiringRouteRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var retiringSessions: [AppleSpeechTranscriptionSession] = []
    private let stopTestingOperations: AppleSpeechStopTestingOperations?
    private let pcmTestingOperations: AppleSpeechPCMTestingOperations?
    private let systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService
    private let usesControlledSystemCapture: Bool
    var onAudioInputDrainForTesting: (() -> Void)?
    private let inactiveReceiver = AppleSpeechNativeReceiver(source: .microphone, input: nil,
        controls: AppleSpeechNativeControlIngress(accepting: false))
    private var microphoneReceiver: AppleSpeechNativeReceiver?
    private var systemReceiver: AppleSpeechNativeReceiver?
    // Recognition and its synthetic/diagnostic receiver do not own device I/O.
    // Registration is authority only after the actual native owner accepts it.
    private var registeredMicrophoneReceiver: AppleSpeechNativeReceiver?
    private var registeredSystemCapture: (receiver: AppleSpeechNativeReceiver, receipt: SystemAudioCaptureStopReceipt, terminalCaptureRevision: UInt64?)?
    // One retained native receipt also identifies its queued terminal signal.
    // A new recognition submission revokes only the old terminal revision;
    // failed native cleanup remains recoverable through this same receipt.
    private var retiringSystemCapture: (receipt: SystemAudioCaptureStopReceipt, failure: Error?, terminalCaptureRevision: UInt64?)?
    var captureCleanupFailure: Error? { retiringSystemCapture?.failure }
    func ownsCurrentSystemAudioCapture(_ capture: ScreenCaptureKitSystemAudioCaptureService) -> Bool {
        guard capture === systemAudioCaptureService,
            let receipt = registeredSystemCapture?.receipt ?? retiringSystemCapture?.receipt else { return false }
        return capture.isCurrentCaptureOwner(receipt)
    }
    func hasMostRecentSystemAudioCaptureReceipt(_ capture: ScreenCaptureKitSystemAudioCaptureService) -> Bool {
        guard capture === systemAudioCaptureService else { return false }
        if let registeredSystemCapture, registeredSystemCapture.terminalCaptureRevision != nil {
            return capture.isMostRecentCaptureReceipt(registeredSystemCapture.receipt)
        }
        guard let retiringSystemCapture, retiringSystemCapture.terminalCaptureRevision != nil else { return false }
        return capture.isMostRecentCaptureReceipt(retiringSystemCapture.receipt)
    }
    /// A newer recognition request revokes presentation only. Both exact
    /// receipts remain available to their native stop/drain owner.
    func invalidateSystemAudioTerminalAttribution() {
        registeredSystemCapture?.terminalCaptureRevision = nil
        retiringSystemCapture?.terminalCaptureRevision = nil
    }
    private var nativeControlTasks: [UUID: (controls: AppleSpeechNativeControlIngress, task: Task<Void, Never>)] = [:]
    var onNativeControlHandledForTesting: ((UInt64, AudioSourceType) -> Void)?
    var pendingNativeControlsForTesting: Int { nativeControlTasks.values.reduce(0) { $0 + $1.controls.pendingControlCount } }
    var ownedNativeControlWorkersForTesting: [(controls: AppleSpeechNativeControlIngress, task: Task<Void, Never>)] {
        Array(nativeControlTasks.values)
    }
    // Actual native registration and regression tests share these exact handles.
    var microphoneCaptureReceiver: any AudioEngineBufferDelegate { microphoneReceiver ?? inactiveReceiver }
    var systemAudioCaptureReceiver: any SystemAudioBufferDelegate { systemReceiver ?? inactiveReceiver }
    var routeRecoveryTaskForTesting: Task<Void, Never>? { routeRecoveryTask }
    var terminalError: Error? { transcriptOutput?.terminalError }
    
    private(set) var microphoneSession: AppleSpeechTranscriptionSession?
    private(set) var systemAudioSession: AppleSpeechTranscriptionSession?

    var hasUnreleasedAudioInput: Bool {
        let captured = [microphoneSession, systemAudioSession].compactMap { $0 } + retiringSessions
        return registeredMicrophoneReceiver != nil || registeredSystemCapture != nil ||
            retiringSystemCapture?.receipt.hasUnreleasedResource == true ||
            retiringSystemCapture?.failure != nil || captured.contains { $0.hasUnreleasedAudioInput } ||
            nativeControlTasks.values.contains { !$0.controls.isAccepting } ||
            !retiringRouteRecoveryTasks.isEmpty
    }

    /// Capture exact sessions and route workers before suspension. Cleanup never
    /// re-reads a later current session or stops a replacement capture epoch.
    func finishStoppingAudioInput() async {
        let routes = retiringRouteRecoveryTasks
        // A delayed old join observes only closed receiver workers. An open
        // replacement receiver belongs to the later capture epoch.
        let nativeControls = nativeControlTasks.values.filter { !$0.controls.isAccepting }.map(\.task)
        // finish joins only already stopped sessions. A delayed old caller
        // cannot close a later currently active Session on this service.
        let captured = retiringSessions
        let nativeStop = retiringSystemCapture?.receipt
        onAudioInputDrainForTesting?()
        for task in nativeControls { await task.value }
        for task in routes.values { await task.value }
        for session in captured { await session.finishStoppingAudioInput() }
        for id in routes.keys { retiringRouteRecoveryTasks[id] = nil }
        retiringSessions.removeAll { candidate in
            captured.contains { $0 === candidate } && !candidate.hasUnreleasedAudioInput
        }
        if let nativeStop {
            do {
                try await systemAudioCaptureService.finishStoppingSystemAudioCapture(capturedReceipt: nativeStop)
                if retiringSystemCapture?.receipt === nativeStop { retiringSystemCapture?.failure = nil }
            } catch {
                if retiringSystemCapture?.receipt === nativeStop { retiringSystemCapture?.failure = error }
            }
        }
    }

    /// Explicit retry authority is the retained resource receipt. A later
    /// recognition session or another owner's stream is never used as input.
    func retryStoppingAudioInput() {
        guard let captured = retiringSystemCapture, captured.failure != nil else { return }
        _ = systemAudioCaptureService.retryStoppingSystemAudioCapture(capturedReceipt: captured.receipt)
    }

    private func retainStoppedSession(_ session: AppleSpeechTranscriptionSession) {
        // A captured route worker may acquire an input after cancellation.
        // Retain even a not-yet-started Session until that exact worker exits.
        guard !retiringSessions.contains(where: { $0 === session }) else { return }
        retiringSessions.append(session)
    }
    
    private var isRecording = false
    private var captureMode: AudioCaptureMode = .microphoneAndSystem
    private var requiresOnDeviceRecognition = false
    private var currentParentSessionID: String?
    
    // Callback to let AppState know that session parameters changed (useful for diagnostics update triggers)
    var onSessionStateChanged: (@MainActor () -> Void)?
    var onRuntimeEvent: (@MainActor (TranscriptRuntimeEvent) -> Void)?
    
    var segments: AsyncStream<TranscriptSegment> {
        if transcriptOutput == nil { resetStream() }
        return transcriptOutput!.stream
    }

    private func resetStream() {
        transcriptOutput = TranscriptOutput()
    }

    var currentTranscriptOutputIdentity: ObjectIdentifier? {
        transcriptOutput.map { ObjectIdentifier($0) }
    }

    /// Capture the error reader synchronously alongside `segments`. The old
    /// output record remains owned only by that exact consumer until it exits.
    func captureTerminalErrorReader() -> @MainActor () -> Error? {
        let output = transcriptOutput
        return { output?.terminalError }
    }

    /// A wrapper retains the same output record through startup, normal finish
    /// and failed cleanup. Replacement never grants it the new record's stop.
    func stop(capturedOutput: TranscriptOutput, retryFailedResource: Bool) {
        if transcriptOutput === capturedOutput {
            stop(retryFailedResource: retryFailedResource)
            return
        }
        capturedOutput.finish()
        if let receipt = capturedOutput.systemCaptureReceipt {
            _ = systemAudioCaptureService.stopSystemAudioCapture(
                capturedReceipt: receipt, retryFailed: retryFailedResource)
        }
    }

    func captureCleanupFailure(capturedOutput: TranscriptOutput) -> Error? {
        guard let receipt = capturedOutput.systemCaptureReceipt,
            retiringSystemCapture?.receipt === receipt else { return nil }
        return retiringSystemCapture?.failure
    }

    private func admitTranscriptSegment(_ segment: TranscriptSegment, captureRevision: UInt64) {
        guard captureFence.isCurrent(captureRevision), let output = transcriptOutput else { return }
        let error: TranscriptionError?
        if segment.text.utf8.count > Self.maximumTranscriptTextBytes {
            error = .unavailable("Apple Speech transcript text exceeded \(Self.maximumTranscriptTextBytes) bytes.")
        } else if case .dropped = output.continuation.yield(segment) {
            error = .unavailable("Apple Speech transcript output buffer overflow (\(Self.maximumPendingTranscriptEvents) events).")
        } else { error = nil }
        guard let error else { return }
        // Already admitted partial/final values retain order. End both selected
        // inputs through their existing exact native/PCM owners; external drain
        // still proves actual resource release and never authorizes a retry.
        output.finish(error)
        stop(retryFailedResource: false)
    }

    override convenience init() { self.init(stopTestingOperations: nil) }

    init(stopTestingOperations: AppleSpeechStopTestingOperations?,
        pcmTestingOperations: AppleSpeechPCMTestingOperations? = nil,
        systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService? = nil) {
        self.stopTestingOperations = stopTestingOperations
        self.pcmTestingOperations = pcmTestingOperations
        self.systemAudioCaptureService = systemAudioCaptureService ?? .shared
        self.usesControlledSystemCapture = systemAudioCaptureService != nil
        super.init()
    }
    
    func start(sessionID: String) async throws {
        try await start(sessionID: sessionID, captureMode: .microphoneAndSystem)
    }
    
    func start(sessionID: String, captureMode: AudioCaptureMode) async throws {
        try await start(sessionID: sessionID, captureMode: captureMode, requiresOnDeviceRecognition: false)
    }

    func start(sessionID: String, captureMode: AudioCaptureMode,
        requiresOnDeviceRecognition: Bool) async throws {
        try await start(sessionID: sessionID, captureMode: captureMode,
            requiresOnDeviceRecognition: requiresOnDeviceRecognition, onOutputOwned: nil)
    }

    func start(sessionID: String, captureMode: AudioCaptureMode,
        requiresOnDeviceRecognition: Bool,
        onOutputOwned: (@MainActor (TranscriptOutput) -> Void)?) async throws {
        // A start is not permission to hide/retry a failed native release.
        if let captureCleanupFailure { throw captureCleanupFailure }
        invalidateSystemAudioTerminalAttribution()
        let captureRevision = captureFence.begin()
        let output = TranscriptOutput()
        // Commit pending output before cleanup callbacks or the first await.
        // Old stopped Sessions may synchronously submit a newer recognition.
        closeCurrentInput(retryFailedResource: false, pendingOutput: output)
        onOutputOwned?(output)
        await finishStoppingAudioInput()
        guard captureFence.isCurrent(captureRevision), transcriptOutput === output,
            !Task.isCancelled else { throw CancellationError() }
        if let captureCleanupFailure { throw captureCleanupFailure }
        currentCaptureRevision = captureRevision
        
        self.currentParentSessionID = sessionID
        self.captureMode = captureMode
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        self.isRecording = true
        
        print("[DualAudio] mode = \(captureMode.rawValue)")
        
        #if DEBUG
        let isTesting = ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("test") ||
                        ProcessInfo.processInfo.environment["SWIFT_TESTING"] != nil ||
                        NSClassFromString("XCTestCase") != nil
        #else
        let isTesting = false
        #endif
        
        let micRequired = (captureMode == .microphoneOnly || captureMode == .microphoneAndSystem)
        let systemRequired = (captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem)
        
        do {
            if micRequired {
                print("[DualAudio] starting mic capture")
                let micSessionID = AudioTranscriptionSessionID(source: .microphone)
                let session = AppleSpeechTranscriptionSession(
                    sessionID: micSessionID,
                    parentSessionID: sessionID,
                    requiresOnDeviceRecognition: requiresOnDeviceRecognition,
                    onEmit: { [weak self] segment in
                        guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                        self.admitTranscriptSegment(segment, captureRevision: captureRevision)
                    },
                    onStateChange: { [weak self] in
                        guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                        self.onSessionStateChanged?()
                    },
                    onRuntimeEvent: { [weak self] event in
                        guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                        self.onRuntimeEvent?(event)
                    },
                    onFailure: { [weak self] error in
                        self?.handleSessionFailure(error, captureRevision: captureRevision)
                    },
                    pcmTestingOperations: pcmTestingOperations
                )
                self.microphoneSession = session
                try await session.start()
                guard captureFence.isCurrent(captureRevision), !Task.isCancelled else {
                    session.stop()
                    throw CancellationError()
                }

                microphoneReceiver = makeNativeReceiver(session: session, captureRevision: captureRevision)
                if !isTesting {
                    // Register to AudioEngineManager
                    try AudioEngineManager.shared.register(microphoneCaptureReceiver).get()
                    registeredMicrophoneReceiver = microphoneReceiver
                }
            }

            if systemRequired {
                print("[DualAudio] starting system capture")
                let systemSessionID = AudioTranscriptionSessionID(source: .systemAudio)
                let session = AppleSpeechTranscriptionSession(
                    sessionID: systemSessionID,
                    parentSessionID: sessionID,
                    requiresOnDeviceRecognition: requiresOnDeviceRecognition,
                    onEmit: { [weak self] segment in
                        guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                        self.admitTranscriptSegment(segment, captureRevision: captureRevision)
                    },
                    onStateChange: { [weak self] in
                        guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                        self.onSessionStateChanged?()
                    },
                    onRuntimeEvent: { [weak self] event in
                        guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                        self.onRuntimeEvent?(event)
                    },
                    onFailure: { [weak self] error in
                        self?.handleSessionFailure(error, captureRevision: captureRevision)
                    },
                    pcmTestingOperations: pcmTestingOperations
                )
                self.systemAudioSession = session
                try await session.start()
                guard captureFence.isCurrent(captureRevision), !Task.isCancelled else {
                    session.stop()
                    throw CancellationError()
                }

                systemReceiver = makeNativeReceiver(session: session, captureRevision: captureRevision)
                if !isTesting || usesControlledSystemCapture {
                    // The controlled instance exercises this same native owner
                    // path without granting access to a real capture device.
                    let receiver = systemAudioCaptureReceiver
                    let capturedReceiver = systemReceiver
                    let owned = systemAudioCaptureService.beginSystemAudioCapture(onOwned: { [self] receipt in
                        output.bindSystemCapture(receipt)
                        if let capturedReceiver { registeredSystemCapture = (capturedReceiver, receipt, captureRevision) }
                        systemAudioCaptureService.register(receiver, capturedReceipt: receipt)
                    })
                    try await systemAudioCaptureService.finishStartingSystemAudioCapture(
                        capturedStart: owned.startup, capturedReceipt: owned.receipt)
                    guard captureFence.isCurrent(captureRevision), !Task.isCancelled else { throw CancellationError() }
                }
            }

            // Concurrent-session guard check
            if captureMode == .microphoneAndSystem {
                let micActive = microphoneSession?.isRecognitionActive == true
                let sysActive = systemAudioSession?.isRecognitionActive == true
                if !micActive || !sysActive {
                    let errorMsg = "Apple Speech could not run two concurrent transcription streams. Use System Audio Only / Manual Capture or configure an alternate ASR provider."
                    print("[DualAudio] Concurrent session guard failed! micActive: \(micActive), sysActive: \(sysActive)")
                    throw TranscriptionError.unavailable(errorMsg)
                }
            }
        } catch {
            if captureFence.isCurrent(captureRevision) {
                transcriptOutput?.finish(error)
                stop(retryFailedResource: false)
            }
            throw error
        }
    }

    #if DEBUG
    @MainActor
    func startDiagnosticSystemAudioSession(sessionID: String) {
        invalidateSystemAudioTerminalAttribution()
        let captureRevision = captureFence.begin()
        let output = TranscriptOutput()
        closeCurrentInput(retryFailedResource: false, pendingOutput: output)
        guard captureFence.isCurrent(captureRevision), transcriptOutput === output else { return }
        currentCaptureRevision = captureRevision
        self.currentParentSessionID = sessionID
        self.captureMode = .systemAudioOnly
        self.isRecording = true

        let systemSessionID = AudioTranscriptionSessionID(source: .systemAudio)
        let session = AppleSpeechTranscriptionSession(
            sessionID: systemSessionID,
            parentSessionID: sessionID,
            onEmit: { [weak self] segment in
                guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                self.admitTranscriptSegment(segment, captureRevision: captureRevision)
            },
            onStateChange: { [weak self] in
                guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                self.onSessionStateChanged?()
            },
            onRuntimeEvent: { [weak self] event in
                guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                self.onRuntimeEvent?(event)
            },
            pcmTestingOperations: pcmTestingOperations
        )
        self.systemAudioSession = session
        session.startSimulatedRecognitionForDiagnostic()
        systemReceiver = makeNativeReceiver(session: session, captureRevision: captureRevision)
    }
    #endif
    
    func stop() { stop(retryFailedResource: true) }

    func stop(retryFailedResource: Bool) {
        closeCurrentInput(retryFailedResource: retryFailedResource, pendingOutput: nil)
    }

    private func closeCurrentInput(retryFailedResource: Bool, pendingOutput: TranscriptOutput?) {
        // A pending start already revoked the old capture fence. Plain stop
        // revokes the current one; both paths close only captured old resources.
        if pendingOutput == nil { captureFence.invalidate() }
        let oldOutput = transcriptOutput
        if let pendingOutput { transcriptOutput = pendingOutput }
        currentCaptureRevision = nil
        let microphone = microphoneSession
        let system = systemAudioSession
        let microphoneReceiver = self.microphoneReceiver
        let systemReceiver = self.systemReceiver
        let registeredMicrophone = registeredMicrophoneReceiver
        let registeredSystem = registeredSystemCapture
        // Revoke the exact current registration before any synchronous state
        // observer can create a replacement recognition session.
        self.microphoneSession = nil
        self.systemAudioSession = nil
        self.microphoneReceiver = nil
        self.systemReceiver = nil
        registeredMicrophoneReceiver = nil
        registeredSystemCapture = nil
        isRecording = false
        currentParentSessionID = nil
        microphoneReceiver?.close()
        systemReceiver?.close()
        for entry in nativeControlTasks.values { entry.controls.close() }
        if let routeRecoveryTask {
            routeRecoveryTask.cancel()
            retiringRouteRecoveryTasks[routeRecoveryID ?? UUID()] = routeRecoveryTask
            self.routeRecoveryTask = nil
            routeRecoveryID = nil
        }
        oldOutput?.finish()

        if let stopTestingOperations {
            // Existing PCM stop observers remain independent of native device
            // ownership. Only an actual registration authorizes native stop.
            stopTestingOperations.unregisterMicrophone(microphoneReceiver ?? inactiveReceiver)
            stopTestingOperations.unregisterSystemAudio(systemReceiver ?? inactiveReceiver)
            if registeredSystem != nil { stopTestingOperations.stopSystemAudio() }
        } else {
            if let registeredMicrophone { AudioEngineManager.shared.unregister(registeredMicrophone) }
            if let registeredSystem {
                systemAudioCaptureService.unregister(registeredSystem.receiver)
                let receipt = systemAudioCaptureService.stopSystemAudioCapture(
                    capturedReceipt: registeredSystem.receipt, retryFailed: retryFailedResource)
                retiringSystemCapture = (receipt, nil, registeredSystem.terminalCaptureRevision)
            } else if retryFailedResource {
                retryStoppingAudioInput()
            }
        }
        // Retain captured sessions before their callbacks may restart the
        // service; no trailing assignment can then erase a replacement.
        if let microphone { retainStoppedSession(microphone); microphone.stop() }
        if let system { retainStoppedSession(system); system.stop() }
    }
    
    private func handleSessionFailure(_ error: Error, captureRevision: UInt64) {
        guard captureFence.isCurrent(captureRevision) else { return }
        // Recognition failure has already closed its exact input. Close only
        // that current receiver so its retained control worker can finish too.
        if let session = microphoneSession, session.serviceState == .failed,
            let receiver = microphoneReceiver, receiver.input === session.nativePCMInput {
            receiver.close()
        }
        if let session = systemAudioSession, session.serviceState == .failed,
            let receiver = systemReceiver, receiver.input === session.nativePCMInput {
            receiver.close()
        }
        // Combined capture keeps the surviving channel alive. A single-source
        // failure, or failure of both sources, terminates the provider stream.
        let microphoneActive = microphoneSession?.isRecognitionActive == true
        let systemActive = systemAudioSession?.isRecognitionActive == true
        guard !microphoneActive, !systemActive else { return }
        // Native errors reach this control path through the retained receiver
        // worker. Finishing the stream keeps resource teardown with its owner.
        transcriptOutput?.finish(error)
    }

    private func makeNativeReceiver(session: AppleSpeechTranscriptionSession,
        captureRevision: UInt64) -> AppleSpeechNativeReceiver {
        let controls = AppleSpeechNativeControlIngress()
        let receiver = AppleSpeechNativeReceiver(source: session.sessionID.source,
            input: session.nativePCMInput, controls: controls)
        let id = receiver.id
        let task = Task { @MainActor [weak self, weak session, controls] in
            defer { self?.nativeControlTasks[id] = nil }
            for await _ in controls.signals {
                for event in controls.takePending() {
                    guard let self, let session,
                        self.captureFence.isCurrent(captureRevision),
                        self.isCurrentNativeReceiver(id, session: session) else { continue }
                    switch event {
                    case .failure(let error):
                        session.lastError = error
                        session.stop()
                        self.handleSessionFailure(error, captureRevision: captureRevision)
                        // The failed source cannot accept further controls. End
                        // its exact signal so this owned worker exits, while an
                        // independent healthy source continues in Combined mode.
                        controls.close()
                    case .routeRestart:
                        self.restartMicrophoneAfterRouteChange()
                    }
                    self.onNativeControlHandledForTesting?(captureRevision, session.sessionID.source)
                }
            }
        }
        nativeControlTasks[id] = (controls, task)
        return receiver
    }

    private func isCurrentNativeReceiver(_ id: UUID, session: AppleSpeechTranscriptionSession) -> Bool {
        switch session.sessionID.source {
        case .microphone: return microphoneReceiver?.id == id && microphoneSession === session
        case .systemAudio: return systemReceiver?.id == id && systemAudioSession === session
        default: return false
        }
    }

    // These legacy control entry points are called only on MainActor. Native
    // registration exclusively uses immutable receiver handles above.
    func audioEngineManager(_ manager: AudioEngineManager, didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        microphoneReceiver?.audioEngineManager(manager, didReceive: buffer, at: time)
    }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        systemReceiver?.systemAudioCaptureService(service, didReceive: buffer, at: time)
    }
    func audioEngineManager(_ manager: AudioEngineManager, didFailWith error: Error) {
        microphoneSession?.lastError = error
        microphoneSession?.stop()
        if let revision = currentCaptureRevision { handleSessionFailure(error, captureRevision: revision) }
    }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService, didFailWithError error: Error) {
        systemAudioSession?.lastError = error
        systemAudioSession?.stop()
        if let revision = currentCaptureRevision { handleSessionFailure(error, captureRevision: revision) }
    }
    func audioEngineManagerDidRestartAfterRouteChange(_ manager: AudioEngineManager) {
        restartMicrophoneAfterRouteChange()
    }

    private func restartMicrophoneAfterRouteChange() {
        guard let currentParentSessionID, let oldSession = microphoneSession,
            let captureRevision = currentCaptureRevision else { return }
        if let routeRecoveryTask {
            routeRecoveryTask.cancel()
            retiringRouteRecoveryTasks[routeRecoveryID ?? UUID()] = routeRecoveryTask
        }
        let oldReceiver = microphoneReceiver
        oldReceiver?.close()
        oldSession.stop()
        retainStoppedSession(oldSession)
        let session = AppleSpeechTranscriptionSession(
            sessionID: .init(source: .microphone), parentSessionID: currentParentSessionID,
            requiresOnDeviceRecognition: requiresOnDeviceRecognition,
            onEmit: { [weak self] segment in
                guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                self.admitTranscriptSegment(segment, captureRevision: captureRevision)
            }, onStateChange: { [weak self] in
                guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                self.onSessionStateChanged?()
            }, onRuntimeEvent: { [weak self] event in
                guard let self, self.captureFence.isCurrent(captureRevision) else { return }
                self.onRuntimeEvent?(event)
            }, onFailure: { [weak self] error in
                self?.handleSessionFailure(error, captureRevision: captureRevision)
            }, pcmTestingOperations: pcmTestingOperations)
        microphoneSession = session
        let id = UUID()
        routeRecoveryID = id
        routeRecoveryTask = Task { @MainActor [weak self, session] in
            defer {
                if self?.routeRecoveryID == id {
                    self?.routeRecoveryID = nil
                    self?.routeRecoveryTask = nil
                }
                self?.retiringRouteRecoveryTasks[id] = nil
            }
            do {
                try Task.checkCancellation()
                guard let self, self.captureFence.isCurrent(captureRevision) else { session.stop(); return }
                try await session.start()
                guard self.captureFence.isCurrent(captureRevision), !Task.isCancelled,
                    self.microphoneSession === session else { session.stop(); return }
                let freshReceiver = self.makeNativeReceiver(session: session, captureRevision: captureRevision)
                self.microphoneReceiver = freshReceiver
                #if DEBUG
                let isTesting = ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("test") ||
                    ProcessInfo.processInfo.environment["SWIFT_TESTING"] != nil || NSClassFromString("XCTestCase") != nil
                #else
                let isTesting = false
                #endif
                if !isTesting {
                    if let oldReceiver { AudioEngineManager.shared.unregister(oldReceiver) }
                    try AudioEngineManager.shared.register(freshReceiver).get()
                    self.registeredMicrophoneReceiver = freshReceiver
                }
            } catch {
                session.stop()
                guard let self, self.captureFence.isCurrent(captureRevision), !Task.isCancelled,
                    self.microphoneSession === session else { return }
                self.handleSessionFailure(error, captureRevision: captureRevision)
                print("[DualAudio] Failed to recover microphone speech session: code=\((error as NSError).code)")
            }
        }
    }
}
