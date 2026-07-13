import AVFoundation
import Foundation
import Speech

enum TranscriptionServiceState: String, Codable {
    case idle
    case starting
    case running
    case recoveringRoute
    case stopped
    case failed
}

struct AudioTranscriptionSessionID: Hashable, Equatable {
    let source: AudioSourceType
}

/// Utterance-level ASR latency tracking (per speech segment, not per session)
struct UtteranceLatency {
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

final class AppleSpeechTranscriptionSession: NSObject {
    let sessionID: AudioTranscriptionSessionID
    let parentSessionID: String
    
    private let recognizer: SFSpeechRecognizer?
    private(set) var request: SFSpeechAudioBufferRecognitionRequest?
    private(set) var recognitionTask: SFSpeechRecognitionTask?
    
    var partialTranscriptBuffer: String = ""
    var lastFinalTranscriptTimestamp: Date?
    var totalBuffersAppended: Int = 0
    var lastBufferReceivedAt: Date?
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
    private var recognitionEventSequence: Int = 0
    
    // Session-level ASR timestamps
    private(set) var sessionStartedAt: Date?
    private(set) var firstPartialReceivedAt: Date?
    private(set) var firstFinalReceivedAt: Date?
    
    // Utterance-level ASR latency (tracks per-utterance, not per-session)
    private(set) var currentUtteranceLatency: UtteranceLatency?
    private(set) var lastCompletedUtteranceLatency: UtteranceLatency?
    
    private let onEmit: (TranscriptSegment) -> Void
    private let onStateChange: () -> Void
    private let onRuntimeEvent: ((TranscriptRuntimeEvent) -> Void)?
    
    // Test simulation hooks
    var simulatedTaskActive = false
    var onSimulatedAppend: ((AVAudioPCMBuffer) -> Void)?
    
    private(set) var serviceState: TranscriptionServiceState = .idle {
        didSet {
            onStateChange()
        }
    }
    
    init(
        sessionID: AudioTranscriptionSessionID,
        parentSessionID: String,
        onEmit: @escaping (TranscriptSegment) -> Void,
        onStateChange: @escaping () -> Void,
        onRuntimeEvent: ((TranscriptRuntimeEvent) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.onEmit = onEmit
        self.onStateChange = onStateChange
        self.onRuntimeEvent = onRuntimeEvent
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
            self.partialTranscriptBuffer = ""
            self.totalBuffersAppended = 0
            self.lastBufferReceivedAt = nil
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
            self.request = SFSpeechAudioBufferRecognitionRequest()
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
        self.partialTranscriptBuffer = ""
        self.totalBuffersAppended = 0
        self.lastBufferReceivedAt = nil
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
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        
        print("[DualAudio] \(sessionID.source == .microphone ? "mic" : "system") ASR session created: \(sessionID.source.rawValue)")
        
        self.serviceState = .running
        self.onRuntimeEvent?(.audioStarted(sessionID: parentSessionID, timestamp: Date()))
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
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
                            print("[DualAudio] mic partial = \(text)")
                        } else {
                            print("[DualAudio] system partial = \(text)")
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
                            print("[DualAudio] mic final segment source=microphone speaker=candidate: \"\(text)\"")
                        } else {
                            print("[DualAudio] system final segment source=systemAudio speaker=interviewer: \"\(text)\"")
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
                        
                        print("[DualAudio] finalization resolved. reason: \"\(self.finalizationReason)\" | best: \"\(bestTranscript)\" | asrFirstPartialMS=\(self.currentUtteranceLatency?.asrFirstPartialMS ?? -1) asrFinalMS=\(self.currentUtteranceLatency?.asrFinalMS ?? -1) asrBestSelectedMS=\(self.currentUtteranceLatency?.asrBestSelectedMS ?? -1)")
                        
                        // Complete utterance latency and archive it
                        self.lastCompletedUtteranceLatency = self.currentUtteranceLatency
                        
                        // Emit the finalized best transcript using the SAME utteranceID to overwrite any partials
                        self.emitWithLatency(text: bestTranscript, id: self.utteranceID)
                        self.onStateChange()
                        
                        // Rotate to a new utterance ID for subsequent inputs
                        self.utteranceID = UUID().uuidString
                        self.resetUtteranceLatency()
                    }
                }
            } else if let error = error {
                print("[DualAudio] \(self.sessionID.source.rawValue) recognition task error: \(error.localizedDescription)")
                Task { @MainActor in
                    self.lastError = error
                    self.serviceState = .failed
                }
            }
        }
    }

    #if DEBUG
    @MainActor
    func startSimulatedRecognitionForDiagnostic() {
        stop()
        self.partialTranscriptBuffer = ""
        self.totalBuffersAppended = 0
        self.lastBufferReceivedAt = nil
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
        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.onRuntimeEvent?(.audioStarted(sessionID: parentSessionID, timestamp: Date()))
    }
    #endif
    
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        #if DEBUG
        if simulatedTaskActive {
            totalBuffersAppended += 1
            let now = Date()
            lastBufferReceivedAt = now
            onRuntimeEvent?(.audioBufferReceived(sessionID: parentSessionID, frameCount: Int(buffer.frameLength), timestamp: now))
            onSimulatedAppend?(buffer)
            onStateChange()
            return
        }
        #endif
        
        request?.append(buffer)
        totalBuffersAppended += 1
        let now = Date()
        lastBufferReceivedAt = now
        onRuntimeEvent?(.audioBufferReceived(sessionID: parentSessionID, frameCount: Int(buffer.frameLength), timestamp: now))
        if totalBuffersAppended % 100 == 0 || totalBuffersAppended == 1 {
            print("[DualAudio] \(sessionID.source == .microphone ? "mic" : "system") buffer appended count = \(totalBuffersAppended)")
        }
        onStateChange()
    }
    
    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        simulatedTaskActive = false
        self.serviceState = .stopped
    }
    
    @MainActor
    func simulateEmit(text: String, isFinal: Bool = false) {
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
                .candidate
            )
        } else {
            return (
                nil,
                "System Audio Capture",
                "system_audio",
                .interviewer
            )
        }
    }
}

final class AppleSpeechTranscriptionService: NSObject, TranscriptionProvider, AudioEngineBufferDelegate, SystemAudioBufferDelegate {
    let providerName = "Apple Speech Session Manager"
    
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    
    private(set) var microphoneSession: AppleSpeechTranscriptionSession?
    private(set) var systemAudioSession: AppleSpeechTranscriptionSession?
    
    private var isRecording = false
    private var captureMode: AudioCaptureMode = .microphoneAndSystem
    private var currentParentSessionID: String?
    
    // Callback to let AppState know that session parameters changed (useful for diagnostics update triggers)
    var onSessionStateChanged: (() -> Void)?
    var onRuntimeEvent: ((TranscriptRuntimeEvent) -> Void)?
    
    lazy var segments: AsyncStream<TranscriptSegment> = AsyncStream { continuation in
        self.continuation = continuation
    }
    
    override init() {
        super.init()
    }
    
    func start(sessionID: String) async throws {
        try await start(sessionID: sessionID, captureMode: .microphoneAndSystem)
    }
    
    func start(sessionID: String, captureMode: AudioCaptureMode) async throws {
        stop()
        
        self.currentParentSessionID = sessionID
        self.captureMode = captureMode
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
        
        if micRequired {
            print("[DualAudio] starting mic capture")
            let micSessionID = AudioTranscriptionSessionID(source: .microphone)
            let session = AppleSpeechTranscriptionSession(
                sessionID: micSessionID,
                parentSessionID: sessionID,
                onEmit: { [weak self] segment in
                    self?.continuation?.yield(segment)
                },
                onStateChange: { [weak self] in
                    self?.onSessionStateChanged?()
                },
                onRuntimeEvent: { [weak self] event in
                    self?.onRuntimeEvent?(event)
                }
            )
            self.microphoneSession = session
            try await session.start()
            
            if !isTesting {
                // Register to AudioEngineManager
                AudioEngineManager.shared.register(self)
            }
        }
        
        if systemRequired {
            print("[DualAudio] starting system capture")
            let systemSessionID = AudioTranscriptionSessionID(source: .systemAudio)
            let session = AppleSpeechTranscriptionSession(
                sessionID: systemSessionID,
                parentSessionID: sessionID,
                onEmit: { [weak self] segment in
                    self?.continuation?.yield(segment)
                },
                onStateChange: { [weak self] in
                    self?.onSessionStateChanged?()
                },
                onRuntimeEvent: { [weak self] event in
                    self?.onRuntimeEvent?(event)
                }
            )
            self.systemAudioSession = session
            try await session.start()
            
            if !isTesting {
                // Register to ScreenCaptureKitSystemAudioCaptureService
                ScreenCaptureKitSystemAudioCaptureService.shared.register(self)
                try await ScreenCaptureKitSystemAudioCaptureService.shared.startSystemAudioCapture()
            }
        }
        
        // Concurrent-session guard check
        if captureMode == .microphoneAndSystem {
            let micActive = microphoneSession?.simulatedTaskActive == true || microphoneSession?.recognitionTask != nil
            let sysActive = systemAudioSession?.simulatedTaskActive == true || systemAudioSession?.recognitionTask != nil
            if !micActive || !sysActive {
                let errorMsg = "Apple Speech could not run two concurrent transcription streams. Use System Audio Only / Manual Capture or configure an alternate ASR provider."
                print("[DualAudio] Concurrent session guard failed! micActive: \(micActive), sysActive: \(sysActive)")
                throw TranscriptionError.unavailable(errorMsg)
            }
        }
    }

    #if DEBUG
    @MainActor
    func startDiagnosticSystemAudioSession(sessionID: String) {
        stop()
        self.currentParentSessionID = sessionID
        self.captureMode = .systemAudioOnly
        self.isRecording = true

        let systemSessionID = AudioTranscriptionSessionID(source: .systemAudio)
        let session = AppleSpeechTranscriptionSession(
            sessionID: systemSessionID,
            parentSessionID: sessionID,
            onEmit: { [weak self] segment in
                self?.continuation?.yield(segment)
            },
            onStateChange: { [weak self] in
                self?.onSessionStateChanged?()
            },
            onRuntimeEvent: { [weak self] event in
                self?.onRuntimeEvent?(event)
            }
        )
        self.systemAudioSession = session
        session.startSimulatedRecognitionForDiagnostic()
    }
    #endif
    
    func stop() {
        isRecording = false
        
        // Stop & cleanup sessions
        microphoneSession?.stop()
        microphoneSession = nil
        
        systemAudioSession?.stop()
        systemAudioSession = nil
        
        // Unregister from capture services
        AudioEngineManager.shared.unregister(self)
        
        ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
        ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        
        currentParentSessionID = nil
    }
    
    // MARK: - AudioEngineBufferDelegate conformance (Microphone)
    
    func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        microphoneSession?.appendBuffer(buffer)
    }
    
    func audioEngineManagerDidRestartAfterRouteChange(
        _ manager: AudioEngineManager
    ) {
        guard let currentParentSessionID, microphoneSession != nil else { return }
        print("[DualAudio] Re-initializing microphone speech capture request after route change...")
        
        // Recover route safely by spinning up a new microphone ASR session
        microphoneSession?.stop()
        
        let micSessionID = AudioTranscriptionSessionID(source: .microphone)
        let session = AppleSpeechTranscriptionSession(
            sessionID: micSessionID,
            parentSessionID: currentParentSessionID,
            onEmit: { [weak self] segment in
                self?.continuation?.yield(segment)
            },
            onStateChange: { [weak self] in
                self?.onSessionStateChanged?()
            },
            onRuntimeEvent: { [weak self] event in
                self?.onRuntimeEvent?(event)
            }
        )
        self.microphoneSession = session
        
        Task {
            do {
                try await session.start()
            } catch {
                print("[DualAudio] Failed to recover microphone speech session after route change: \(error.localizedDescription)")
            }
        }
    }
    
    func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    ) {
        print("[DualAudio] Microphone input failed with error: \(error.localizedDescription)")
        microphoneSession?.stop()
    }
    
    // MARK: - SystemAudioBufferDelegate conformance (System Audio Loopback)
    
    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        systemAudioSession?.appendBuffer(buffer)
    }
    
    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    ) {
        print("[DualAudio] System audio capture failed with error: \(error.localizedDescription)")
        systemAudioSession?.stop()
    }
}
