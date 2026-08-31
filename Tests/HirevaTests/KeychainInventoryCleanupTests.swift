import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
struct KeychainInventoryCleanupTests {
    private static let canonicalOrphanAccount = "provider.fixture.orphan"
    private static let legacyOrphanAccount = "embedding.fixture.orphan"
    private static let syntheticCredential = "fixture-credential-value"

    @Test
    func realInventoryQueryIsExactNonInteractiveAndAttributesOnly() throws {
        let service = "com.example.fixture.credentials"
        let query = RealKeychainStore.genericPasswordAccountQuery(service: service)

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == service)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnRef as String] == nil)
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)
    }

    @Test
    func inMemoryInventoryIsServiceScopedAndDeterministic() throws {
        let store = InMemoryMockKeychainStore()
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: KeychainConstants.service,
            account: "z-account"
        )
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: KeychainConstants.service,
            account: "a-account"
        )
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: "com.example.foreign.credentials",
            account: "foreign-account"
        )

        let keychain = KeychainService(store: store)
        #expect(try keychain.storedAPIKeyAccounts().sorted() == ["a-account", "z-account"])
        #expect(try store.genericPasswordAccounts(service: "com.example.foreign.credentials") == ["foreign-account"])
    }

    @Test
    func migrationDiscoversCanonicalOrphanAccountWithoutOverwritingLegacy() throws {
        let store = InMemoryMockKeychainStore()
        try store.saveGenericPassword(
            data: Data(),
            service: KeychainConstants.service,
            account: Self.canonicalOrphanAccount
        )
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: LegacyHirevaIdentifiers.keychainService,
            account: Self.canonicalOrphanAccount
        )
        let keychain = KeychainService(store: store)

        keychain.performMigrationIfNeeded()

        #expect(keychain.migrationPerformed)
        #expect(try keychain.storedAPIKeyAccounts().contains(Self.canonicalOrphanAccount))
        #expect(try store.loadGenericPassword(
            service: KeychainConstants.service,
            account: Self.canonicalOrphanAccount
        ) == Self.syntheticCredential)
        #expect(try store.loadGenericPassword(
            service: LegacyHirevaIdentifiers.keychainService,
            account: Self.canonicalOrphanAccount
        ) == Self.syntheticCredential)
    }

    @Test
    func migrationCoversHistoricalLowercaseBundleServiceAndRetainsSourceItem() throws {
        let historicalService = "com.interviewcopilot.mac"
        let historicalAccount = "DeepSeekAPIKey"
        let store = InMemoryMockKeychainStore()
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: historicalService,
            account: historicalAccount
        )
        let keychain = KeychainService(store: store)

        keychain.performMigrationIfNeeded()

        #expect(keychain.legacyItemFound)
        #expect(keychain.legacyItemCount == 1)
        #expect(keychain.migrationPerformed)
        #expect(try store.loadGenericPassword(
            service: KeychainConstants.service,
            account: KeychainConstants.deepSeekAccount
        ) == Self.syntheticCredential)
        #expect(try store.loadGenericPassword(
            service: historicalService,
            account: historicalAccount
        ) == Self.syntheticCredential)
    }

    @Test
    func deleteAllAPIKeysCoversHistoricalLowercaseBundleService() throws {
        let historicalService = "com.interviewcopilot.mac"
        let store = InMemoryMockKeychainStore()
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: historicalService,
            account: Self.legacyOrphanAccount
        )
        let keychain = KeychainService(store: store)

        let deletedCount = try keychain.deleteAllAPIKeys()

        #expect(deletedCount == 1)
        #expect(try store.genericPasswordAccounts(service: historicalService).isEmpty)
    }

    @Test
    @MainActor
    func deleteAllLocalDataRemovesProviderEmbeddingAndOrphanCredentialsOnly() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "KeychainInventoryCleanup")
        let store = InMemoryMockKeychainStore()
        let keychain = KeychainService(store: store)
        let appState = AppState(database: database, keychainService: keychain)
        let canonicalAccounts = [
            KeychainConstants.deepSeekAccount,
            KeychainConstants.defaultEmbeddingAccount,
            "provider.openAICompatible.fixture",
            Self.canonicalOrphanAccount,
            Self.legacyOrphanAccount
        ]
        for account in canonicalAccounts {
            try store.saveGenericPassword(
                data: Data(Self.syntheticCredential.utf8),
                service: KeychainConstants.service,
                account: account
            )
        }
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: LegacyHirevaIdentifiers.keychainService,
            account: "DeepSeekAPIKey"
        )
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: LegacyHirevaIdentifiers.olderKeychainServices[0],
            account: Self.legacyOrphanAccount
        )
        let foreignService = "com.example.foreign.credentials"
        try store.saveGenericPassword(
            data: Data(Self.syntheticCredential.utf8),
            service: foreignService,
            account: "foreign-account"
        )

        appState.deleteAllLocalData(includeAPIKey: true)

        let appServices = Set(
            [KeychainConstants.service, LegacyHirevaIdentifiers.keychainService] +
                LegacyHirevaIdentifiers.olderKeychainServices
        )
        for service in appServices {
            #expect(try store.genericPasswordAccounts(service: service).isEmpty)
        }
        #expect(try store.genericPasswordAccounts(service: foreignService) == ["foreign-account"])
        let feedback = try #require(appState.latestActionFeedback(for: ActionID.clearLocalData))
        #expect(feedback.kind == .success)
        #expect(feedback.message.contains("all app-owned provider and embedding keys were cleared"))
        #expect(feedback.message.contains(Self.syntheticCredential) == false)
    }

    @Test
    @MainActor
    func deleteAllLocalDataDoesNotReportSuccessWhenCredentialDeletionFails() throws {
        final class DeleteFailingStore: KeychainStore {
            func saveGenericPassword(data: Data, service: String, account: String) throws {}

            func loadGenericPassword(
                service: String,
                account: String,
                authenticationPolicy: KeychainAuthenticationPolicy
            ) throws -> String? {
                nil
            }

            func genericPasswordAccounts(service: String) throws -> Set<String> {
                service == KeychainConstants.service ? ["provider.fixture.cannot-delete"] : []
            }

            func deleteGenericPassword(service: String, account: String) throws {
                throw KeychainError.unexpectedStatus(errSecAuthFailed)
            }
        }

        let database = try TestSupport.makeTemporaryDatabase(prefix: "KeychainCleanupFailure")
        let appState = AppState(
            database: database,
            keychainService: KeychainService(store: DeleteFailingStore())
        )

        appState.deleteAllLocalData(includeAPIKey: true)

        let feedback = try #require(appState.latestActionFeedback(for: ActionID.clearLocalData))
        #expect(feedback.kind == .error)
        #expect(feedback.title == "Clear failed")
        #expect(feedback.message.contains("Keychain operation failed"))
    }
}
