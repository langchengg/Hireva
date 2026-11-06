import Dispatch
import Foundation
@testable import Hireva

/// Test-only scheduling evidence. Immutable fields make this trace Sendable;
/// it owns no task and changes neither the operation nor its safety deadline.
final class TestEventWaitTrace: Sendable {
    let label: String
    let id = UUID()
    private let enabled: Bool
    private let createdAt = DispatchTime.now().uptimeNanoseconds

    init(label: String) {
        self.label = label
        enabled = ProcessInfo.processInfo.environment["HIREVA_TEST_EVENT_TRACE"] == "1"
    }

    func mark(_ phase: String) {
        guard enabled else { return }
        // Bracket wall time before correlating with Testing event timestamps.
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let unixTime = Date().timeIntervalSince1970
        let afterWallSample = DispatchTime.now().uptimeNanoseconds
        let fields: [String: Any] = [
            "trace_id": id.uuidString,
            "label": label,
            "phase": phase,
            "uptime_nanoseconds": timestamp,
            "unix_time_seconds": unixTime,
            "uptime_after_wall_nanoseconds": afterWallSample,
            "elapsed_ms": Double(timestamp - createdAt) / 1_000_000
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print("[TestEventWaitTrace] \(line)")
    }

    /// Logical readiness is bounded by the owning test's timeLimit. It is not
    /// a performance deadline for a task still queued on a loaded MainActor.
    /// Parent cancellation ends AsyncStream.next(), allowing fixture cleanup.
    func nextEvent<Element: Sendable>(in events: AsyncStream<Element>, event: String) async throws -> Element {
        mark("consumer.\(event).requested")
        defer { mark("consumer.\(event).return") }
        try Task.checkCancellation()
        mark("consumer.\(event).child_entered")
        var iterator = events.makeAsyncIterator()
        guard let next = await iterator.next() else {
            mark("consumer.\(event).nil")
            try Task.checkCancellation()
            throw TestEventWaitFailure.endedBeforeEvent
        }
        try Task.checkCancellation()
        mark("consumer.\(event).event_consumed")
        return next
    }
}

enum TestEventWaitFailure: Error { case endedBeforeEvent }
