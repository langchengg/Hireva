import Foundation

enum AudioInputSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case mock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        case .mock:
            return "Mock"
        }
    }
}

protocol AudioInputService: AnyObject {
    var source: AudioInputSource { get }
    var isRunning: Bool { get }
    func start() async throws
    func stop()
}

final class MicrophoneAudioInputService: AudioInputService {
    let source: AudioInputSource = .microphone
    private(set) var isRunning = false

    func start() async throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

final class MockAudioInputService: AudioInputService {
    let source: AudioInputSource = .mock
    private(set) var isRunning = false

    func start() async throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

final class FutureSystemAudioInputService: AudioInputService {
    let source: AudioInputSource = .systemAudio
    private(set) var isRunning = false

    func start() async throws {
        throw TranscriptionError.unavailable("System audio capture is planned for a future version. macOS 14.4+ Core Audio process taps can support this with public APIs and normal permissions.")
    }

    func stop() {
        isRunning = false
    }
}
