import Foundation
import Combine

/// Owns preparation input, results and work. Leaving the view and entering an
/// audio session use the same cancellation boundary; cancelled work remains
/// owned until its transport or isolated SQL operation has actually exited.
@MainActor
final class PreparationState: ObservableObject {
    typealias Fetch = @Sendable (String) async throws -> PublicRoleBrief
    typealias RunSQL = @Sendable (String) async -> SQLPracticeResult

    @Published var url = ""
    @Published var query = "SELECT c.name, SUM(o.amount) AS total\nFROM customers c LEFT JOIN orders o ON c.id = o.customer_id\nGROUP BY c.id, c.name ORDER BY c.id;"
    @Published var code = ""
    // The notification-only pulse carries no business value. All output facts
    // commit before synchronous observers can submit/cancel another request.
    @Published private var observationPulse: Void = ()
    private(set) var brief: PublicRoleBrief? { didSet { observationPulse = () } }
    private(set) var sql: SQLPracticeResult? { didSet { observationPulse = () } }
    private(set) var busy = false { didSet { observationPulse = () } }
    private(set) var error = "" { didSet { observationPulse = () } }
    private(set) var records: [PreparationRecord] = [] { didSet { observationPulse = () } }
    private(set) var selectedRecordText = "" { didSet { observationPulse = () } }

    private let repository: PreparationRepository
    private let consent: PersistenceConsent
    private let historyEnabled: () -> Bool
    private let fetchPage: Fetch
    private let executeSQL: RunSQL
    private var operationID = UUID()
    private var worker: Task<Void, Never>?
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var admissionClosed = false
    #if DEBUG
    // Observation only: tests retain the original registered Task for exact
    // cleanup even when the baseline loses its public worker registration.
    var workerRegisteredForTesting: (@MainActor (UUID, Task<Void, Never>) -> Void)?
    #endif

    init(repository: PreparationRepository, consent: PersistenceConsent,
         historyEnabled: @escaping () -> Bool, fetch: @escaping Fetch,
         runSQL: @escaping RunSQL) {
        self.repository = repository
        self.consent = consent
        self.historyEnabled = historyEnabled
        self.fetchPage = fetch
        self.executeSQL = runSQL
    }

    var pendingTaskCount: Int { retiring.count + (worker == nil ? 0 : 1) }

    func cancel() {
        let id = UUID()
        retireWorker(nextID: id)
        guard operationID == id else { return }
        busy = false // Last effect: a synchronous observer can now start again.
    }

    private func retireWorker(nextID: UUID) {
        let previous = operationID, captured = worker
        operationID = nextID // Revoke publication before requesting cancellation.
        worker = nil // A cancellation callback cannot erase a newer registration.
        if let captured {
            retiring[previous] = captured
            captured.cancel()
        }
    }

    private func accepts(_ id: UUID) -> Bool {
        !admissionClosed && operationID == id && worker?.isCancelled != true
    }

    func closeAdmission() {
        admissionClosed = true
        cancel()
    }

    func shutdown() async {
        closeAdmission()
        await finishPendingWork()
    }

    func finishPendingWork() async {
        let pending = Array(retiring.values) + (worker.map { [$0] } ?? [])
        for task in pending { await task.value }
    }

    private func didExit(_ id: UUID) {
        retiring.removeValue(forKey: id)
        if operationID == id { worker = nil; busy = false }
    }

    func refresh() {
        do { records = try repository.records() }
        catch { self.error = error.localizedDescription }
    }

    func select(_ record: PreparationRecord) {
        selectedRecordText = String(decoding: record.payload, as: UTF8.self)
    }

    func delete(_ record: PreparationRecord) {
        do {
            try repository.delete(record.id)
            selectedRecordText = ""
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func fetch() {
        guard !admissionClosed else { return }
        let text = url, ticket = consent.ticket(), id = UUID()
        retireWorker(nextID: id)
        guard accepts(id) else { return }
        let shouldSave = historyEnabled(), fetch = fetchPage
        guard accepts(id) else { return }
        // Registration precedes every notification. A reentrant replacement
        // must retire this exact worker rather than lose the inner request.
        worker = Task { [weak self] in
            defer { self?.didExit(id) }
            do {
                guard self?.accepts(id) == true else { return }
                let result = try await fetch(text)
                guard let self, self.accepts(id) else { return }
                self.brief = result
                guard self.accepts(id) else { return }
                if shouldSave {
                    // The original admission ticket remains revoked after off→on.
                    try self.consent.write(ticket: ticket) {
                        try self.repository.save(result, kind: "public-url-brief")
                    }
                }
                guard self.accepts(id) else { return }
                self.refresh()
            } catch is CancellationError {
                // Cancellation or a revoked save ticket is not a transport error.
            } catch {
                guard let self, self.accepts(id) else { return }
                self.error = error.localizedDescription
            }
        }
        #if DEBUG
        if let worker { workerRegisteredForTesting?(id, worker) }
        #endif
        guard accepts(id) else { return }
        busy = true
        guard accepts(id) else { return }
        error = ""
    }

    func runSQL() {
        guard !admissionClosed else { return }
        let text = query, ticket = consent.ticket(), id = UUID()
        retireWorker(nextID: id)
        guard accepts(id) else { return }
        let shouldSave = historyEnabled(), run = executeSQL
        guard accepts(id) else { return }
        worker = Task { [weak self] in
            defer { self?.didExit(id) }
            guard self?.accepts(id) == true else { return }
            let result = await run(text)
            guard let self, self.accepts(id) else { return }
            self.sql = result
            guard self.accepts(id) else { return }
            if shouldSave {
                do {
                    try self.consent.write(ticket: ticket) {
                        try self.repository.save(result, kind: "sql-execution")
                    }
                    guard self.accepts(id) else { return }
                    self.refresh()
                } catch is CancellationError {
                    // Keep the temporary result while refusing the stale write.
                } catch {
                    guard self.accepts(id) else { return }
                    self.error = error.localizedDescription
                }
            }
        }
        #if DEBUG
        if let worker { workerRegisteredForTesting?(id, worker) }
        #endif
        guard accepts(id) else { return }
        busy = true
        guard accepts(id) else { return }
        error = ""
    }

    deinit {
        worker?.cancel()
        retiring.values.forEach { $0.cancel() }
    }
}
