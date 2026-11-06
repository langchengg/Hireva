import Foundation

/// The original default-mode, one-second Timer stays on MainActor. Its already
/// owned worker retains the exact Timer until install-thread invalidation.
@MainActor
final class AudioSignalMonitor {
    private enum Lifecycle {
        case idle, starting(UUID), running(UUID), stopping(UUID), closed(UUID?)
        var identity: UUID? {
            switch self {
            case .idle: return nil
            case .starting(let id), .running(let id), .stopping(let id): return id
            case .closed(let id): return id
            }
        }
    }
    typealias TimerCallback = @Sendable (Timer) -> Void
    typealias ScheduleTimer = @MainActor (@escaping TimerCallback) -> Timer
    private let tick: @MainActor () -> Void
    private let scheduleTimer: ScheduleTimer
    private var lifecycle: Lifecycle = .idle
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var stopSignal: AsyncStream<Void>.Continuation?
    var ownedWorker: Task<Void, Never>? { worker }
    var currentTimer: Timer? { timer }
    var hasPendingWork: Bool { worker != nil }

    init(tick: @escaping @MainActor () -> Void,
        scheduleTimer: @escaping ScheduleTimer = { callback in
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: callback)
        }) {
        self.tick = tick
        self.scheduleTimer = scheduleTimer
    }

    @discardableResult
    func start() async -> Task<Void, Never>? {
        guard !Task.isCancelled else { return nil }
        if case .closed = lifecycle { return nil }
        let previous = stop()
        let id = UUID()
        lifecycle = .starting(id)
        await previous?.value
        guard !Task.isCancelled, case .starting(let submitted) = lifecycle, submitted == id else {
            // An interrupted start only settles its own already joined fence.
            finish(id)
            return nil
        }
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let exactTimer = scheduleTimer { [weak self] _ in
            // The only producer is the Timer installed above on MainActor's
            // macOS main runloop. This callback never creates another Task.
            MainActor.assumeIsolated {
                guard let self, case .running(let active) = self.lifecycle, active == id else { return }
                self.tick()
            }
        }
        let task = Task { [weak self] in
            defer {
                exactTimer.invalidate() // Same installation actor, exact epoch.
                self?.finish(id)
            }
            var iterator = signals.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        lifecycle = .running(id)
        timer = exactTimer
        stopSignal = signals.continuation
        worker = task
        return task
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        switch lifecycle {
        case .starting(let id), .running(let id): lifecycle = .stopping(id)
        default: break
        }
        // Invalidate authority before releasing the timer source. Normal stop
        // is synchronous on the installation actor; the waiter stays owned.
        timer?.invalidate()
        timer = nil
        stopSignal?.finish()
        worker?.cancel()
        return worker
    }

    func closeAdmission() {
        _ = stop()
        lifecycle = .closed(lifecycle.identity)
    }

    func shutdown() async {
        closeAdmission()
        let exact = worker
        await exact?.value
    }

    private func finish(_ id: UUID) {
        guard lifecycle.identity == id else { return }
        timer = nil
        stopSignal = nil
        worker = nil
        if case .closed = lifecycle { lifecycle = .closed(nil) }
        else { lifecycle = .idle }
    }

    deinit {
        // These two handles are Sendable. The existing worker still strongly
        // retains the Timer and invalidates it on MainActor, even when ARC
        // releases this owner on another executor. No cleanup Task is spawned.
        stopSignal?.finish()
        worker?.cancel()
    }
}
