// Handles provider/settings persistence and connection tests.
// This extension may save preferences and API keys through KeychainService, but
// it must not own generation flow, prompt construction, audio capture, or raw
// API-key display/logging.

import Foundation
import Combine
import SwiftUI
import AppKit

extension AppState {
    // MARK: - Settings Persistence

    func saveSettings(_ newSettings: AppSettings) { settingsState.saveSettings(newSettings) }

    // MARK: - API Key Storage

    /// Saves the default DeepSeek API key through KeychainService.
    ///
    /// Never log or expose the raw key. UI copy should describe this as
    /// "securely saved" rather than mentioning Keychain internals.
    func saveAPIKey(_ apiKey: String) { settingsState.saveAPIKey(apiKey) }

    /// Saves a provider-specific API key under the provider's stable keychain
    /// account name.
    ///
    /// Account names are part of the migration contract and should not change
    /// without an explicit migration.
    func saveAPIKey(_ apiKey: String, for provider: LLMProviderConfiguration) { settingsState.saveAPIKey(apiKey, for: provider) }

    func saveEmbeddingAPIKey(_ apiKey: String, account: String) { settingsState.saveEmbeddingAPIKey(apiKey, account: account) }

    func embeddingKeyStatus(account: String) -> String { settingsState.embeddingKeyStatus(account: account) }

    func testEmbeddingProvider() { settingsState.testEmbeddingProvider(provider: resolveEmbeddingProvider()) }

    func deleteAPIKey() { settingsState.deleteAPIKey() }

    func saveProviderConfiguration(_ provider: LLMProviderConfiguration) { settingsState.saveProviderConfiguration(provider) }

    func deleteProviderConfiguration(_ provider: LLMProviderConfiguration) { settingsState.deleteProviderConfiguration(provider) }

    func setActiveRealtimeProvider(_ provider: LLMProviderConfiguration) { settingsState.setActiveRealtimeProvider(provider) }

    func updateActiveRealtimeProvider(provider: LLMProviderConfiguration, model: String?) { settingsState.updateActiveRealtimeProvider(provider: provider, model: model) }

    func setActiveRecapProvider(_ provider: LLMProviderConfiguration) { settingsState.setActiveRecapProvider(provider) }

    func testProviderConnection(_ provider: LLMProviderConfiguration) { settingsState.testProviderConnection(provider) }

    func testDeepSeekConnection() { settingsState.testDeepSeekConnection() }
}
