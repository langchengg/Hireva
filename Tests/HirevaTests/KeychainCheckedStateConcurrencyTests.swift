import Foundation
import Testing
@testable import Hireva

struct KeychainCheckedStateConcurrencyTests {
    // Post-contract characterization. Never run the old unlocked dictionary in
    // concurrent tasks merely to seek a crash; identity RED is a separate test.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func distinctAccountsAndDiagnosticSnapshotsRemainSafeAcrossActualOperations(reverse: Bool) async throws {
        let store = InMemoryMockKeychainStore()
        let keys = KeychainService(store: store)
        for iteration in 0..<20 {
            let accounts = (0..<4).map { "synthetic.\(iteration).\($0)" }
            let ordered = reverse ? Array(accounts.reversed()) : accounts
            try await withThrowingTaskGroup(of: Void.self) { group in
                for account in ordered {
                    group.addTask {
                        try Task.checkCancellation()
                        let value = "synthetic-value-\(account)"
                        try keys.saveAPIKey(value, account: account)
                        #expect(try keys.loadAPIKeyForProviderRequest(account: account) == value)
                        #expect(keys.apiKeyAccessState(account: account).hasReadableKey)
                        let snapshot = keys.diagnosticSnapshot
                        #expect(snapshot.legacyItemCount >= 0)
                        #expect(!snapshot.lastReadStatus.contains(value))
                        #expect(!snapshot.lastWriteStatus.contains(value))
                        try keys.deleteAPIKey(account: account)
                        #expect(try keys.loadAPIKey(account: account) == nil)
                    }
                }
                try await group.waitForAll()
            }
            #expect(keys.diagnosticSnapshot.lastWriteStatus == "Deleted")
            #expect(keys.diagnosticSnapshot.lastReadStatus == "Success")
            for account in accounts {
                #expect(try store.loadGenericPassword(service: KeychainConstants.service, account: account) == nil)
            }
        }
    }
}
