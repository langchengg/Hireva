import Foundation
import Combine
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DocumentCallbackAdmissionTests {
    @Test(arguments: ["typed", "fileImport", "reprocess"])
    func sourceCallbackCanCloseAdmissionBeforeTheActualSave(origin: String) async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        let bytes = Data(Self.original.utf8)
        let material = try MaterialExtractionService.extract(data: bytes, filename: "synthetic.md")
        _ = try repository.saveDocument(type: .cv, title: "Synthetic original", content: material.text,
            material: material, originalData: bytes)
        let before = try repository.documents()
        let beforeChunks = try repository.allChunks()
        let replacement = try MaterialExtractionService.extract(data: Data(Self.replacement.utf8), filename: "replacement.md")
        var owner: DocumentsState?
        var hookCount = 0, didSaveCount = 0
        owner = DocumentsState(repository: repository,
            extractURL: { _ in (replacement, Data(Self.replacement.utf8)) },
            extractData: { _, _ in replacement },
            willSave: { _ in hookCount += 1; owner?.closeAdmission() },
            didSave: { _, _ in didSaveCount += 1 })
        let state = try #require(owner)
        var task: Task<Void, Never>?
        do {
            switch origin {
            case "typed":
                do {
                    _ = try state.saveDocument(type: .cv, title: "Replacement", content: Self.replacement)
                    Issue.record("A synchronous source hook closed admission, but typed save returned success.")
                } catch is CancellationError {}
            case "fileImport":
                state.importDocument(from: URL(fileURLWithPath: "/HirevaSynthetic/replacement.md"), as: .cv)
                let operation = try #require(state.importTask)
                task = operation
                await operation.value
            default:
                state.reprocessDocument(try #require(before.first))
                let operation = try #require(state.importTask)
                task = operation
                await operation.value
            }
            #expect(hookCount == 1)
            #expect(didSaveCount == 0)
            #expect(try repository.documents() == before)
            #expect(try repository.allChunks().map(\.id) == beforeChunks.map(\.id))
            #expect(!state.importStatus.hasPrefix("Imported and indexed"))
            #expect(!state.importStatus.hasPrefix("Reprocessed from saved original"))
            await state.shutdown()
            #expect(state.pendingImportTaskCount == 0)
            owner = nil
            try database.close()
        } catch {
            task?.cancel()
            await task?.value
            await state.shutdown()
            owner = nil
            try database.close()
            throw error
        }
    }

    @Test
    func importStatusObserverCanCloseBeforeExtractorTaskRegistration() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        let bytes = Data(Self.original.utf8)
        let material = try MaterialExtractionService.extract(data: bytes, filename: "synthetic.md")
        var extractionCalls = 0
        let owner = DocumentsState(repository: repository, extractURL: { _ in
            extractionCalls += 1
            return (material, bytes)
        })
        let observation = owner.updates.sink { update in
            guard case .importStatus = update else { return }
            let status = owner.importStatus
            if status == "Extracting locally…" { owner.closeAdmission() }
        }
        defer { observation.cancel() }
        owner.importDocument(from: URL(fileURLWithPath: "/HirevaSynthetic/synthetic.md"), as: .cv)
        let task = owner.importTask
        await task?.value
        #expect(task == nil)
        #expect(extractionCalls == 0)
        #expect(owner.importStatus == "Import cancelled")
        #expect(try repository.documents().isEmpty)
        await owner.shutdown()
        #expect(owner.pendingImportTaskCount == 0)
        try database.close()
    }

    @Test(arguments: ["running", "ready"])
    func phaseObserverClosingAdmissionCannotBeOverwrittenByTheOriginalPublication(phaseToClose: String) async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        _ = try repository.saveDocument(type: .cv, title: "Synthetic original", content: Self.original)
        var settings = AppSettings.default
        settings.embeddingProviderKind = .mock
        settings.embeddingModelName = "callback-model"
        settings.embeddingDimension = 3
        let provider = CallbackEmbeddingProvider()
        var feedback: [ActionFeedback] = []
        let owner = DocumentEmbeddingState(repository: repository, configuration: { settings },
            resolveProvider: { _ in provider }, feedback: { feedback.append($0) })
        var didClose = false
        let observation = owner.updates.sink { update in
            guard case .phase = update else { return }
            let phase = owner.phase
            let matches = phaseToClose == "running" ? phase == .running : phase == .ready(1)
            if matches && !didClose { didClose = true; owner.closeAdmission() }
        }
        defer { observation.cancel() }
        do {
            let task = try #require(owner.rebuildAll())
            await task.value
            #expect(didClose)
            #expect(owner.phase == .cancelled)
            #expect(!owner.isRebuilding)
            #expect(feedback.last?.kind == .warning)
            #expect(!feedback.contains { $0.kind == .success })
            if phaseToClose == "running" {
                #expect(await provider.callCount == 0)
                #expect(!feedback.contains { $0.kind == .loading })
                #expect(try repository.allChunks().allSatisfy { $0.embedding == nil })
            } else { #expect(await provider.callCount == 1) }
            await owner.shutdown()
            #expect(owner.pendingTaskCount == 0)
            try database.close()
        } catch {
            await owner.shutdown()
            try database.close()
            throw error
        }
    }

    @Test
    func progressObserverClosingAdmissionPreventsTheNextFrozenChunk() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        _ = try repository.saveDocument(type: .cv, title: "Synthetic CV", content: Self.original)
        _ = try repository.saveDocument(type: .jobDescription, title: "Synthetic JD", content: Self.replacement)
        #expect(try repository.allChunks().count == 2)
        var settings = AppSettings.default
        settings.embeddingProviderKind = .mock
        settings.embeddingModelName = "callback-model"
        settings.embeddingDimension = 3
        let provider = CallbackEmbeddingProvider()
        var feedback: [ActionFeedback] = []
        let owner = DocumentEmbeddingState(repository: repository, configuration: { settings },
            resolveProvider: { _ in provider }, feedback: { feedback.append($0) })
        var didClose = false
        let observation = owner.updates.sink { update in
            guard case .progress = update else { return }
            let progress = owner.progress
            if progress > 0 && !didClose { didClose = true; owner.closeAdmission() }
        }
        defer { observation.cancel() }
        do {
            let task = try #require(owner.rebuildAll())
            await task.value
            #expect(didClose)
            #expect(await provider.callCount == 1)
            #expect(try repository.allChunks().filter { $0.embedding != nil }.count == 1)
            #expect(owner.phase == .cancelled)
            #expect(!feedback.contains { $0.kind == .success })
            await owner.shutdown()
            try database.close()
        } catch {
            await owner.shutdown()
            try database.close()
            throw error
        }
    }

    private static let original = "Synthetic source: I designed an isolated document flow and validated transactional persistence using controlled test inputs and exact source locations."
    private static let replacement = "Synthetic replacement: this independent document describes required reliability skills and does not authorize any candidate experience or remote operation."
}

private actor CallbackEmbeddingProvider: EmbeddingProvider {
    nonisolated let providerID = "controlled-mock"
    nonisolated let modelName = "callback-model"
    private(set) var callCount = 0
    var dimension: Int { get async throws { 3 } }
    func embed(text: String) async throws -> [Float] { callCount += 1; return [1, 0, 0] }
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for text in texts { result.append(try await embed(text: text)) }
        return result
    }
}
