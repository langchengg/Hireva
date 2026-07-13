import Darwin
import Foundation
import Hireva

do {
    try HirevaStartup.preparePersistentIdentity()
} catch {
    fputs("Hireva could not migrate its persistent data safely: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--repair-rag-index") || arguments.contains("--rebuild-clean-rag-index") {
    let regenerateEmbeddings = !arguments.contains("--skip-embeddings")
    let semaphore = DispatchSemaphore(value: 0)
    var processExitCode: Int32 = 0

    Task {
        do {
            let result = try await HirevaMaintenance.rebuildCleanRAGIndex(
                regenerateEmbeddings: regenerateEmbeddings
            )
            print("Clean RAG index rebuild complete.")
            print("Documents rebuilt: \(result.documentsRebuilt)")
            print("Chunks rebuilt: \(result.chunksRebuilt)")
            print("Historical retrieved sources sanitized: \(result.sanitizedRetrievedSources)")
            print("Historical suggestion cards sanitized: \(result.sanitizedSuggestionCards)")
            print("Embeddings updated: \(result.embeddingsUpdated)")
            if !result.embeddingErrors.isEmpty {
                print("Embedding warnings:")
                for warning in result.embeddingErrors.prefix(20) {
                    print("- \(warning)")
                }
            }
            print("Polluted chunk count: \(result.pollutedChunkCount)")
            print("Polluted retrieved source count: \(result.pollutedRetrievedSourceCount)")
            print("Polluted suggestion card count: \(result.pollutedSuggestionCardCount)")
            processExitCode = result.pollutedChunkCount == 0 && result.pollutedRetrievedSourceCount == 0 && result.pollutedSuggestionCardCount == 0 ? 0 : 2
        } catch {
            fputs("Clean RAG index rebuild failed: \(error.localizedDescription)\n", stderr)
            processExitCode = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    exit(processExitCode)
}

HirevaApp.main()
