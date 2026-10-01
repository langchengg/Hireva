import Foundation

/// A revoked ticket never becomes valid again, even if saving is re-enabled.
/// The lock spans the write so revocation and the persistence boundary serialize.
final class PersistenceConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var enabled = true
    func update(enabled: Bool) { lock.lock(); defer { lock.unlock() }; if self.enabled != enabled { generation += 1 }; self.enabled = enabled }
    func invalidate() { lock.lock(); generation += 1; lock.unlock() }
    func ticket() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
    func isCurrent(ticket: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return enabled && ticket == generation }
    func write(ticket: Int, _ operation: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, ticket == generation else { throw CancellationError() }
        try operation()
    }
}
