import Foundation

enum LocalModelKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case transcription
    case localLLM

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcription:
            return "Transcription"
        case .localLLM:
            return "Local LLM"
        }
    }
}

struct LocalModelFileRequirement: Codable, Hashable {
    let relativePath: String
    let minimumBytes: Int64?
    let exactBytes: Int64?
    let sha256: String?

    init(
        relativePath: String,
        minimumBytes: Int64? = nil,
        exactBytes: Int64? = nil,
        sha256: String? = nil
    ) {
        self.relativePath = relativePath
        self.minimumBytes = minimumBytes
        self.exactBytes = exactBytes
        self.sha256 = sha256
    }
}

struct LocalModelDescriptor: Codable, Hashable, Identifiable {
    let id: String
    let version: String?
    let displayName: String
    let kind: LocalModelKind
    let sizeBytes: Int64?
    let downloadURL: URL?
    let checksum: String?
    let storageRelativePath: String
    let requiredFiles: [LocalModelFileRequirement]
    let archiveRootDirectory: String?
    let trustedDownloadHosts: [String]
    let legacyStorageRelativePaths: [String]
    let storageNamespace: String?

    var canonicalIdentifier: String {
        guard let version, !version.isEmpty else { return id }
        return "\(id)/\(version)"
    }

    var canonicalStorageRelativePath: String {
        guard let storageNamespace, !storageNamespace.isEmpty else {
            return canonicalIdentifier
        }
        return "\(storageNamespace)/\(canonicalIdentifier)"
    }

    init(
        id: String,
        version: String? = nil,
        displayName: String,
        kind: LocalModelKind,
        sizeBytes: Int64?,
        downloadURL: URL?,
        checksum: String?,
        storageRelativePath: String,
        requiredFiles: [LocalModelFileRequirement] = [],
        archiveRootDirectory: String? = nil,
        trustedDownloadHosts: [String] = [],
        legacyStorageRelativePaths: [String] = [],
        storageNamespace: String? = nil
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.downloadURL = downloadURL
        self.checksum = checksum
        self.storageRelativePath = storageRelativePath
        self.requiredFiles = requiredFiles
        self.archiveRootDirectory = archiveRootDirectory
        self.trustedDownloadHosts = trustedDownloadHosts
        self.legacyStorageRelativePaths = legacyStorageRelativePaths
        self.storageNamespace = storageNamespace
    }

    static let localWhisperTinyEnglish = LocalModelDescriptor(
        id: "local-whisper-tiny-en",
        displayName: "Local Whisper Tiny.en",
        kind: .transcription,
        sizeBytes: 77_700_000,
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"),
        checksum: nil,
        storageRelativePath: "Transcription/ggml-tiny.en.bin"
    )

    static let defaultQwenLocalLLM = LocalModelDescriptor(
        id: "qwen3.5:4b",
        displayName: "Qwen3.5 4B",
        kind: .localLLM,
        sizeBytes: nil,
        downloadURL: nil,
        checksum: nil,
        storageRelativePath: "ollama/qwen3.5-4b"
    )

    static let defaultParakeetASR = LocalModelDescriptor(
        id: "parakeet-tdt-0.6b-v3-int8",
        version: "asr-models-5793d0fd397c5778",
        displayName: "Parakeet TDT 0.6B",
        kind: .transcription,
        sizeBytes: 487_170_055,
        downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"),
        checksum: "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf",
        storageRelativePath: "asr/parakeet-tdt-0.6b-v3-int8/asr-models-5793d0fd397c5778",
        requiredFiles: [
            LocalModelFileRequirement(
                relativePath: "encoder.int8.onnx",
                exactBytes: 652_184_281,
                sha256: "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"
            ),
            LocalModelFileRequirement(
                relativePath: "decoder.int8.onnx",
                exactBytes: 11_845_275,
                sha256: "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"
            ),
            LocalModelFileRequirement(
                relativePath: "joiner.int8.onnx",
                exactBytes: 6_355_277,
                sha256: "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"
            ),
            LocalModelFileRequirement(
                relativePath: "tokens.txt",
                exactBytes: 93_939,
                sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"
            ),
            LocalModelFileRequirement(
                relativePath: "test_wavs/de.wav",
                exactBytes: 121_388,
                sha256: "36d3c4845b9808a1656a2a2e92d884590e2db94389e6fe559643291ae0cd3710"
            ),
            LocalModelFileRequirement(
                relativePath: "test_wavs/en.wav",
                exactBytes: 184_608,
                sha256: "148b936b43ce7c546a866e64da059f0458aee2d65e617f16e9d94f06e8d99ed6"
            ),
            LocalModelFileRequirement(
                relativePath: "test_wavs/es.wav",
                exactBytes: 235_052,
                sha256: "49fd2cfa4b62db7068143c582b35de9d31ec2733495ece3611105131d21de06c"
            ),
            LocalModelFileRequirement(
                relativePath: "test_wavs/fr.wav",
                exactBytes: 219_180,
                sha256: "b59be4349b92d344fb903677165eaf4694025d1ab119c608726ecbcb3164b528"
            )
        ],
        archiveRootDirectory: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
        trustedDownloadHosts: ["github.com", "release-assets.githubusercontent.com"],
        legacyStorageRelativePaths: ["asr/parakeet-tdt-0.6b-v3-int8"],
        storageNamespace: "asr"
    )

    static let ollamaQwen = defaultQwenLocalLLM
}

enum LocalModelStatus: Equatable {
    case notInstalled
    case downloading(progress: Double, downloadedBytes: Int64, totalBytes: Int64?, speedBytesPerSecond: Double?)
    case installed
    case verifying
    case failed(String)

    var isReady: Bool {
        if case .installed = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .notInstalled:
            return "Not Installed"
        case .downloading:
            return "Downloading"
        case .installed:
            return "Model Ready"
        case .verifying:
            return "Verifying"
        case .failed:
            return "Failed"
        }
    }
}

struct ModelDownloadProgress: Equatable {
    let modelID: String
    let progress: Double
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let speedBytesPerSecond: Double?
    let statusMessage: String

    static func completed(modelID: String, totalBytes: Int64?) -> ModelDownloadProgress {
        ModelDownloadProgress(
            modelID: modelID,
            progress: 1,
            downloadedBytes: totalBytes ?? 0,
            totalBytes: totalBytes,
            speedBytesPerSecond: nil,
            statusMessage: "Ready"
        )
    }
}

protocol LocalModelManager {
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error>
    func repairModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error>
    func rollbackModel(_ model: LocalModelDescriptor) async throws
    func deleteModel(_ model: LocalModelDescriptor) async throws
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool
    func fileURL(for model: LocalModelDescriptor) -> URL
}

extension LocalModelManager {
    func repairModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        downloadModel(model)
    }

    func rollbackModel(_ model: LocalModelDescriptor) async throws {
        throw LocalModelManagerError.rollbackUnavailable(model.displayName)
    }
}

enum LocalModelManagerError: LocalizedError, Equatable {
    case missingDownloadURL(String)
    case invalidRelativePath(String)
    case downloadFailed(String)
    case checksumUnsupported
    case untrustedDownloadURL(String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case checksumMismatch(path: String)
    case unsafeArchiveEntry(String)
    case rollbackUnavailable(String)
    case modelInUse(String)

    var errorDescription: String? {
        switch self {
        case .missingDownloadURL(let model):
            return "\(model) does not have a configured download URL."
        case .invalidRelativePath(let path):
            return "Invalid local model path: \(path)"
        case .downloadFailed(let message):
            return message
        case .checksumUnsupported:
            return "Checksum verification is not implemented for this model yet."
        case .untrustedDownloadURL(let url):
            return "Untrusted model download URL: \(url)"
        case .sizeMismatch(let path, let expected, let actual):
            return "\(path) has \(actual) bytes; expected exactly \(expected)."
        case .checksumMismatch(let path):
            return "SHA-256 verification failed for \(path)."
        case .unsafeArchiveEntry(let path):
            return "Unsafe model archive entry: \(path)"
        case .rollbackUnavailable(let model):
            return "No verified rollback is available for \(model)."
        case .modelInUse(let model):
            return "\(model) is currently in use. Stop listening before installing, repairing, rolling back, or deleting it."
        }
    }
}

enum AnswerProviderMode: String, Codable, CaseIterable, Identifiable {
    case deepSeekPrimary
    case localQwenPrimary
    case deepSeekWithLocalQwenFallback

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepSeekPrimary:
            return "DeepSeek primary"
        case .localQwenPrimary:
            return "Local Qwen primary"
        case .deepSeekWithLocalQwenFallback:
            return "DeepSeek primary, Local Qwen fallback"
        }
    }

    init(storedValue: String?) {
        switch storedValue {
        case nil, "":
            self = .localQwenPrimary
        case Self.localQwenPrimary.rawValue, "localQwen":
            self = .localQwenPrimary
        case Self.deepSeekPrimary.rawValue, "deepSeek":
            self = .deepSeekPrimary
        case Self.deepSeekWithLocalQwenFallback.rawValue, "deepSeekWithLocalFallback":
            self = .deepSeekWithLocalQwenFallback
        default:
            self = .localQwenPrimary
        }
    }
}

enum TranscriptionProviderMode: String, Codable, CaseIterable, Identifiable {
    case appleSpeech
    case localParakeetExperimental

    var id: String { rawValue }

    var providerID: ASRProviderID {
        switch self {
        case .appleSpeech:
            return .appleSpeech
        case .localParakeetExperimental:
            return .localParakeet
        }
    }

    var displayName: String {
        providerID.displayName
    }

    init(providerID: ASRProviderID) {
        switch providerID {
        case .localParakeet:
            self = .localParakeetExperimental
        case .appleSpeech, .localWhisper:
            self = .appleSpeech
        }
    }
}

enum AnswerSource: String, Codable, CaseIterable, Hashable {
    case deepseekStream = "deepseek_stream"
    case localQwen = "local_qwen"
    case ollamaQwen = "ollama_qwen"
    case openAICompatible = "openai_compatible"
    case ragTemplateSoftFallback = "rag_template_soft_fallback"
    case localTimeoutFallback = "local_timeout_fallback"
    case placeholder
    case providerError = "provider_error"
    case lowConfidenceRejected = "low_confidence_rejected"

    var isLocal: Bool {
        switch self {
        case .localQwen, .ollamaQwen, .ragTemplateSoftFallback, .localTimeoutFallback:
            return true
        case .deepseekStream, .openAICompatible, .placeholder, .providerError, .lowConfidenceRejected:
            return false
        }
    }

    var isFallback: Bool {
        switch self {
        case .ragTemplateSoftFallback, .localTimeoutFallback, .providerError, .placeholder, .lowConfidenceRejected:
            return true
        case .deepseekStream, .localQwen, .ollamaQwen, .openAICompatible:
            return false
        }
    }
}

enum ASRSource: String, Codable, CaseIterable, Hashable {
    case appleASR = "apple_asr"
    case localWhisperASR = "local_whisper_asr"
    case localParakeetASR = "local_parakeet_asr"
}

struct ProviderSourceMetadata: Equatable {
    let providerName: String
    let modelName: String
    let source: AnswerSource
    let isLocal: Bool
    let isFallback: Bool
    let fallbackReason: String?
    let providerFirstTokenObserved: Bool
    let providerStreamCompleted: Bool
    let finalVisibleSource: String
    let persistedSource: String

    static func ollamaQwen(modelName: String, fallbackReason: String? = nil) -> ProviderSourceMetadata {
        ProviderSourceMetadata(
            providerName: "Ollama Qwen",
            modelName: modelName,
            source: .ollamaQwen,
            isLocal: true,
            isFallback: fallbackReason != nil,
            fallbackReason: fallbackReason,
            providerFirstTokenObserved: false,
            providerStreamCompleted: false,
            finalVisibleSource: AnswerSource.ollamaQwen.rawValue,
            persistedSource: AnswerSource.ollamaQwen.rawValue
        )
    }

    static func deepSeek(modelName: String) -> ProviderSourceMetadata {
        ProviderSourceMetadata(
            providerName: "DeepSeek",
            modelName: modelName,
            source: .deepseekStream,
            isLocal: false,
            isFallback: false,
            fallbackReason: nil,
            providerFirstTokenObserved: false,
            providerStreamCompleted: false,
            finalVisibleSource: AnswerSource.deepseekStream.rawValue,
            persistedSource: AnswerSource.deepseekStream.rawValue
        )
    }
}

enum SetupPermissionStatus: Equatable {
    case granted
    case notGranted
    case notRequired

    var isSatisfied: Bool {
        switch self {
        case .granted, .notRequired:
            return true
        case .notGranted:
            return false
        }
    }
}

struct SetupPermissionPolicy: Equatable {
    var microphone: SetupPermissionStatus
    var speechRecognition: SetupPermissionStatus
    var systemAudio: SetupPermissionStatus
    var screenRecording: SetupPermissionStatus
    var permissionsExplicitlySkipped: Bool

    var requiredPermissionsSatisfied: Bool {
        microphone.isSatisfied && speechRecognition.isSatisfied && systemAudio.isSatisfied && screenRecording.isSatisfied
    }

    var canFinishSetup: Bool {
        requiredPermissionsSatisfied || permissionsExplicitlySkipped
    }
}
