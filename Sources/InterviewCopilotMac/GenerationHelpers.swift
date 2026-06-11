import Foundation

final class StageBTrigger {
    private var continuation: CheckedContinuation<Void, Never>?
    private var triggered = false
    private let lock = NSLock()
    
    func wait(timeoutMs: Int) async {
        await withCheckedContinuation { cont in
            lock.lock()
            if triggered {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
            
            // Set up a timeout fallback
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                self.trigger()
            }
        }
    }
    
    func trigger() {
        lock.lock()
        defer { lock.unlock() }
        guard !triggered else { return }
        triggered = true
        continuation?.resume()
        continuation = nil
    }
}

public protocol DelayProvider: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public final class RealDelayProvider: DelayProvider {
    public init() {}
    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
