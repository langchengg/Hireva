// Stores provider API keys in the macOS Keychain behind stable service/account
// names.
// Never log raw API keys. Repeated authorization prompts are expected with
// ad-hoc signing because each rebuilt binary has a different CDHash.

import Foundation
import LocalAuthentication
import Security
import os

/// Normalized Keychain failures surfaced to provider/settings UI.
enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .invalidData:
            return "The saved keychain item could not be read."
        }
    }

    var status: OSStatus? {
        if case .unexpectedStatus(let status) = self {
            return status
        }
        return nil
    }

    var isAuthorizationOrTrustFailure: Bool {
        guard let status else { return false }
        return status == errSecAuthFailed ||
            status == errSecInteractionNotAllowed ||
            status == errSecUserCanceled ||
            status == KeychainConstants.errSecInDarkWake
    }
}

/// User-facing state for an API key without exposing the raw key.
enum KeychainAPIKeyAccessState: Equatable, Sendable {
    case available(maskedKey: String, keyLengthCategory: String)
    case missing
    case authorizationRequired(String)
    case unreadable(String)

    var hasReadableKey: Bool {
        if case .available = self { return true }
        return false
    }

    var maskedDisplay: String {
        switch self {
        case .available(let maskedKey, _):
            return maskedKey
        case .missing:
            return "None"
        case .authorizationRequired:
            return "Needs re-authorization"
        case .unreadable:
            return "Configured, unreadable"
        }
    }

    var statusDisplay: String {
        switch self {
        case .available:
            return "Success"
        case .missing:
            return "Missing"
        case .authorizationRequired(let message), .unreadable(let message):
            return message
        }
    }

    var keyLengthCategory: String {
        switch self {
        case .available(_, let category):
            return category
        case .missing:
            return "empty"
        case .authorizationRequired, .unreadable:
            return "unknown"
        }
    }
}

protocol KeychainStore: AnyObject, Sendable {
    func saveGenericPassword(data: Data, service: String, account: String) throws
    func loadGenericPassword(service: String, account: String, authenticationPolicy: KeychainAuthenticationPolicy) throws -> String?
    func deleteGenericPassword(service: String, account: String) throws
}

extension KeychainStore {
    func loadGenericPassword(service: String, account: String) throws -> String? {
        try loadGenericPassword(service: service, account: account, authenticationPolicy: .skip)
    }
}

enum KeychainAuthenticationPolicy: Equatable, Sendable {
    case skip
    case allow
}

/// Real SecItem-backed Keychain adapter.
final class RealKeychainStore: KeychainStore {
    func saveGenericPassword(data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }

        throw KeychainError.unexpectedStatus(status)
    }

    func loadGenericPassword(
        service: String,
        account: String,
        authenticationPolicy: KeychainAuthenticationPolicy
    ) throws -> String? {
        let context = LAContext()
        context.interactionNotAllowed = authenticationPolicy.interactionNotAllowed

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecUseAuthenticationContext as String] = context

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    func deleteGenericPassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

final class InMemoryMockKeychainStore: KeychainStore {
    private struct ItemKey: Hashable, Sendable {
        let service: String
        let account: String
    }
    private let items = OSAllocatedUnfairLock(initialState: [ItemKey: Data]())

    func saveGenericPassword(data: Data, service: String, account: String) throws {
        items.withLock { $0[ItemKey(service: service, account: account)] = data }
    }

    func loadGenericPassword(
        service: String,
        account: String,
        authenticationPolicy: KeychainAuthenticationPolicy
    ) throws -> String? {
        let data = items.withLock { $0[ItemKey(service: service, account: account)] }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    func deleteGenericPassword(service: String, account: String) throws {
        _ = items.withLock { $0.removeValue(forKey: ItemKey(service: service, account: account)) }
    }
}

/// Stable Keychain identifiers.
///
/// Treat service/account names as persisted data. Changing them without an
/// explicit migration can make existing saved keys appear missing.
enum KeychainConstants {
    static let service = HirevaProductIdentity.keychainService
    static let deepSeekAccount = "deepseek.default"
    static let defaultEmbeddingAccount = "openai.embedding.default"
    static let errSecInDarkWake: OSStatus = -25320
}

extension KeychainAuthenticationPolicy {
    var interactionNotAllowed: Bool {
        switch self {
        case .skip:
            return true
        case .allow:
            return false
        }
    }
}

/// High-level API-key store used by settings, provider tests, and diagnostics.
///
/// This type may return masked key display strings, but it must never log or
/// expose raw key values. Ad-hoc signing can legitimately cause macOS to ask
/// for access again after rebuilds because the code signature identity changes.
final class KeychainService: Sendable {
    let store: KeychainStore

    static func defaultStore(
        isTestProcess: Bool,
        verification: HirevaVerificationConfiguration?
    ) -> KeychainStore {
        // Verification retains product identifiers but must never read or
        // migrate a person's existing credentials, even in the real GUI.
        isTestProcess || verification != nil ? InMemoryMockKeychainStore() : RealKeychainStore()
    }

    struct DiagnosticSnapshot: Sendable {
        var migrationPerformed = false
        var legacyItemFound = false
        var legacyItemCount = 0
        var lastReadStatus = "Not Checked"
        var lastWriteStatus = "Not Checked"
    }
    // Sole diagnostic storage. No native operation or await holds this lock.
    private let diagnostics = OSAllocatedUnfairLock(initialState: DiagnosticSnapshot())
    var diagnosticSnapshot: DiagnosticSnapshot { diagnostics.withLock { $0 } }
    var migrationPerformed: Bool {
        get { diagnostics.withLock { $0.migrationPerformed } }
        set { diagnostics.withLock { $0.migrationPerformed = newValue } }
    }
    var legacyItemFound: Bool {
        get { diagnostics.withLock { $0.legacyItemFound } }
        set { diagnostics.withLock { $0.legacyItemFound = newValue } }
    }
    var legacyItemCount: Int {
        get { diagnostics.withLock { $0.legacyItemCount } }
        set { diagnostics.withLock { $0.legacyItemCount = newValue } }
    }
    var lastReadStatus: String {
        get { diagnostics.withLock { $0.lastReadStatus } }
        set { diagnostics.withLock { $0.lastReadStatus = newValue } }
    }
    var lastWriteStatus: String {
        get { diagnostics.withLock { $0.lastWriteStatus } }
        set { diagnostics.withLock { $0.lastWriteStatus = newValue } }
    }

    init(store: KeychainStore = RealKeychainStore()) {
        self.store = store
    }

    public static func maskKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "None" }
        if trimmed.hasPrefix("sk-") {
            let last4 = String(trimmed.suffix(4))
            return "sk-****\(last4)"
        } else {
            let last4 = String(trimmed.suffix(min(4, trimmed.count)))
            return "****\(last4)"
        }
    }

    static func keyLengthCategory(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        return trimmed.count < 20 ? "short" : "present"
    }

    func performMigrationIfNeeded(accounts additionalAccounts: Set<String> = []) {
        let accounts = additionalAccounts.union([
            KeychainConstants.deepSeekAccount,
            KeychainConstants.defaultEmbeddingAccount
        ])
        let legacyServices = [LegacyHirevaIdentifiers.keychainService] +
            LegacyHirevaIdentifiers.olderKeychainServices
        var discoveredItems = 0
        var migratedAccounts = 0
        var firstFailure: Error?

        for account in accounts.sorted() {
            let currentValue: String?
            do {
                currentValue = try store.loadGenericPassword(
                    service: KeychainConstants.service,
                    account: account
                )
            } catch {
                currentValue = nil
                firstFailure = firstFailure ?? error
            }

            var firstLegacyValue: String?
            for service in legacyServices {
                var candidateAccounts = [account]
                if account == KeychainConstants.deepSeekAccount {
                    candidateAccounts.append("DeepSeekAPIKey")
                }
                for legacyAccount in candidateAccounts {
                    do {
                        if let value = try store.loadGenericPassword(
                            service: service,
                            account: legacyAccount
                        ), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            discoveredItems += 1
                            firstLegacyValue = firstLegacyValue ?? value
                        }
                    } catch {
                        firstFailure = firstFailure ?? error
                    }
                }
            }

            guard currentValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  let legacyValue = firstLegacyValue else {
                continue
            }

            do {
                let trimmed = legacyValue.trimmingCharacters(in: .whitespacesAndNewlines)
                try store.saveGenericPassword(
                    data: Data(trimmed.utf8),
                    service: KeychainConstants.service,
                    account: account
                )
                let verified = try store.loadGenericPassword(
                    service: KeychainConstants.service,
                    account: account
                )
                guard verified == trimmed else {
                    throw KeychainError.invalidData
                }
                migratedAccounts += 1
            } catch {
                firstFailure = firstFailure ?? error
            }
        }

        let readStatus: String
        let writeStatus: String?
        if migratedAccounts > 0 {
            readStatus = "Success (legacy credentials migrated)"
            writeStatus = "Success (migrated \(migratedAccounts) account(s))"
        } else if let firstFailure {
            readStatus = KeychainService.keychainReadStatusMessage(for: firstFailure)
            writeStatus = "Migration unavailable: \(firstFailure.localizedDescription)"
        } else {
            readStatus = "Success"
            writeStatus = nil
        }
        diagnostics.withLock { [discoveredItems, migratedAccounts] state in
            state.legacyItemCount = discoveredItems
            state.legacyItemFound = discoveredItems > 0
            state.migrationPerformed = migratedAccounts > 0
            state.lastReadStatus = readStatus
            if let writeStatus { state.lastWriteStatus = writeStatus }
        }
        if migratedAccounts > 0 {
            print("[KeychainService] Legacy credentials copied to the Hireva service. Legacy items were retained.")
        }
    }

    func saveAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, account: KeychainConstants.deepSeekAccount)
    }

    func loadAPIKey() throws -> String? {
        try loadAPIKey(account: KeychainConstants.deepSeekAccount)
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(account: KeychainConstants.deepSeekAccount)
    }

    func saveAPIKey(_ apiKey: String, account: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        do {
            try store.saveGenericPassword(data: data, service: KeychainConstants.service, account: account)
            self.lastWriteStatus = "Success"
        } catch {
            self.lastWriteStatus = "Error: \(error.localizedDescription)"
            throw error
        }
    }

    func loadAPIKey(account: String) throws -> String? {
        do {
            let result = try loadAPIKey(account: account, authenticationPolicy: .skip)
            self.lastReadStatus = "Success"
            return result
        } catch {
            self.lastReadStatus = KeychainService.keychainReadStatusMessage(for: error)
            throw error
        }
    }

    func loadAPIKeyForProviderRequest(account: String) throws -> String? {
        do {
            let result = try loadAPIKey(account: account, authenticationPolicy: .allow)
            self.lastReadStatus = "Success"
            return result
        } catch {
            self.lastReadStatus = KeychainService.keychainReadStatusMessage(for: error)
            throw error
        }
    }

    private func loadAPIKey(
        account: String,
        authenticationPolicy: KeychainAuthenticationPolicy
    ) throws -> String? {
        try store.loadGenericPassword(
            service: KeychainConstants.service,
            account: account,
            authenticationPolicy: authenticationPolicy
        )
    }

    func deleteAPIKey(account: String) throws {
        do {
            try store.deleteGenericPassword(service: KeychainConstants.service, account: account)
            self.lastWriteStatus = "Deleted"
        } catch {
            self.lastWriteStatus = "Error: \(error.localizedDescription)"
            throw error
        }
    }

    func hasAPIKey(account: String) -> Bool {
        apiKeyAccessState(account: account).hasReadableKey
    }

    func hasAPIKey() -> Bool {
        hasAPIKey(account: KeychainConstants.deepSeekAccount)
    }

    func apiKeyAccessState(account: String) -> KeychainAPIKeyAccessState {
        do {
            guard let key = try loadAPIKey(account: account) else {
                lastReadStatus = "Missing"
                return .missing
            }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                lastReadStatus = "Missing"
                return .missing
            }
            lastReadStatus = "Success"
            return .available(
                maskedKey: KeychainService.maskKey(trimmed),
                keyLengthCategory: KeychainService.keyLengthCategory(trimmed)
            )
        } catch {
            let message = KeychainService.keychainReadStatusMessage(for: error)
            lastReadStatus = message
            if KeychainService.isAuthorizationOrTrustFailure(error) {
                return .authorizationRequired(message)
            }
            return .unreadable(message)
        }
    }

    static func isAuthorizationOrTrustFailure(_ error: Error) -> Bool {
        if let keychainError = error as? KeychainError {
            return keychainError.isAuthorizationOrTrustFailure
        }
        return false
    }

    static func keychainReadStatusMessage(for error: Error) -> String {
        guard let keychainError = error as? KeychainError,
              let status = keychainError.status else {
            return "Error: \(error.localizedDescription)"
        }
        if status == KeychainConstants.errSecInDarkWake {
            return "Keychain access needs an active foreground user session; macOS reported that no Keychain UI is possible."
        }
        if keychainError.isAuthorizationOrTrustFailure {
            return "Keychain access needs re-authorization because the app signing identity changed or macOS requires user approval."
        }
        return "Error: \(error.localizedDescription)"
    }
}

protocol APIKeyStore: AnyObject, Sendable {
    func saveAPIKey(_ apiKey: String, account: String) throws
    func loadAPIKey(account: String) throws -> String?
    func deleteAPIKey(account: String) throws
}

extension KeychainService: APIKeyStore {}

protocol ProviderRequestAPIKeyStore: APIKeyStore {
    func loadAPIKeyForProviderRequest(account: String) throws -> String?
}

extension KeychainService: ProviderRequestAPIKeyStore {}
