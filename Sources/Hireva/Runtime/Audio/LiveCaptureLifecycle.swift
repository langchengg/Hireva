import Foundation

/// Owns Live capture controls, transcript consumption and their exact cleanup fences.
/// Native resources remain with the injected per-round operation and its service
/// owner. A cancelled startup is inadmissible while its task is still retained.
@MainActor
final class LiveCaptureLifecycle {
    private struct Startup: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        var admitted = true
    }
    private struct Consumer: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        var admitted = true
    }
    /// One submitted concrete cleanup operation and its latest issued attempt.
    /// A returned failed attempt retains the original capture/provider closure.
    @MainActor
    private final class Teardown {
        let id: UUID
        var task: Task<Void, Never>
        enum Phase { case initial, failed, retrying, released }
        let operation: @MainActor (UUID, Bool) async -> Bool
        let onCleanupChanged: (@MainActor (UUID, Bool) -> Void)?
        var phase: Phase = .initial
        var hasFailedCleanup: Bool { phase == .failed || phase == .retrying }

        init(id: UUID, task: Task<Void, Never>, operation: @escaping @MainActor (UUID, Bool) async -> Bool,
             onCleanupChanged: (@MainActor (UUID, Bool) -> Void)?) {
            self.id = id
            self.task = task
            self.operation = operation
            self.onCleanupChanged = onCleanupChanged
        }
    }
    private struct Retiring: Sendable {
        let task: Task<Void, Never>
        let join: Task<Void, Never>
        let cancellable: Bool
        let teardown: Teardown?
    }

    // Immutable admission snapshot, not another task/resource registry. An
    // initial attempt cannot become retry-authorized merely by failing later.
    private typealias RetrySubmission = (
        record: Teardown, attempt: Task<Void, Never>, join: Task<Void, Never>?, canRetry: Bool
    )

    private var startup: Startup?
    private var teardown: Teardown?
    private var consumer: Consumer?
    private var retiring: [UUID: Retiring] = [:]
    private var admissionClosed = false

    var startupTask: Task<Void, Never>? { startup?.task }
    var startupID: UUID? {
        guard let startup, startup.admitted else { return nil }
        return startup.id
    }
    var transcriptionTask: Task<Void, Never>? { consumer?.task }
    var consumerID: UUID? {
        guard let consumer, consumer.admitted else { return nil }
        return consumer.id
    }
    var teardownTask: Task<Void, Never>? { teardown?.task }
    var teardownID: UUID? { teardown?.id }
    var hasFailedTeardown: Bool {
        teardown?.hasFailedCleanup == true || retiring.values.contains { $0.teardown?.hasFailedCleanup == true }
    }
    var failedTeardownCount: Int {
        (teardown?.hasFailedCleanup == true ? 1 : 0) +
            retiring.values.filter { $0.teardown?.hasFailedCleanup == true }.count
    }
    var retiringTaskCount: Int { retiring.count }
    /// Task execution and failed native cleanup are separate observations.
    /// A returned failed fence stays visible until a replacement stop succeeds.
    var pendingTaskCount: Int {
        (startup == nil ? 0 : 1) +
            (teardown == nil || teardown?.phase == .failed ? 0 : 1) +
            (consumer == nil ? 0 : 1) +
            retiring.values.filter { $0.teardown?.phase != .failed }.count
    }

    /// The owner creates the task and waits for previously admitted work before
    /// invoking the submitted operation. No mutable application container enters
    /// this owner; the caller freezes configuration in its operation capture.
    @discardableResult
    func start(onCleanupBlocked: (@MainActor () -> Void)? = nil,
               operation: @escaping @MainActor (UUID) async -> Void) -> Task<Void, Never>? {
        guard !admissionClosed else { return nil }
        guard !hasFailedTeardown else {
            onCleanupBlocked?()
            return nil
        }
        let previousStartup = startup
        let previousTeardown = teardownTask
        _ = invalidateStartup()
        if let previousStartup {
            startup = nil
            retire(id: previousStartup.id, task: previousStartup.task, cancellable: true)
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            // Registration cleanup runs even after admission was revoked while
            // waiting. It must not depend on the visible startupID projection.
            defer { self?.finishStartup(id: id) }
            await previousStartup?.task.value
            await previousTeardown?.value
            guard self?.isStartupCurrent(id) == true else { return }
            guard self?.hasFailedTeardown == false else {
                onCleanupBlocked?()
                return
            }
            await operation(id)
        }
        startup = Startup(id: id, task: task)
        return task
    }

    func isStartupCurrent(_ id: UUID) -> Bool {
        startupID == id && !Task.isCancelled
    }

    /// Revoke publication/start admission before cooperative cancellation. The
    /// exact registered task remains owned until its defer transfers it to join.
    @discardableResult
    func invalidateStartup() -> Task<Void, Never>? {
        let task = startupTask
        startup?.admitted = false
        task?.cancel()
        return task
    }

    /// A replacement may consume immediately while the old stream drains.
    /// Revoke the old publication identity before asking its task to cancel,
    /// and retain that exact handle in this owner's existing retirement set.
    @discardableResult
    func consume(operation: @escaping @MainActor (UUID) async -> Void) -> Task<Void, Never>? {
        guard !admissionClosed else { return nil }
        let previous = consumer
        _ = invalidateConsumer()
        if let previous {
            consumer = nil
            retire(id: previous.id, task: previous.task, cancellable: true)
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.finishConsumer(id: id) }
            guard self?.isConsumerCurrent(id) == true else { return }
            await operation(id)
        }
        consumer = Consumer(id: id, task: task)
        return task
    }

    func isConsumerCurrent(_ id: UUID) -> Bool {
        !admissionClosed && consumerID == id && !Task.isCancelled
    }

    /// The cancelled registration stays visible until its actual task exits.
    /// This is consumer cleanup, not evidence that its native producer stopped.
    @discardableResult
    func invalidateConsumer() -> Task<Void, Never>? {
        let task = transcriptionTask
        consumer?.admitted = false
        task?.cancel()
        return task
    }

    func isCurrentTeardown(_ id: UUID) -> Bool { teardownID == id }

    /// The existing order is monitor drain, stopped startup, older teardown,
    /// then this round's concrete provider/meter/native stop operation. Cleanup
    /// is admitted after closeAdmission so shutdown can stop an existing epoch.
    @discardableResult
    func queueTeardown(
        after startupFence: Task<Void, Never>?,
        quiescing monitorFence: Task<Void, Never>? = nil,
        retryRetainedFailures: Bool = false,
        onCleanupChanged: (@MainActor (UUID, Bool) -> Void)? = nil,
        operation: @escaping @MainActor (UUID) async -> Bool
    ) -> Task<Void, Never> {
        // Compatibility for operations without native retry distinctions. Both
        // signatures register exactly one operation in this same owner.
        queueTeardown(after: startupFence, quiescing: monitorFence,
            retryRetainedFailures: retryRetainedFailures, onCleanupChanged: onCleanupChanged) { id, _ in
            await operation(id)
        }
    }

    @discardableResult
    func queueTeardown(
        after startupFence: Task<Void, Never>?,
        quiescing monitorFence: Task<Void, Never>? = nil,
        retryRetainedFailures: Bool = false,
        onCleanupChanged: (@MainActor (UUID, Bool) -> Void)? = nil,
        operation: @escaping @MainActor (UUID, Bool) async -> Bool
    ) -> Task<Void, Never> {
        let failedAtSubmission = retryRetainedFailures ? retrySubmissions() : []
        let previous = teardown
        let previousTask = previous?.task
        if let previous {
            teardown = nil
            retire(id: previous.id, task: previous.task, cancellable: false, teardown: previous)
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await monitorFence?.value
            await startupFence?.value
            await previousTask?.value
            // This batch predates the new registration, so it cannot include or
            // await this task. Later failures do not expand its authority.
            await self?.retryFailedTeardowns(failedAtSubmission)
            let released = await operation(id, false)
            self?.finishTeardown(id: id, released: released)
        }
        teardown = Teardown(id: id, task: task, operation: operation, onCleanupChanged: onCleanupChanged)
        return task
    }

    /// Only an explicit external stop/shutdown calls this method. A drain or
    /// replacement start never authorizes another native stop attempt. Snapshot
    /// each failed record before yielding: concurrent callers join a retry that
    /// replaced their captured attempt instead of retrying its new failure.
    func retryFailedTeardowns() async {
        await retryFailedTeardowns(retrySubmissions())
    }

    private func retrySubmissions() -> [RetrySubmission] {
        var records: [Teardown] = []
        if let teardown, teardown.hasFailedCleanup { records.append(teardown) }
        records += retiring.values.compactMap { $0.teardown?.hasFailedCleanup == true ? $0.teardown : nil }
        return records.map {
            (record: $0, attempt: $0.task, join: retiring[$0.id]?.join, canRetry: $0.phase == .failed)
        }
    }

    private func retryFailedTeardowns(_ failures: [RetrySubmission]) async {
        for failure in failures {
            let record = failure.record
            let captured = failure.attempt
            let capturedJoin = failure.join
            await captured.value
            var joinedObserver = capturedJoin
            await joinedObserver?.value
            // Queue submission can retire a current record after its snapshot
            // captured join=nil. Join that exact attempt's newly registered
            // observer before removing it; never borrow a newer attempt's join.
            while let entry = retiring[record.id], entry.teardown === record,
                entry.task == captured, entry.join != joinedObserver {
                let exactObserver = entry.join
                await exactObserver.value
                joinedObserver = exactObserver
            }
            guard ownsTeardown(record) else { continue }
            guard failure.canRetry, record.task == captured, record.phase == .failed else {
                await record.task.value
                continue
            }
            let wasRetiring = retiring[record.id]?.teardown === record
            // The old exact worker and join observer both exited above. The
            // original operation remains the authority, including its receipts.
            if wasRetiring { retiring.removeValue(forKey: record.id) }
            record.phase = .retrying
            let retry = Task { @MainActor [weak self] in
                let released = await record.operation(record.id, true)
                self?.finishTeardown(id: record.id, released: released)
            }
            record.task = retry
            if wasRetiring {
                retire(id: record.id, task: retry, cancellable: false, teardown: record)
            }
            await retry.value
        }
    }

    private func ownsTeardown(_ record: Teardown) -> Bool {
        teardown === record || retiring[record.id]?.teardown === record
    }

    func closeAdmission() {
        admissionClosed = true
        _ = invalidateStartup()
        _ = invalidateConsumer()
    }

    /// External lifecycle callers only. A task completes by transferring its
    /// handle to a join observer; neither operation ever waits on itself here.
    /// Cancellation of a borrower cannot force a noncooperative resource out.
    func drain() async {
        while true {
            let current = [startupTask, teardownTask, transcriptionTask].compactMap { $0 }
            let joins = retiring.values.map(\.join)
            for task in current { await task.value }
            for join in joins { await join.value }
            if startup == nil, consumer == nil,
                teardown == nil || teardown?.phase == .failed,
                retiring.values.allSatisfy({ $0.teardown?.phase == .failed }) {
                return
            }
        }
    }

    private func finishStartup(id: UUID) {
        guard let registered = startup, registered.id == id else { return }
        startup = nil
        retire(id: id, task: registered.task, cancellable: true)
    }

    private func finishConsumer(id: UUID) {
        guard let registered = consumer, registered.id == id else { return }
        consumer = nil
        retire(id: id, task: registered.task, cancellable: true)
    }

    private func finishTeardown(id: UUID, released: Bool) {
        let registered: Teardown?
        if teardown?.id == id { registered = teardown }
        else { registered = retiring[id]?.teardown }
        guard let registered else { return }
        registered.phase = released ? .released : .failed
        if released, teardown === registered {
            teardown = nil
            retire(id: id, task: registered.task, cancellable: false, teardown: registered)
        }
        // Read-only UI projections must observe the committed owner state.
        // No owner mutation follows a synchronous/reentrant observer callback.
        registered.onCleanupChanged?(id, released)
    }

    private func retire(id: UUID, task: Task<Void, Never>, cancellable: Bool, teardown: Teardown? = nil) {
        guard retiring[id] == nil else { return }
        let join = Task { @MainActor [weak self] in
            await task.value
            guard let self, let entry = self.retiring[id], entry.task == task,
                entry.teardown?.phase != .failed else { return }
            self.retiring.removeValue(forKey: id)
        }
        retiring[id] = Retiring(task: task, join: join, cancellable: cancellable, teardown: teardown)
    }

    deinit {
        // ARC cannot await. Explicit shutdown/drain is the resource-exit proof;
        // cancellation here only asks still-owned controls/consumers to stop.
        startup?.task.cancel()
        consumer?.task.cancel()
        for entry in retiring.values where entry.cancellable { entry.task.cancel() }
    }
}
