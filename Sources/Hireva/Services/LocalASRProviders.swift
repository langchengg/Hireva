import AVFoundation
import Darwin
import Foundation
import os

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

enum ParakeetHelperFailureCode: String, Codable, Equatable {
    case runtimeFailure = "runtime_failure"
    case modelFileUnavailable = "model_file_unavailable"
    case modelLockUnavailable = "model_lock_unavailable"
    case recognizerInitializationFailed = "recognizer_initialization_failed"
    case inputProtocolFailure = "input_protocol_failure"
    case queueLimitExceeded = "queue_limit_exceeded"
    case audioFileUnavailable = "audio_file_unavailable"
    case runtimeConflict = "runtime_conflict"
}

enum ParakeetSidecarError: LocalizedError, Equatable {
    case executableNotConfigured
    case launchFailed(code: Int)
    case invalidEvent(byteCount: Int)
    case exited(Int32)
    case healthCheckFailed
    case helperFailure(ParakeetHelperFailureCode)

    var errorDescription: String? {
        switch self {
        case .executableNotConfigured:
            return "Parakeet sidecar executable is not configured."
        case .launchFailed(let code):
            return "Parakeet sidecar failed to launch (code \(code))."
        case .invalidEvent(let byteCount):
            return "Parakeet sidecar emitted invalid transcript JSON (\(byteCount) bytes)."
        case .exited(let code):
            return "Parakeet sidecar exited with code \(code)."
        case .healthCheckFailed:
            return "Parakeet runtime health check failed."
        case .helperFailure(let code):
            return "Parakeet native helper failed (\(code.rawValue))."
        }
    }
}

struct ParakeetAudioWriterDiagnostics: Equatable {
    let maximumPendingChunks: Int
    let maximumPendingBytes: Int
    let pendingChunks: Int
    let pendingBytes: Int
    let droppedChunks: Int
}

private final class ParakeetLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        return drainCompleteLines()
    }

    func finish() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines = drainCompleteLines()
        if !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: false)
        }
        return lines
    }

    private func drainCompleteLines() -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(...newline)
        }
        return lines
    }
}

private final class ParakeetOutputStreamState: @unchecked Sendable {
    private struct HelperErrorFrame: Decodable {
        let type: String
        let code: String
    }

    private let lock = NSLock()
    private let buffer = ParakeetLineBuffer()
    private let continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation
    private let process: Process
    private var finished = false
    private var sawEndOfOutput = false
    private var processTerminationStatus: Int32?

    init(
        continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation,
        process: Process
    ) {
        self.continuation = continuation
        self.process = process
    }

    func receive(_ data: Data, from handle: FileHandle) {
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            buffer.finish().forEach(emit)
            finishAtEndOfOutput()
            return
        }
        buffer.append(data).forEach(emit)
    }

    func processDidTerminate(status: Int32) {
        lock.lock()
        processTerminationStatus = status
        guard sawEndOfOutput, !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        complete(status == 0 ? nil : ParakeetSidecarError.exited(status))
    }

    private func emit(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8) else {
            finish(ParakeetSidecarError.invalidEvent(byteCount: line.utf8.count))
            return
        }
        if let event = try? JSONDecoder().decode(ParakeetTranscriptEvent.self, from: data) {
            lock.lock()
            let shouldYield = !finished
            lock.unlock()
            if shouldYield {
                continuation.yield(event)
            }
            return
        }
        if let frame = try? JSONDecoder().decode(HelperErrorFrame.self, from: data),
           frame.type == "error" {
            let code = ParakeetHelperFailureCode(rawValue: frame.code) ?? .runtimeFailure
            finish(ParakeetSidecarError.helperFailure(code))
            return
        }
        finish(ParakeetSidecarError.invalidEvent(byteCount: line.utf8.count))
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        complete(error)
    }

    private func finishAtEndOfOutput() {
        lock.lock()
        sawEndOfOutput = true
        if processTerminationStatus == nil, !process.isRunning {
            processTerminationStatus = process.terminationStatus
        }
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let status = processTerminationStatus
        lock.unlock()

        // stdout EOF is the output protocol's terminal event. A helper may
        // close stdout before it exits, so do not hold the stream open waiting
        // for an otherwise still-running process. If termination was already
        // observed, preserve its status after all output has drained.
        let error: Error? = if let status, status != 0 {
            ParakeetSidecarError.exited(status)
        } else {
            nil
        }
        complete(error)
    }

    private func complete(_ error: Error?) {
        process.terminationHandler = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

final class ParakeetSidecarRuntimeClient: ParakeetRuntimeClient {
    static let sidecarPathDefaultsKey = HirevaPreferenceKeys.parakeetSidecarPath
    static let maximumPendingAudioChunks = 2_048
    static let maximumPendingAudioBytes = 8 * 1_024 * 1_024

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
    private let inputStateLock = NSLock()
    private var acceptsAudio = false
    private var streamGeneration = 0
    private var audioSequence = 0
    private var pendingAudioChunks = 0
    private var pendingAudioBytes = 0
    private var droppedAudioChunks = 0

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
            return .unavailable(path: Self.helperLocationLabel(executableURL), error: "Helper is not executable")
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
        await stop()

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
            let code = (error as NSError).code
            PrivacySafeLogger.audioFailure(operation: .parakeetHelperLaunch, code: code)
            throw ParakeetSidecarError.launchFailed(code: code)
        }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let generation = withInputStateLock {
            streamGeneration += 1
            audioSequence = 0
            droppedAudioChunks = 0
            acceptsAudio = true
            self.process = process
            stdinHandle = stdin.fileHandleForWriting
            return streamGeneration
        }

        return AsyncThrowingStream { continuation in
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let outputState = ParakeetOutputStreamState(
                continuation: continuation,
                process: process
            )
            process.terminationHandler = { terminatedProcess in
                outputState.processDidTerminate(status: terminatedProcess.terminationStatus)
            }
            if !process.isRunning {
                outputState.processDidTerminate(status: process.terminationStatus)
            }
            let stderrBuffer = ParakeetLineBuffer()
            stdoutHandle.readabilityHandler = { handle in
                outputState.receive(handle.availableData, from: handle)
            }
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    for line in stderrBuffer.finish() where !line.isEmpty {
                        Self.logSidecarDiagnostic(line)
                    }
                    return
                }
                for line in stderrBuffer.append(data) where !line.isEmpty {
                    Self.logSidecarDiagnostic(line)
                }
            }

            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop(generation: generation) }
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        appendAudioBuffer(buffer, at: time, source: .systemAudio)
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType) {
        guard let reservation = reserveAudioSequence() else { return }
        guard let audioEvent = Self.audioEventData(
            from: buffer,
            sequence: reservation.sequence,
            source: source
        ) else { return }
        var audioLine = audioEvent
        audioLine.append(0x0A)
        guard let inputHandle = commitAudioWrite(
            generation: reservation.generation,
            byteCount: audioLine.count
        ) else { return }
        inputQueue.async { [self] in
            defer { self.releaseAudioWrite(byteCount: audioLine.count) }
            do {
                try inputHandle.write(contentsOf: audioLine)
            } catch {
                let currentStreamStillOwnsInput = self.withInputStateLock {
                    self.acceptsAudio && reservation.generation == self.streamGeneration
                }
                if currentStreamStillOwnsInput {
                    let nsError = error as NSError
                    PrivacySafeLogger.audioFailure(operation: .parakeetAudioWrite, code: nsError.code)
                }
            }
        }
    }

    func stop() async {
        await stop(generation: nil)
    }

    private static func logSidecarDiagnostic(_ line: String) {
        PrivacySafeLogger.parakeetHelperDiagnostic(byteCount: line.utf8.count)
    }

    private func stop(generation ownerGeneration: Int?) async {
        let stoppingRuntime: (Process?, FileHandle?)? = withInputStateLock {
            if let ownerGeneration, ownerGeneration != streamGeneration {
                return nil
            }
            acceptsAudio = false
            guard process != nil || stdinHandle != nil else { return (nil, nil) }
            streamGeneration += 1
            let stoppingProcess = process
            let stoppingInput = stdinHandle
            process = nil
            stdinHandle = nil
            return (stoppingProcess, stoppingInput)
        }
        guard let (stoppingProcess, stoppingInput) = stoppingRuntime else { return }

        if let stoppingInput {
            inputQueue.async {
                var stopLine = (try? JSONSerialization.data(withJSONObject: ["type": "stop"])) ?? Data()
                stopLine.append(0x0A)
                try? stoppingInput.write(contentsOf: stopLine)
                try? stoppingInput.close()
            }
        }

        if let stoppingProcess, stoppingProcess.isRunning {
            let gracefulDeadline = Date().addingTimeInterval(3)
            while stoppingProcess.isRunning && Date() < gracefulDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if stoppingProcess.isRunning {
                stoppingProcess.terminate()
            }
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while stoppingProcess.isRunning && Date() < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if stoppingProcess.isRunning {
                _ = Darwin.kill(stoppingProcess.processIdentifier, SIGKILL)
                let killDeadline = Date().addingTimeInterval(0.5)
                while stoppingProcess.isRunning && Date() < killDeadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
    }

    func audioWriterDiagnostics() -> ParakeetAudioWriterDiagnostics {
        withInputStateLock {
            ParakeetAudioWriterDiagnostics(
                maximumPendingChunks: Self.maximumPendingAudioChunks,
                maximumPendingBytes: Self.maximumPendingAudioBytes,
                pendingChunks: pendingAudioChunks,
                pendingBytes: pendingAudioBytes,
                droppedChunks: droppedAudioChunks
            )
        }
    }

    private func reserveAudioSequence() -> (generation: Int, sequence: Int)? {
        withInputStateLock {
            guard acceptsAudio, stdinHandle != nil else { return nil }
            audioSequence += 1
            return (streamGeneration, audioSequence)
        }
    }

    private func commitAudioWrite(generation: Int, byteCount: Int) -> FileHandle? {
        withInputStateLock {
            guard acceptsAudio,
                  generation == streamGeneration,
                  let stdinHandle,
                  byteCount <= Self.maximumPendingAudioBytes,
                  pendingAudioChunks < Self.maximumPendingAudioChunks,
                  pendingAudioBytes <= Self.maximumPendingAudioBytes - byteCount else {
                droppedAudioChunks += 1
                return nil
            }
            pendingAudioChunks += 1
            pendingAudioBytes += byteCount
            return stdinHandle
        }
    }

    private func releaseAudioWrite(byteCount: Int) {
        withInputStateLock {
            pendingAudioChunks = max(0, pendingAudioChunks - 1)
            pendingAudioBytes = max(0, pendingAudioBytes - byteCount)
        }
    }

    private func withInputStateLock<T>(_ operation: () throws -> T) rethrows -> T {
        inputStateLock.lock()
        defer { inputStateLock.unlock() }
        return try operation()
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
            let code = (error as NSError).code
            PrivacySafeLogger.audioFailure(operation: .parakeetHelperHealth, code: code)
            return .unavailable(path: helperLocationLabel(executableURL), error: "Helper launch failed (code \(code))")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                let killDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.025)
                }
            }
            if !process.isRunning {
                process.waitUntilExit()
            }
            return .unavailable(path: helperLocationLabel(executableURL), error: "Health check timed out")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let frame = try? JSONDecoder().decode(HelperFailureFrame.self, from: output)
            let code = frame?.type == "error"
                ? frame.flatMap { ParakeetHelperFailureCode(rawValue: $0.code) } ?? .runtimeFailure
                : .runtimeFailure
            return .unavailable(
                path: helperLocationLabel(executableURL),
                error: "Helper failed (\(code.rawValue))"
            )
        }
        guard let health = try? JSONDecoder().decode(HelperHealth.self, from: output),
              health.status == "ok",
              health.source == ASRSource.localParakeetASR.rawValue,
              health.runtimeMode == "bundled_native",
              [health.runtimeVersion, health.sherpaVersion, health.onnxRuntimeVersion]
                .allSatisfy(isSafeRuntimeToken),
              ["not_probed", "ready"].contains(health.modelStatus) else {
            return .unavailable(path: helperLocationLabel(executableURL), error: "Invalid helper health response")
        }
        guard health.architecture == currentArchitecture else {
            return .unavailable(
                path: helperLocationLabel(executableURL),
                error: "Helper architecture does not match this Mac"
            )
        }
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let helperPath = executableURL.standardizedFileURL.path
        let bundled = helperPath.hasPrefix(bundlePath + "/Contents/Helpers/")
        return ParakeetRuntimeDiagnostics(
            runtimeMode: health.runtimeMode,
            helperPath: bundled ? "Bundled helper" : "Development helper",
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

    private struct HelperFailureFrame: Decodable {
        let type: String
        let code: String
    }

    private static func helperLocationLabel(_ executableURL: URL) -> String {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let helperPath = executableURL.standardizedFileURL.path
        return helperPath.hasPrefix(bundlePath + "/Contents/Helpers/")
            ? "Bundled helper"
            : "Development helper"
    }

    private static func isSafeRuntimeToken(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]{1,32}$"#, options: .regularExpression) != nil
    }

    private static func minimalRuntimeEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        var result = [
            "HOME": "/var/empty",
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
                        let segment = try ParakeetTranscriptMapper.map(event, config: config)
                        guard !segment.text.isEmpty else { continue }
                        continuation.yield(segment)
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
        let nsError = error as NSError
        PrivacySafeLogger.audioFailure(operation: .parakeetMicrophoneCapture, code: nsError.code)
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
        let nsError = error as NSError
        PrivacySafeLogger.audioFailure(operation: .parakeetSystemAudioCapture, code: nsError.code)
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
            speaker: expectedSpeaker,
            text: event.text.trimmingCharacters(in: .whitespacesAndNewlines),
            startTime: event.startTime,
            endTime: event.endTime,
            createdAt: Date(),
            confidence: event.confidence,
            asrSource: .localParakeetASR,
            asrFinalizationReason: "final",
            recognitionIsFinal: true
        )
    }
}
