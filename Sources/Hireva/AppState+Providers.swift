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

    func saveSettings(_ newSettings: AppSettings) {
        let actionID = ActionID.saveSettings
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving settings", message: "Applying the latest preferences...")
        var next = newSettings
        next.compactMode = next.floatingAssistantDisplayMode == .compact
        if next.highContrastFloatingPanel {
            next.floatingWindowOpacity = max(next.floatingWindowOpacity, 0.65)
        }
        do {
            settings = next
            try settingsRepository.saveSettings(next)
            refreshAll()
            completeAction(actionID, title: "Settings saved", message: "Your settings were applied.")
        } catch {
            let message = "Could not save settings: \(error.localizedDescription)"
            failAction(actionID, title: "Save failed", message: message)
            showError(message)
        }
    }

    // MARK: - API Key Storage

    /// Saves the default DeepSeek API key through KeychainService.
    ///
    /// Never log or expose the raw key. UI copy should describe this as
    /// "securely saved" rather than mentioning Keychain internals.
    func saveAPIKey(_ apiKey: String) {
        let actionID = ActionID.providerSaveKey
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving securely", message: "Saving the provider key without displaying it.")
        do {
            try keychainService.saveAPIKey(apiKey)
            self.connectionResult = "API key securely saved."
            self.refreshAll()
            completeAction(actionID, title: "Saved securely", message: "Provider key saved. Raw key is hidden.")
        } catch {
            let message = "Could not save API key: \(error.localizedDescription)"
            failAction(actionID, title: "Key save failed", message: message)
            showError(message)
        }
    }

    /// Saves a provider-specific API key under the provider's stable keychain
    /// account name.
    ///
    /// Account names are part of the migration contract and should not change
    /// without an explicit migration.
    func saveAPIKey(_ apiKey: String, for provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerSaveKey, provider.id)
        guard !isActionLoading(actionID) else { return }
        guard let account = provider.apiKeyAccount else {
            connectionResult = "\(provider.name) does not require an API key."
            infoAction(actionID, title: "No key needed", message: "\(provider.name) does not require an API key.")
            return
        }
        beginAction(actionID, title: "Saving securely", message: "Saving \(provider.name) key without displaying it.")
        do {
            try keychainService.saveAPIKey(apiKey, account: account)
            self.providerConnectionResults[provider.id] = "API key securely saved."
            self.refreshAll()
            completeAction(actionID, title: "Saved securely", message: "\(provider.name) key saved. Raw key is hidden.")
        } catch {
            let message = "Could not save API key: \(error.localizedDescription)"
            failAction(actionID, title: "Key save failed", message: message)
            showError(message)
        }
    }

    func saveEmbeddingAPIKey(_ apiKey: String, account: String) {
        let actionID = ActionID.saveEmbeddingKey
        guard !isActionLoading(actionID) else { return }
        let cleanedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAccount.isEmpty else {
            let message = "Embedding API key account is missing."
            failAction(actionID, title: "Key save failed", message: message)
            showError(message)
            return
        }
        beginAction(actionID, title: "Saving securely", message: "Saving the embedding provider key without displaying it.")
        do {
            try keychainService.saveAPIKey(apiKey, account: cleanedAccount)
            lastEmbeddingError = nil
            lastEmbeddingTestStatus = "Embedding API key securely saved."
            refreshAll()
            completeAction(actionID, title: "Saved securely", message: "Embedding key saved. Raw key is hidden.")
        } catch {
            let message = "Could not save embedding API key: \(error.localizedDescription)"
            failAction(actionID, title: "Key save failed", message: message)
            showError(message)
        }
    }

    func embeddingKeyStatus(account: String) -> String {
        let cleanedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAccount.isEmpty else { return "No account configured" }
        switch keychainService.apiKeyAccessState(account: cleanedAccount) {
        case .available(let maskedKey, _):
            return maskedKey
        case .missing:
            return "Missing"
        case .authorizationRequired:
            return "Needs re-authorization"
        case .unreadable:
            return "Configured, unreadable"
        }
    }

    func testEmbeddingProvider() {
        let actionID = ActionID.providerTest
        guard !isActionLoading(actionID) else { return }
        guard settings.embeddingProviderKind != .disabled else {
            lastEmbeddingError = nil
            lastEmbeddingTestStatus = "Keyword RAG ready; vector embeddings not configured."
            infoAction(actionID, title: "Keyword search ready", message: "Cloud embeddings are not configured.")
            return
        }
        guard let provider = resolveEmbeddingProvider() else {
            lastEmbeddingTestStatus = "Keyword RAG ready; vector embeddings not configured."
            warnAction(actionID, title: "Embedding key missing", message: "Keyword search remains ready. Add a cloud embedding key to test embeddings.")
            return
        }

        beginAction(actionID, title: "Testing embeddings", message: "Sending a small provider test request...")
        isTestingConnection = true
        lastEmbeddingError = nil
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let vector = try await provider.embed(text: "Embedding provider connection test.")
                guard !Task.isCancelled else { return }
                let latency = Int(Date().timeIntervalSince(started) * 1000)
                self.lastEmbeddingTestStatus = "Connected. Dimension \(vector.count), latency \(latency) ms."
                self.lastEmbeddingError = nil
                self.completeAction(actionID, title: "Embedding provider connected", message: "Dimension \(vector.count), latency \(latency) ms.")
            } catch {
                guard !Task.isCancelled else { return }
                self.lastEmbeddingTestStatus = "Embedding provider test failed."
                self.lastEmbeddingError = self.userFacing(error)
                self.failAction(actionID, title: "Embedding test failed", message: self.userFacing(error))
            }
            self.isTestingConnection = false
        }
    }

    func deleteAPIKey() {
        do {
            try keychainService.deleteAPIKey()
            self.connectionResult = "API key removed."
            self.refreshAll()
        } catch {
            showError("Could not remove API key: \(error.localizedDescription)")
        }
    }

    func saveProviderConfiguration(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerSave, provider.id)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving provider", message: "Saving \(provider.name) configuration...")
        do {
            try settingsRepository.saveProviderConfiguration(provider)
            refreshAll()
            completeAction(actionID, title: "Provider saved", message: "\(provider.name) configuration saved.")
        } catch {
            let message = "Could not save provider: \(error.localizedDescription)"
            failAction(actionID, title: "Provider save failed", message: message)
            showError(message)
        }
    }

    func deleteProviderConfiguration(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerDelete, provider.id)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Deleting provider", message: "Removing \(provider.name)...")
        do {
            try settingsRepository.deleteProviderConfiguration(id: provider.id)
            refreshAll()
            completeAction(actionID, title: "Provider deleted", message: "\(provider.name) was removed.")
        } catch {
            let message = "Could not delete provider: \(error.localizedDescription)"
            failAction(actionID, title: "Provider delete failed", message: message)
            showError(message)
        }
    }

    func setActiveRealtimeProvider(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.providerSwitch
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Switching provider", message: "Setting \(provider.name) for realtime answers...")
        do {
            try settingsRepository.setActiveRealtimeProvider(id: provider.id)
            refreshAll()
            completeAction(actionID, title: "Provider switched", message: "\(provider.name) is now used for realtime answers.")
        } catch {
            let message = "Could not set realtime provider: \(error.localizedDescription)"
            failAction(actionID, title: "Provider switch failed", message: message)
            showError(message)
        }
    }

    func updateActiveRealtimeProvider(provider: LLMProviderConfiguration, model: String?) {
        let actionID = ActionID.providerSwitch
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Switching provider", message: "Checking \(provider.name) configuration...")
        activeAITask?.cancel()
        errorMessage = nil
        lastProviderSwitchError = nil
        lastProviderSwitchTimestamp = Date()
        
        var updated = provider
        if let model = model {
            updated.model = model
        }
        
        do {
            if updated.kind == .ollamaLocal {
                let msg = "Local providers are disabled. Please choose DeepSeek or another API provider."
                self.lastProviderSwitchError = msg
                self.errorMessage = "Could not switch provider: \(msg)"
                failAction(actionID, title: "Provider switch failed", message: msg)
                return
            } else if updated.kind == .deepSeek || updated.kind == .openAICompatible {
                guard let account = updated.apiKeyAccount else {
                    let msg = "Missing API key account for \(updated.name)."
                    self.lastProviderSwitchError = msg
                    self.errorMessage = "Could not switch provider: \(msg)"
                    failAction(actionID, title: "Provider switch failed", message: msg)
                    return
                }
                let keyStatus = keychainService.apiKeyAccessState(account: account)
                guard keyStatus.hasReadableKey else {
                    let msg: String
                    if case .authorizationRequired(let message) = keyStatus {
                        msg = message
                    } else {
                        msg = "Missing API Key for \(updated.name)."
                    }
                    self.lastProviderSwitchError = msg
                    self.errorMessage = "Could not switch provider: \(msg)"
                    failAction(actionID, title: "Provider switch failed", message: msg)
                    return
                }
                
                try settingsRepository.saveProviderConfiguration(updated)
                try settingsRepository.setActiveRealtimeProvider(id: updated.id)
                refreshAll()
            } else {
                try settingsRepository.saveProviderConfiguration(updated)
                try settingsRepository.setActiveRealtimeProvider(id: updated.id)
                refreshAll()
            }
            completeAction(actionID, title: "Provider switched", message: "\(updated.name) \(updated.model) is active.")
        } catch {
            let msg = error.localizedDescription
            self.lastProviderSwitchError = msg
            self.errorMessage = "Could not switch provider: \(msg)"
            failAction(actionID, title: "Provider switch failed", message: msg)
        }
    }

    func setActiveRecapProvider(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerSave, provider.id)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving recap provider", message: "Setting \(provider.name) for full answers and recaps...")
        do {
            try settingsRepository.setActiveRecapProvider(id: provider.id)
            refreshAll()
            completeAction(actionID, title: "Recap provider saved", message: "\(provider.name) is now used for recaps.")
        } catch {
            let message = "Could not set recap provider: \(error.localizedDescription)"
            failAction(actionID, title: "Provider save failed", message: message)
            showError(message)
        }
    }

    func testProviderConnection(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerTest, provider.id)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Testing \(provider.name)", message: "Testing provider connection...")
        isTestingConnection = true
        providerConnectionResults[provider.id] = nil
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await llmRouter.testProvider(configuration: provider)
                guard !Task.isCancelled else { return }
                providerConnectionResults[provider.id] = result.message
                completeAction(actionID, title: "\(provider.name) connected", message: result.message)
                updateDiagnostics {
                    $0.lastAPILatencyMS = result.latencyMS
                    $0.lastProviderName = provider.name
                    $0.lastProviderModel = provider.model
                }
            } catch {
                guard !Task.isCancelled else { return }
                let message = self.userFacing(error)
                providerConnectionResults[provider.id] = message
                self.failAction(actionID, title: "\(provider.name) test failed", message: message)
                updateDiagnostics { $0.lastError = message }
            }
            isTestingConnection = false
        }
    }

    func retryLastFailedAITask() {
        guard let taskType = lastFailedTaskType, let session = currentSession else {
            return
        }
        
        self.errorMessage = nil
        
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            switch taskType {
            case .questionDetection:
                let transcript = self.lastFailedTranscriptContext
                await self.runAutomaticDetection(
                    session: session,
                    detectionTranscript: transcript,
                    suggestionTranscript: transcript,
                    triggeringSegmentID: nil
                )
            case .suggestionGeneration:
                guard let question = self.lastFailedQuestion else { return }
                let transcript = self.lastFailedTranscriptContext
                do {
                    self.lastFailedTaskType = nil
                    try await self.generateSuggestion(for: question, session: session, transcript: transcript, autoGenerated: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    let message = self.userFacing(error)
                    self.liveState = .error(message)
                    self.showError(message)
                }
            }
        }
    }

    func switchToDeepSeekFallback() {
        guard let deepSeekProvider = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
            showError("DeepSeek provider not configured. Please configure it in Provider Settings.")
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Confirm Cloud Fallback"
        alert.informativeText = "Switching to DeepSeek will send your recent transcript and CV/JD context snippets to DeepSeek cloud APIs. Do you want to proceed?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Proceed")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            setActiveRealtimeProvider(deepSeekProvider)
            retryLastFailedAITask()
        }
    }

    func testDeepSeekConnection() {
        let actionID = ActionID.testDeepSeek
        guard !isActionLoading(actionID) else { return }
        guard let provider = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
            connectionResult = "DeepSeek provider is not configured."
            failAction(actionID, title: "DeepSeek not configured", message: "Add DeepSeek in Settings before testing.")
            return
        }
        guard let account = provider.apiKeyAccount else {
            connectionResult = "DeepSeek key account is not configured."
            failAction(actionID, title: "DeepSeek key missing", message: "Save a DeepSeek API key before testing.")
            return
        }
        let keyStatus = keychainService.apiKeyAccessState(account: account)
        guard keyStatus.hasReadableKey else {
            if case .authorizationRequired(let message) = keyStatus {
                connectionResult = message
                failAction(actionID, title: "Keychain needs re-authorization", message: message)
            } else {
                connectionResult = "Add a DeepSeek API key before testing the connection."
                failAction(actionID, title: "DeepSeek key missing", message: "Save a DeepSeek API key before testing.")
            }
            return
        }
        beginAction(actionID, title: "Testing DeepSeek", message: "Checking the saved key and model endpoint...")
        isTestingConnection = true
        connectionResult = nil
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await llmRouter.testProvider(configuration: provider)
                guard !Task.isCancelled else { return }
                connectionResult = response.message
                completeAction(actionID, title: "DeepSeek connected", message: response.message)
                updateDiagnostics {
                    $0.lastAPILatencyMS = response.latencyMS
                    $0.lastProviderName = provider.name
                    $0.lastProviderModel = provider.model
                }
            } catch {
                guard !Task.isCancelled else { return }
                connectionResult = self.userFacing(error)
                failAction(actionID, title: "DeepSeek test failed", message: self.userFacing(error))
                updateDiagnostics { $0.lastError = self.userFacing(error) }
            }
            isTestingConnection = false
        }
    }
}
