import AVFoundation
import Foundation

enum ASRProviderID: String, Codable, CaseIterable, Identifiable, Hashable {
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

struct ASRConfig: Hashable {
    let sessionID: String
    let captureMode: AudioCaptureMode
}

protocol ASRProvider {
    var id: ASRProviderID { get }
    var displayName: String { get }
    func isAvailable() async -> Bool
    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error>
    func stopTranscription() async
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
            return "\(id.displayName) runtime is not available. Configure a Parakeet sidecar before enabling it."
        case .providerUnavailable(let message):
            return message
        }
    }
}

final class AppleSpeechASRProvider: ASRProvider {
    let id: ASRProviderID = .appleSpeech
    let displayName = "Apple Speech"
    private let service: AppleSpeechTranscriptionService

    init(service: AppleSpeechTranscriptionService = AppleSpeechTranscriptionService()) {
        self.service = service
    }

    func isAvailable() async -> Bool {
        true
    }

    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        try await service.start(sessionID: config.sessionID, captureMode: config.captureMode)
        return AsyncThrowingStream { continuation in
            Task {
                for await segment in service.segments {
                    continuation.yield(segment)
                }
                continuation.finish()
            }
        }
    }

    func stopTranscription() async {
        service.stop()
    }
}

final class LocalPlaceholderASRProvider: ASRProvider {
    let id: ASRProviderID
    let displayName: String
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

struct ParakeetTranscriptEvent: Codable, Equatable {
    let segmentId: String
    let text: String
    let isFinal: Bool
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let confidence: Double?
    let source: String?

    init(
        segmentId: String,
        text: String,
        isFinal: Bool,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        confidence: Double? = nil,
        source: String? = nil
    ) {
        self.segmentId = segmentId
        self.text = text
        self.isFinal = isFinal
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.source = source
    }
}

protocol ParakeetRuntimeClient: AnyObject {
    func isRuntimeAvailable() async -> Bool
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error>
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
    func stop() async
}

enum ParakeetSidecarError: LocalizedError, Equatable {
    case executableNotConfigured
    case launchFailed(String)
    case invalidEvent(String)
    case exited(Int32)

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
        }
    }
}

final class ParakeetSidecarRuntimeClient: ParakeetRuntimeClient {
    static let sidecarPathDefaultsKey = HirevaPreferenceKeys.parakeetSidecarPath

    private let executableURLProvider: () -> URL?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private let inputQueue = DispatchQueue(label: "com.langcheng.hireva.parakeet.sidecar.stdin")
    private var audioSequence = 0

    init(executableURLProvider: @escaping () -> URL? = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("parakeet_asr_sidecar"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if let envPath = ProcessInfo.processInfo.environment["PARAKEET_ASR_SIDECAR_PATH"], !envPath.isEmpty {
            return URL(fileURLWithPath: envPath)
        }
        if let storedPath = UserDefaults.standard.string(forKey: sidecarPathDefaultsKey), !storedPath.isEmpty {
            return URL(fileURLWithPath: storedPath)
        }
#if DEBUG
        let developmentSidecar = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/parakeet_asr_sidecar")
        if FileManager.default.isExecutableFile(atPath: developmentSidecar.path) {
            return developmentSidecar
        }
#endif
        return nil
    }) {
        self.executableURLProvider = executableURLProvider
    }

    func isRuntimeAvailable() async -> Bool {
        guard let executableURL = executableURLProvider() else { return false }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }
        return Self.sidecarHealthCheck(executableURL: executableURL)
    }

    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        guard let executableURL = executableURLProvider(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ParakeetSidecarError.executableNotConfigured
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--model-dir", modelDirectory.path,
            "--session-id", config.sessionID,
            "--capture-mode", config.captureMode.rawValue,
            "--jsonl"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            throw ParakeetSidecarError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting

        return AsyncThrowingStream { continuation in
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let stderrTask = Task {
                for try await line in stderrHandle.bytes.lines {
                    guard !line.isEmpty else { continue }
                    print("[ParakeetSidecar] \(line)")
                }
            }
            let task = Task {
                do {
                    for try await line in stdoutHandle.bytes.lines {
                        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        guard let data = line.data(using: .utf8),
                              let event = try? JSONDecoder().decode(ParakeetTranscriptEvent.self, from: data) else {
                            throw ParakeetSidecarError.invalidEvent(line)
                        }
                        continuation.yield(event)
                    }
                    process.waitUntilExit()
                    if process.terminationStatus == 0 || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: ParakeetSidecarError.exited(process.terminationStatus))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [weak self] _ in
                task.cancel()
                stderrTask.cancel()
                Task { await self?.stop() }
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let audioEvent = Self.audioEventData(from: buffer, sequence: nextAudioSequence()) else { return }
        inputQueue.async { [weak self] in
            guard let self, let stdinHandle = self.stdinHandle else { return }
            do {
                try stdinHandle.write(contentsOf: audioEvent)
                try stdinHandle.write(contentsOf: Data([0x0A]))
            } catch {
                print("[ParakeetSidecar] Failed to write audio chunk: \(error.localizedDescription)")
            }
        }
    }

    func stop() async {
        inputQueue.sync {
            try? stdinHandle?.close()
            stdinHandle = nil
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func nextAudioSequence() -> Int {
        inputQueue.sync {
            audioSequence += 1
            return audioSequence
        }
    }

    private static func audioEventData(from buffer: AVAudioPCMBuffer, sequence: Int) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return nil }

        var monoSamples = [Float]()
        monoSamples.reserveCapacity(frameLength)
        for frame in 0..<frameLength {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channelData[channel][frame]
            }
            monoSamples.append(sample / Float(channelCount))
        }

        let audioData = monoSamples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
        let payload: [String: Any] = [
            "type": "audio",
            "sequence": sequence,
            "sampleRate": buffer.format.sampleRate,
            "channels": 1,
            "encoding": "float32le",
            "audio": audioData.base64EncodedString()
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private static func sidecarHealthCheck(executableURL: URL) -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--health"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}

final class LocalParakeetASRProvider: ASRProvider, AudioEngineBufferDelegate, SystemAudioBufferDelegate {
    let id: ASRProviderID = .localParakeet
    let displayName = ASRProviderID.localParakeet.displayName

    private let modelManager: any LocalModelManager
    private let model: LocalModelDescriptor
    private let runtimeClient: any ParakeetRuntimeClient
    private var captureMode: AudioCaptureMode?

    init(
        model: LocalModelDescriptor = .defaultParakeetASR,
        modelManager: any LocalModelManager = FileLocalModelManager(),
        runtimeClient: any ParakeetRuntimeClient = ParakeetSidecarRuntimeClient()
    ) {
        self.model = model
        self.modelManager = modelManager
        self.runtimeClient = runtimeClient
    }

    func isAvailable() async -> Bool {
        let modelReady = (await modelManager.modelStatus(model)).isReady
        let runtimeReady = await runtimeClient.isRuntimeAvailable()
        return modelReady && runtimeReady
    }

    func isRuntimeAvailable() async -> Bool {
        await runtimeClient.isRuntimeAvailable()
    }

    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        guard await modelManager.modelStatus(model).isReady else {
            throw ASRProviderError.modelNotReady(.localParakeet)
        }
        guard await runtimeClient.isRuntimeAvailable() else {
            throw ASRProviderError.localASRRuntimeNotImplemented(.localParakeet)
        }

        let eventStream = try await runtimeClient.startTranscription(
            modelDirectory: modelManager.fileURL(for: model),
            config: config
        )
        do {
            try await startAudioCapture(config.captureMode)
        } catch {
            await runtimeClient.stop()
            throw error
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in eventStream {
                        if let source = event.source,
                           source != ASRSource.localParakeetASR.rawValue {
                            throw ASRProviderError.providerUnavailable("Parakeet sidecar emitted unexpected source: \(source)")
                        }
                        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        continuation.yield(TranscriptSegment(
                            id: event.segmentId,
                            sessionID: config.sessionID,
                            source: Self.audioSource(for: config.captureMode),
                            speaker: Self.speaker(for: config.captureMode),
                            text: text,
                            startTime: event.startTime,
                            endTime: event.endTime,
                            createdAt: Date(),
                            confidence: event.confidence,
                            asrSource: .localParakeetASR,
                            asrFinalizationReason: event.isFinal ? "final" : "partial",
                            recognitionIsFinal: event.isFinal
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { await self?.stopTranscription() }
            }
        }
    }

    func stopTranscription() async {
        stopAudioCapture()
        await runtimeClient.stop()
    }

    private func startAudioCapture(_ mode: AudioCaptureMode) async throws {
        captureMode = mode
        switch mode {
        case .microphoneOnly:
            AudioEngineManager.shared.register(self)
        case .systemAudioOnly:
            ScreenCaptureKitSystemAudioCaptureService.shared.register(self)
            try await ScreenCaptureKitSystemAudioCaptureService.shared.startSystemAudioCapture()
        case .microphoneAndSystem:
            AudioEngineManager.shared.register(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.register(self)
            try await ScreenCaptureKitSystemAudioCaptureService.shared.startSystemAudioCapture()
        }
    }

    private func stopAudioCapture() {
        guard let captureMode else { return }
        switch captureMode {
        case .microphoneOnly:
            AudioEngineManager.shared.unregister(self)
        case .systemAudioOnly:
            ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        case .microphoneAndSystem:
            AudioEngineManager.shared.unregister(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        }
        self.captureMode = nil
    }

    func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        runtimeClient.appendAudioBuffer(buffer, at: time)
    }

    func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    ) {
        print("[LocalParakeetASRProvider] Microphone capture failed: \(error.localizedDescription)")
    }

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        runtimeClient.appendAudioBuffer(buffer, at: time)
    }

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    ) {
        print("[LocalParakeetASRProvider] System audio capture failed: \(error.localizedDescription)")
    }

    private static func audioSource(for captureMode: AudioCaptureMode) -> AudioSourceType {
        switch captureMode {
        case .microphoneOnly:
            return .microphone
        case .systemAudioOnly, .microphoneAndSystem:
            return .systemAudio
        }
    }

    private static func speaker(for captureMode: AudioCaptureMode) -> SpeakerRole {
        switch captureMode {
        case .microphoneOnly:
            return .candidate
        case .systemAudioOnly, .microphoneAndSystem:
            return .interviewer
        }
    }
}
