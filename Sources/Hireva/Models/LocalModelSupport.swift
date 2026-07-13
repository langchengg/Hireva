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

    init(relativePath: String, minimumBytes: Int64? = nil) {
        self.relativePath = relativePath
        self.minimumBytes = minimumBytes
    }
}

struct LocalModelDescriptor: Codable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let kind: LocalModelKind
    let sizeBytes: Int64?
    let downloadURL: URL?
    let checksum: String?
    let storageRelativePath: String
    let requiredFiles: [LocalModelFileRequirement]

    init(
        id: String,
        displayName: String,
        kind: LocalModelKind,
        sizeBytes: Int64?,
        downloadURL: URL?,
        checksum: String?,
        storageRelativePath: String,
        requiredFiles: [LocalModelFileRequirement] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.downloadURL = downloadURL
        self.checksum = checksum
        self.storageRelativePath = storageRelativePath
        self.requiredFiles = requiredFiles
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
        displayName: "Parakeet TDT 0.6B",
        kind: .transcription,
        sizeBytes: 671_145_061,
        downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"),
        checksum: nil,
        storageRelativePath: "asr/parakeet-tdt-0.6b-v3-int8",
        requiredFiles: [
            LocalModelFileRequirement(relativePath: "encoder.int8.onnx", minimumBytes: 652_000_000),
            LocalModelFileRequirement(relativePath: "decoder.int8.onnx", minimumBytes: 11_800_000),
            LocalModelFileRequirement(relativePath: "joiner.int8.onnx", minimumBytes: 6_300_000),
            LocalModelFileRequirement(relativePath: "tokens.txt", minimumBytes: 90_000)
        ]
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
    func deleteModel(_ model: LocalModelDescriptor) async throws
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool
    func fileURL(for model: LocalModelDescriptor) -> URL
}

enum LocalModelManagerError: LocalizedError, Equatable {
    case missingDownloadURL(String)
    case invalidRelativePath(String)
    case downloadFailed(String)
    case checksumUnsupported

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
