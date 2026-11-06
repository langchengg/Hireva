import Foundation

/// Speculative Live transcript retrieval precedes question acceptance. It has
/// no GenerationIdentity, so stopping an answer must not cancel this work.
/// This owner stores the only cache and retains replaced workers until exit.
@MainActor
final class LiveRAGPrefetch {
    struct Scope: Equatable, Sendable {
        let sessionID: String?
        let snapshotID: String?
        let cacheContextID: String
    }
    struct Request: Sendable {
        let scope: Scope
        let segmentID: String
        let question: String
        let service: any ContextRetrievalService
    }
    /// Captured with the frozen retriever at submission. Revocation never
    /// revalidates an earlier request, even if the same settings return later.
    struct CacheAdmission: Equatable, Sendable {
        fileprivate let ownerID: UUID
        fileprivate let revision: UUID
    }
    struct CacheItem: Sendable {
        let scope: Scope
        let segmentID: String
        let admission: CacheAdmission
        let insertionOrder: UInt64
        let context: RetrievedContext
        let trace: RetrievalTrace
        let rawText: String
        let normalizedQuestionText: String
        let questionIntent: AnswerRelevanceIntent
    }
    enum Consumption {
        case hit(CacheItem)
        case mismatch
        case miss(staleItemCount: Int)
    }
    private struct Worker: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private enum Current: Sendable {
        case preparing(UUID)
        case running(Worker)
        var id: UUID {
            switch self { case .preparing(let id): return id; case .running(let worker): return worker.id }
        }
        var task: Task<Void, Never>? {
            if case .running(let worker) = self { return worker.task }
            return nil
        }
    }
    private var current: Current?
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var cache: [String: CacheItem] = [:]
    private var admissionClosed = false
    private let ownerID = UUID()
    private var cacheRevision = UUID()
    private var insertionOrder: UInt64 = 0
    // Unused speculative results are a bounded optimization, never authority.
    // This is a local engineering limit, not an answer/model acceptance gate.
    private static let maximumCachedItems = 32
    private let delay: any DelayProvider

    init(delay: any DelayProvider = RealDelayProvider()) { self.delay = delay }
    var currentTask: Task<Void, Never>? { current?.task }
    var cacheAdmission: CacheAdmission? {
        admissionClosed ? nil : CacheAdmission(ownerID: ownerID, revision: cacheRevision)
    }
    var cachedItems: [String: CacheItem] { cache }
    var pendingTaskCount: Int { (current?.task == nil ? 0 : 1) + retiring.count }

    // Immutable cleanup observations are actual owned handles, not another list.
    var tasksToDrain: [Task<Void, Never>] {
        (currentTask.map { [$0] } ?? []) + Array(retiring.values)
    }

    /// Freeze submission before debounce. A synchronous resolver may publish
    /// diagnostics and reenter stop/replacement, so preparing owns the same
    /// identity slot before it can create a task.
    func schedule(resolve: @escaping @MainActor () -> Request?,
        isScopeCurrent: @escaping @MainActor (Scope) -> Bool) {
        guard let admission = cacheAdmission else { return }
        cancelWorker()
        let id = UUID()
        current = .preparing(id)
        guard let request = resolve(), current?.id == id, cacheAdmission == admission else {
            finish(id: id)
            return
        }
        let delay = delay
        let task = Task { [weak self] in
            defer { self?.finish(id: id) }
            do {
                try await delay.sleep(nanoseconds: 400_000_000)
                try Task.checkCancellation()
                guard self?.current?.id == id, isScopeCurrent(request.scope),
                      !Task.isCancelled, self?.current?.id == id,
                      self?.cacheAdmission == admission else { return }
                let intent = AnswerRelevancePolicy.intent(for: request.question)
                let key = Self.cacheKey(contextID: request.scope.cacheContextID,
                    segmentID: request.segmentID, questionText: request.question, intent: intent)
                let (context, trace) = try await request.service.retrieveContextWithTrace(
                    question: request.question, intent: .unclear, maxCVWords: 240,
                    maxJDWords: 120, strategy: nil)
                try Task.checkCancellation()
                guard let self, isScopeCurrent(request.scope), !Task.isCancelled,
                      self.current?.id == id, self.cacheAdmission == admission else { return }
                // No extra MainActor.run await between scope validation and write.
                // Superseded variants of one segment cannot accumulate. Scope
                // is stored explicitly; underscores/hash collisions are not identity.
                self.removeVariants(scope: request.scope, segmentID: request.segmentID)
                self.insertionOrder += 1
                self.cache[key] = CacheItem(scope: request.scope, segmentID: request.segmentID,
                    admission: admission, insertionOrder: self.insertionOrder,
                    context: context, trace: trace,
                    rawText: request.question,
                    normalizedQuestionText: AnswerRelevancePolicy.normalizedQuestionText(for: request.question),
                    questionIntent: intent)
                self.enforceCacheBound()
                print("[PrecomputeRAG] Context cached")
            } catch is CancellationError {
                // Cancellation closes publication, but the exact worker is
                // retained until any noncooperative retrieval actually returns.
            } catch {
                print("[PrecomputeRAG] Background RAG precompute failed: code=\((error as NSError).code)")
            }
        }
        current = .running(Worker(id: id, task: task))
    }

    func cancelWorker() {
        guard let old = current else { return }
        current = nil
        guard let task = old.task else { return }
        retiring[old.id] = task
        task.cancel()
    }
    func clearCache() {
        cacheRevision = UUID()
        cache.removeAll()
    }
    func configurationDidChange(previous: AppSettings, current: AppSettings) {
        guard !admissionClosed, !Self.sameRetrievalConfiguration(previous, current) else { return }
        cancelAndClear()
    }
    func credentialWillChange(account: String, configuredAccount: String) {
        guard !admissionClosed, account == configuredAccount else { return }
        cancelAndClear()
    }
    func indexDidChange() {
        guard !admissionClosed else { return }
        cancelAndClear()
    }
    func cancelAndClear() {
        // Revoke cache admission before cancellation invokes any handlers.
        clearCache()
        cancelWorker()
    }
    func closeAdmission() {
        guard !admissionClosed else { return }
        admissionClosed = true
        cancelAndClear()
    }
    func shutdown() async {
        closeAdmission()
        while !retiring.isEmpty {
            let captured = Array(retiring.values)
            for task in captured { await task.value }
        }
    }
    private func finish(id: UUID) {
        if current?.id == id { current = nil }
        retiring.removeValue(forKey: id)
        // This is the worker's last synchronous action before returning, and
        // never awaits its own handle or starts an unowned observer task.
    }

    func consume(scope: Scope, admission: CacheAdmission?, segmentID: String,
        questionText: String, intent: AnswerRelevanceIntent) -> Consumption {
        // A queued request cannot acquire a new ticket here. Rejecting it must
        // also leave a replacement request's cache item intact.
        guard let admission, cacheAdmission == admission else { return .miss(staleItemCount: 0) }
        let key = Self.cacheKey(contextID: scope.cacheContextID, segmentID: segmentID,
            questionText: questionText, intent: intent)
        if let item = cache[key] {
            guard item.scope == scope, item.segmentID == segmentID, item.admission == admission else {
                return .mismatch
            }
            cache.removeValue(forKey: key)
            let normalized = AnswerRelevancePolicy.normalizedQuestionText(for: questionText)
            return item.normalizedQuestionText == normalized && item.questionIntent == intent
                ? .hit(item) : .mismatch
        }
        return .miss(staleItemCount: removeVariants(scope: scope, segmentID: segmentID))
    }
    @discardableResult
    private func removeVariants(scope: Scope, segmentID: String) -> Int {
        let stale = cache.compactMap { key, item in
            item.scope == scope && item.segmentID == segmentID ? key : nil
        }
        stale.forEach { cache.removeValue(forKey: $0) }
        return stale.count
    }
    private func enforceCacheBound() {
        while cache.count > Self.maximumCachedItems {
            guard let oldest = cache.min(by: { $0.value.insertionOrder < $1.value.insertionOrder }) else { return }
            cache.removeValue(forKey: oldest.key)
        }
    }
    private static func sameRetrievalConfiguration(_ left: AppSettings, _ right: AppSettings) -> Bool {
        left.enableVectorRAG == right.enableVectorRAG && left.forceHybridRAG == right.forceHybridRAG &&
        left.embeddingProviderKind == right.embeddingProviderKind && left.embeddingBaseURL == right.embeddingBaseURL &&
        left.embeddingModelName == right.embeddingModelName && left.embeddingApiKeyAccount == right.embeddingApiKeyAccount &&
        left.embeddingDimension == right.embeddingDimension && left.embeddingTimeoutSeconds == right.embeddingTimeoutSeconds &&
        left.hybridSemanticWeight == right.hybridSemanticWeight && left.hybridKeywordWeight == right.hybridKeywordWeight
    }
    static func cacheKey(contextID: String, segmentID: String, questionText: String,
        intent: AnswerRelevanceIntent) -> String {
        let normalized = AnswerRelevancePolicy.normalizedQuestionText(for: questionText)
        let clean = normalized.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return [contextID, segmentID, intent.rawValue, String(clean.hashValue)].joined(separator: "_")
    }
    deinit {
        current?.task?.cancel()
        retiring.values.forEach { $0.cancel() }
    }
}
