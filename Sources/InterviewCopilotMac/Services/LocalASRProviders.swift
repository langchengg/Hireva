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
}

protocol ParakeetRuntimeClient: AnyObject {
    func isRuntimeAvailable() async -> Bool
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error>
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
    static let sidecarPathDefaultsKey = "InterviewCopilot.parakeetSidecarPath"

    private let executableURLProvider: () -> URL?
    private var process: Process?

    init(executableURLProvider: @escaping () -> URL? = {
        if let envPath = ProcessInfo.processInfo.environment["PARAKEET_ASR_SIDECAR_PATH"], !envPath.isEmpty {
            return URL(fileURLWithPath: envPath)
        }
        if let storedPath = UserDefaults.standard.string(forKey: sidecarPathDefaultsKey), !storedPath.isEmpty {
            return URL(fileURLWithPath: storedPath)
        }
        return nil
    }) {
        self.executableURLProvider = executableURLProvider
    }

    func isRuntimeAvailable() async -> Bool {
        guard let executableURL = executableURLProvider() else { return false }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
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
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ParakeetSidecarError.launchFailed(error.localizedDescription)
        }
        self.process = process

        return AsyncThrowingStream { continuation in
            let stdoutHandle = stdout.fileHandleForReading
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
                Task { await self?.stop() }
            }
        }
    }

    func stop() async {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }
}

final class LocalParakeetASRProvider: ASRProvider {
    let id: ASRProviderID = .localParakeet
    let displayName = ASRProviderID.localParakeet.displayName

    private let modelManager: any LocalModelManager
    private let model: LocalModelDescriptor
    private let runtimeClient: any ParakeetRuntimeClient

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
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in eventStream {
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
                            confidence: nil,
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
        await runtimeClient.stop()
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
