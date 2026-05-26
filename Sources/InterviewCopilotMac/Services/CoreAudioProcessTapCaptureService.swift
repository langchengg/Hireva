import Foundation

/// Protocol defining future core audio process tap capabilities.
public protocol CoreAudioProcessTapCaptureService: AnyObject {
    var isTapping: Bool { get }
    func startCapture(processIdentifier: pid_t) async throws
    func stopCapture()
}

/// A stub service for future system audio capture support (e.g. Zoom, Teams, Meet).
public final class FutureSystemAudioCaptureService: CoreAudioProcessTapCaptureService {
    public private(set) var isTapping = false

    public init() {}

    public func startCapture(processIdentifier: pid_t) async throws {
        throw TranscriptionError.unavailable(
            "System audio capture is planned for a future version. macOS 14.4+ Core Audio process taps can support this with public APIs and normal permissions."
        )
    }

    public func stopCapture() {
        isTapping = false
    }
}
