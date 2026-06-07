import Foundation
import Security

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
}

protocol KeychainStore: AnyObject {
    func saveGenericPassword(data: Data, service: String, account: String) throws
    func loadGenericPassword(service: String, account: String) throws -> String?
    func deleteGenericPassword(service: String, account: String) throws
}

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

    func loadGenericPassword(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

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
    private var store: [String: Data] = [:]

    private func makeKey(service: String, account: String) -> String {
        return "\(service):\(account)"
    }

    func saveGenericPassword(data: Data, service: String, account: String) throws {
        let key = makeKey(service: service, account: account)
        store[key] = data
    }

    func loadGenericPassword(service: String, account: String) throws -> String? {
        let key = makeKey(service: service, account: account)
        guard let data = store[key] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteGenericPassword(service: String, account: String) throws {
        let key = makeKey(service: service, account: account)
        store.removeValue(forKey: key)
    }
}

enum KeychainConstants {
    static let service = "com.langcheng.InterviewCopilotMac.LLMProviderKeys"
    static let deepSeekAccount = "deepseek.default"
    static let defaultEmbeddingAccount = "openai.embedding.default"
}

final class KeychainService {
    let store: KeychainStore

    // Diagnostic properties
    var migrationPerformed: Bool = false
    var legacyItemFound: Bool = false
    var legacyItemCount: Int = 0
    var lastReadStatus: String = "Not Checked"
    var lastWriteStatus: String = "Not Checked"

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

    func performMigrationIfNeeded() {
        // Always search legacy combinations to keep diagnostics accurate
        let legacyServices = [
            "InterviewCopilotMac",
            "InterviewCopilotMac.LLMProviderKeys",
            "com.interviewcopilot.mac",
            "com.langcheng.InterviewCopilotMac"
        ]
        let legacyAccounts = [
            "deepseek.default",
            "DeepSeekAPIKey"
        ]

        var foundKey: String? = nil
        var foundService: String = ""
        var foundAccount: String = ""
        var count = 0

        for service in legacyServices {
            for account in legacyAccounts {
                if service == KeychainConstants.service && account == KeychainConstants.deepSeekAccount {
                    continue
                }
                do {
                    if let key = try store.loadGenericPassword(service: service, account: account),
                       !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        count += 1
                        if foundKey == nil {
                            foundKey = key
                            foundService = service
                            foundAccount = account
                        }
                    }
                } catch {
                    // Ignore load errors for specific legacy items
                }
            }
        }

        self.legacyItemCount = count
        self.legacyItemFound = count > 0

        // 1. Try to load from the new stable keychain
        do {
            if let existingKey = try store.loadGenericPassword(
                service: KeychainConstants.service,
                account: KeychainConstants.deepSeekAccount
            ), !existingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.lastReadStatus = "Success (Existing Key Found)"
                self.migrationPerformed = false
                return
            }
            self.lastReadStatus = "Key Missing (Ready for Migration)"
        } catch {
            self.lastReadStatus = "Error: \(error.localizedDescription)"
        }

        if let keyToMigrate = foundKey {
            do {
                let trimmed = keyToMigrate.trimmingCharacters(in: .whitespacesAndNewlines)
                let data = Data(trimmed.utf8)
                try store.saveGenericPassword(
                    data: data,
                    service: KeychainConstants.service,
                    account: KeychainConstants.deepSeekAccount
                )
                self.migrationPerformed = true
                self.lastWriteStatus = "Success"
                
                let masked = KeychainService.maskKey(trimmed)
                print("[KeychainService] Dynamic migration complete: Copied legacy key \(masked) from service '\(foundService)', account '\(foundAccount)' to new stable Keychain. Legacy key preserved.")
            } catch {
                self.migrationPerformed = false
                self.lastWriteStatus = "Error: \(error.localizedDescription)"
                print("[KeychainService] Dynamic migration failed to save: \(error.localizedDescription)")
            }
        } else {
            self.migrationPerformed = false
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
            let result = try store.loadGenericPassword(service: KeychainConstants.service, account: account)
            self.lastReadStatus = "Success"
            return result
        } catch {
            self.lastReadStatus = "Error: \(error.localizedDescription)"
            throw error
        }
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
        ((try? loadAPIKey(account: account)) ?? nil)?.isEmpty == false
    }

    func hasAPIKey() -> Bool {
        ((try? loadAPIKey()) ?? nil)?.isEmpty == false
    }
}

protocol APIKeyStore: AnyObject {
    func saveAPIKey(_ apiKey: String, account: String) throws
    func loadAPIKey(account: String) throws -> String?
    func deleteAPIKey(account: String) throws
}

extension KeychainService: APIKeyStore {}
