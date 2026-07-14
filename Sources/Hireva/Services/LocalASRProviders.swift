import AVFoundation
import Darwin
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

struct ParakeetRuntimeDiagnostics: Codable, Hashable {
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
    func isRuntimeAvailable() async -> Bool
    func runtimeDiagnostics() async -> ParakeetRuntimeDiagnostics
    func probeModel(at modelDirectory: URL) async -> Bool
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error>
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType)
    func stop() async
}

extension ParakeetRuntimeClient {
    func runtimeDiagnostics() async -> ParakeetRuntimeDiagnostics {
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

    func probeModel(at modelDirectory: URL) async -> Bool {
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
        }
    }
}

final class ParakeetSidecarRuntimeClient: ParakeetRuntimeClient {
    static let sidecarPathDefaultsKey = HirevaPreferenceKeys.parakeetSidecarPath

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

    private let executableURLProvider: () -> URL?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private let inputQueue = DispatchQueue(label: "com.langcheng.hireva.parakeet.sidecar.stdin")
    private var audioSequence = 0

    init(executableURLProvider: @escaping () -> URL? = {
        ParakeetSidecarRuntimeClient.discoverExecutable(
            bundleURL: Bundle.main.bundleURL,
            environment: ProcessInfo.processInfo.environment,
            storedDevelopmentPath: UserDefaults.standard.string(forKey: sidecarPathDefaultsKey),
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            allowDevelopmentOverrides: _isDebugAssertConfiguration()
        )
    }) {
        self.executableURLProvider = executableURLProvider
    }

    static func discoverExecutable(
        bundleURL: URL,
        environment: [String: String],
        storedDevelopmentPath: String?,
        currentDirectory: URL,
        allowDevelopmentOverrides: Bool,
        fileManager: FileManager = .default
    ) -> URL? {
        let bundled = bundleURL.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        guard allowDevelopmentOverrides else { return nil }

        for key in ["PARAKEET_ASR_HELPER_PATH", "PARAKEET_ASR_SIDECAR_PATH"] {
            if let path = environment[key], !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        if let storedDevelopmentPath, !storedDevelopmentPath.isEmpty {
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

    func isRuntimeAvailable() async -> Bool {
        (await runtimeDiagnostics()).healthStatus == "ok"
    }

    func runtimeDiagnostics() async -> ParakeetRuntimeDiagnostics {
        guard let executableURL = executableURLProvider() else {
            return .unavailable(error: "Bundled native Parakeet helper is missing")
        }
        let executable = FileManager.default.isExecutableFile(atPath: executableURL.path)
        guard executable else {
            return .unavailable(path: executableURL.path, error: "Helper is not executable")
        }
        return Self.runHealthCheck(executableURL: executableURL, arguments: ["--health"], timeout: 3)
    }

    func probeModel(at modelDirectory: URL) async -> Bool {
        guard let executableURL = executableURLProvider(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return false
        }
        let diagnostics = Self.runHealthCheck(
            executableURL: executableURL,
            arguments: ["--health", "--probe-model", "--model-dir", modelDirectory.path],
            timeout: 15
        )
        return diagnostics.healthStatus == "ok" && diagnostics.modelStatus == "ready"
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
        process.environment = Self.minimalRuntimeEnvironment()

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
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
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
        appendAudioBuffer(buffer, at: time, source: .systemAudio)
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType) {
        guard let audioEvent = Self.audioEventData(
            from: buffer,
            sequence: nextAudioSequence(),
            source: source
        ) else { return }
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
            if let stdinHandle {
                let stopEvent = try? JSONSerialization.data(withJSONObject: ["type": "stop"])
                if let stopEvent {
                    try? stdinHandle.write(contentsOf: stopEvent)
                    try? stdinHandle.write(contentsOf: Data([0x0A]))
                }
            }
            try? stdinHandle?.close()
            stdinHandle = nil
        }
        if let process, process.isRunning {
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning {
                process.terminate()
            }
        }
        process = nil
    }

    private func nextAudioSequence() -> Int {
        inputQueue.sync {
            audioSequence += 1
            return audioSequence
        }
    }

    private static func audioEventData(
        from buffer: AVAudioPCMBuffer,
        sequence: Int,
        source: AudioSourceType
    ) -> Data? {
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
            "audioSource": source.rawValue,
            "audio": audioData.base64EncodedString()
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private static func runHealthCheck(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> ParakeetRuntimeDiagnostics {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = minimalRuntimeEnvironment()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .unavailable(path: executableURL.path, error: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .unavailable(path: executableURL.path, error: "Health check timed out")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
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
        let modelDirectory = modelManager.fileURL(for: model)
        guard await runtimeClient.probeModel(at: modelDirectory) else {
            throw ASRProviderError.providerUnavailable(
                "The Parakeet runtime could not load the verified model. Repair the model before retrying."
            )
        }

        let eventStream = try await runtimeClient.startTranscription(
            modelDirectory: modelDirectory,
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
                        guard event.source == ASRSource.localParakeetASR.rawValue else {
                            throw ASRProviderError.providerUnavailable(
                                "Parakeet helper emitted an untrusted or missing ASR source."
                            )
                        }
                        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let audioSource = try Self.audioSource(for: config.captureMode, event: event)
                        let speaker = try Self.speaker(for: audioSource, event: event)
                        continuation.yield(TranscriptSegment(
                            id: event.segmentId,
                            sessionID: config.sessionID,
                            source: audioSource,
                            speaker: speaker,
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
        runtimeClient.appendAudioBuffer(buffer, at: time, source: .microphone)
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
        runtimeClient.appendAudioBuffer(buffer, at: time, source: .systemAudio)
    }

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    ) {
        print("[LocalParakeetASRProvider] System audio capture failed: \(error.localizedDescription)")
    }

    private static func audioSource(
        for captureMode: AudioCaptureMode,
        event: ParakeetTranscriptEvent
    ) throws -> AudioSourceType {
        if let rawSource = event.audioSource,
           let source = AudioSourceType(rawValue: rawSource),
           source == .microphone || source == .systemAudio {
            return source
        }
        switch captureMode {
        case .microphoneOnly:
            return .microphone
        case .systemAudioOnly:
            return .systemAudio
        case .microphoneAndSystem:
            throw ASRProviderError.providerUnavailable(
                "Parakeet mixed capture emitted a transcript without channel attribution."
            )
        }
    }

    private static func speaker(
        for audioSource: AudioSourceType,
        event: ParakeetTranscriptEvent
    ) throws -> SpeakerRole {
        let expected: SpeakerRole = audioSource == .microphone ? .candidate : .interviewer
        if let rawSpeaker = event.speaker {
            guard let emitted = SpeakerRole(rawValue: rawSpeaker), emitted == expected else {
                throw ASRProviderError.providerUnavailable(
                    "Parakeet helper emitted speaker metadata that conflicts with its audio channel."
                )
            }
        }
        return expected
    }
}
