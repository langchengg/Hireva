import Foundation
import AppKit
import SwiftUI
import Combine
import Testing
@testable import Hireva

@MainActor
struct SettingsStateOwnershipTests {
    @Test
    func twoIndependentSubscribersObserveTheSameAppliedSettingsOwner() async throws {
        try await StandaloneSettingsFixture.run { fixture in
            var firstUpdates = 0
            var secondUpdates = 0
            let first = fixture.owner.objectWillChange.sink { firstUpdates += 1 }
            let second = fixture.owner.objectWillChange.sink { secondUpdates += 1 }
            defer { first.cancel(); second.cancel() }
            var draft = fixture.owner.settings
            draft.highContrastFloatingPanel = true
            draft.floatingWindowOpacity = 0.4
            draft.saveTranscriptsLocally = false
            fixture.owner.saveSettings(draft)
            #expect(firstUpdates > 0)
            #expect(secondUpdates > 0)
            let storedSettings = try fixture.repository.loadSettings()
            #expect(fixture.owner.settings == storedSettings)
            #expect(fixture.owner.settings.floatingWindowOpacity == 0.65)
            #expect(!fixture.owner.settings.saveTranscriptsLocally)
            #expect(fixture.settingsChanges.contains { !$0.saveTranscriptsLocally })
        }
    }

    @Test
    func repositoryProviderProjectionsAndStableKeyIdentityNeedNoAppState() async throws {
        try await StandaloneSettingsFixture.run { fixture in
            let provider = LLMProviderConfiguration.deepSeekDefault()
            fixture.owner.saveProviderConfiguration(provider)
            fixture.owner.setActiveRealtimeProvider(provider)
            fixture.owner.setActiveRecapProvider(provider)
            fixture.owner.saveAPIKey("sk-synthetic-owner-123456", for: provider)
            let storedProviders = try fixture.repository.providerConfigurations()
            let storedRealtime = try fixture.repository.activeRealtimeProvider()
            let storedRecap = try fixture.repository.activeRecapProvider()
            #expect(fixture.owner.providerConfigurations == storedProviders)
            #expect(fixture.owner.activeRealtimeProvider == storedRealtime)
            #expect(fixture.owner.activeRecapProvider == storedRecap)
            #expect(fixture.owner.keychainServiceName == KeychainConstants.service)
            #expect(fixture.owner.keychainDeepSeekAccount == KeychainConstants.deepSeekAccount)
            #expect(fixture.owner.keychainDeepSeekKeyExists)
            #expect(fixture.owner.keychainMaskedKey == "sk-****3456")
            #expect(!fixture.owner.keychainMaskedKey.contains("synthetic-owner"))
            #expect(fixture.owner.hasAPIKey)
        }
    }

    @Test
    func selectedProviderPreferencesUseOnlyTheirInjectedDefaults() async throws {
        try await StandaloneSettingsFixture.run { first in
            try await StandaloneSettingsFixture.run { second in
                first.owner.setSelectedASRProvider(.localParakeet)
                first.owner.setSelectedQwenModelName("synthetic-local-model")
                first.owner.setSelectedAnswerProviderMode(.deepSeekPrimary)
                #expect(first.owner.selectedASRProviderID == .localParakeet)
                #expect(first.owner.selectedQwenModelName == "synthetic-local-model")
                #expect(first.owner.selectedAnswerProviderMode == .deepSeekPrimary)
                #expect(first.defaults.string(forKey: HirevaPreferenceKeys.selectedQwenModel) == "synthetic-local-model")
                #expect(second.defaults.string(forKey: HirevaPreferenceKeys.selectedQwenModel) == nil)
                #expect(second.owner.selectedASRProviderID == .appleSpeech)
                #expect(second.owner.selectedQwenModelName == LocalModelDescriptor.defaultQwenLocalLLM.id)
            }
        }
    }

    @Test
    func anUnsavedProviderDraftCanTestItsFrozenConfigurationWithoutCreatingARow() async throws {
        let client = RecordingSettingsProviderClient()
        try await StandaloneSettingsFixture.run(client: client) { fixture in
            var draft = LLMProviderConfiguration.openAICompatibleDefault()
            draft.id = UUID()
            draft.name = "Synthetic unsaved provider draft"
            draft.baseURL = "https://settings-draft.test/v1"
            draft.model = "synthetic-draft-model"
            #expect(try fixture.repository.providerConfiguration(id: draft.id) == nil)
            fixture.owner.testProviderConnection(draft)
            let task = try #require(fixture.owner.providerTestTask)
            await task.value
            #expect(await client.configuration() == draft)
            #expect(fixture.owner.providerConnectionResults[draft.id] == "synthetic draft connection success")
            #expect(!fixture.owner.isTestingConnection)
            #expect(try fixture.repository.providerConfiguration(id: draft.id) == nil)
        }
    }

    @Test
    func dialoguePreferencesPublishDirectlyAndReportOnlySelectedModeChanges() async throws {
        try await StandaloneSettingsFixture.run { fixture in
            var updates = 0
            let subscription = fixture.owner.objectWillChange.sink { updates += 1 }
            defer { subscription.cancel() }
            let previous = fixture.owner.interviewSessionMode
            fixture.owner.interviewSessionMode = .presentation
            fixture.owner.answerPanelQuestionsEnabled = false
            fixture.owner.candidatePresentationMode = .normal
            fixture.owner.candidateAsksPanelMode = .normal
            #expect(updates >= 4)
            #expect(fixture.sessionModeChanges.last?.0 == previous)
            #expect(fixture.sessionModeChanges.last?.1 == .presentation)
            #expect(fixture.defaults.string(forKey: DialogueSettingsStore.sessionModeKey) == InterviewSessionMode.presentation.rawValue)
            #expect(!fixture.defaults.bool(forKey: DialogueSettingsStore.answerPanelQuestionsKey))
            #expect(!fixture.defaults.bool(forKey: DialogueSettingsStore.suppressPresentationKey))
            #expect(!fixture.defaults.bool(forKey: DialogueSettingsStore.suppressCandidateQuestionsKey))
        }
    }
}

@MainActor
private final class StandaloneSettingsFixture {
    let database: AppDatabase
    let repository: SettingsRepository
    let defaults: UserDefaults
    let defaultsSuite: String
    private(set) var settingsChanges: [AppSettings] = []
    private(set) var sessionModeChanges: [(InterviewSessionMode, InterviewSessionMode)] = []
    private var feedbacks: [ActionFeedback] = []
    private var loading: [String: Bool] = [:]
    private(set) var owner: SettingsState!

    init(client: (any LLMClientProtocol)? = nil) throws {
        database = try AppDatabase(inMemory: true)
        repository = SettingsRepository(database: database)
        defaultsSuite = "com.langcheng.Hireva.tests.settings-owner.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        let keychain = KeychainService(store: InMemoryMockKeychainStore())
        let clients: [LLMProviderKind: any LLMClientProtocol]
        if let client { clients = [client.providerKind: client] } else { clients = [:] }
        let router = LLMRouter(settingsRepository: repository, clients: clients)
        owner = SettingsState(repository: repository, keychain: keychain, router: router, defaults: defaults,
            isActionLoading: { [weak self] in self?.loading[$0] == true },
            feedback: { [weak self] value in
                self?.feedbacks.append(value)
                self?.loading[value.actionID] = value.kind == .loading
            },
            clearFeedback: { [weak self] id in self?.loading[id] = false },
            onChange: { [weak self] change in
                switch change {
                case .settingsChanged(_, let current): self?.settingsChanges.append(current)
                case .sessionModeChanged(let previous, let current): self?.sessionModeChanges.append((previous, current))
                default: break
                }
            })
        try owner.reload()
    }

    static func run(client: (any LLMClientProtocol)? = nil,
        _ body: (StandaloneSettingsFixture) async throws -> Void) async throws {
        let fixture = try StandaloneSettingsFixture(client: client)
        do {
            try await body(fixture)
            await fixture.owner.shutdown()
            fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite)
            try fixture.database.close()
        } catch {
            await fixture.owner.shutdown()
            fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite)
            try fixture.database.close()
            throw error
        }
    }
}

private actor RecordingSettingsProviderClient: LLMClientProtocol {
    nonisolated let providerKind: LLMProviderKind = .openAICompatible
    private var requested: LLMProviderConfiguration?
    func configuration() -> LLMProviderConfiguration? { requested }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        requested = configuration
        return LLMConnectionTestResult(success: true, message: "synthetic draft connection success", latencyMS: 1, models: [])
    }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Settings owner tests do not request answers")
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}


extension SettingsStateOwnershipTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_SETTINGS_MOUNTED_UI"] == "1"),
          .timeLimit(.minutes(1)))
    func mountedSettingsUsesAppliedDraftAcrossFirstMountAndReopen() async throws {
        MainActor.preconditionIsolated()
        try #require(!NSScreen.screens.isEmpty, "This opt-in needs a real graphical session.")
        _ = NSApplication.shared
        // This singleton is metadata only. No engine, recorder or permission API
        // is started. This exact single-filter host owns its lifetime here.
        let devices = AudioDeviceManager.shared
        do {
            try await StandaloneSettingsFixture.run { fixture in
                var applied = fixture.owner.settings
                applied.audioCaptureMode = .systemAudioOnly
                applied.diagnosticTraceMode = .fullText
                applied.saveTranscriptsLocally = true
                fixture.owner.saveSettings(applied)
                let embeddings = DocumentEmbeddingState(
                    repository: DocumentRepository(database: fixture.database),
                    configuration: { fixture.owner.settings })
                let makeView = {
                    SettingsView(settingsState: fixture.owner, relevantContextStatus: "Synthetic context",
                        embeddingState: embeddings, feedbacks: [], loadingStates: [:],
                        requestFeedback: { _ in }, addProvider: { _ in }, rebuildCleanRAGIndex: {},
                        clearTrace: {}, deleteAllLocalData: { _ in }, showError: { _ in })
                }
                do {
                    for mount in 0..<2 {
                        let host = MountedSettingsAXWindow(root: makeView())
                        do {
                            // This is a real mounted native AX value check, not
                            // a mirror of State or an unmounted View property.
                            try await host.requireControls(trace: "Full text (sensitive)")
                            if mount == 0 {
                                var updated = fixture.owner.settings
                                updated.diagnosticTraceMode = .metadataOnly
                                fixture.owner.saveSettings(updated)
                                try await host.requireControls(trace: "Metadata only")
                                updated.diagnosticTraceMode = .fullText
                                fixture.owner.saveSettings(updated)
                                try await host.requireControls(trace: "Full text (sensitive)")
                            }
                            let stored = try fixture.repository.loadSettings()
                            #expect(stored.audioCaptureMode == .systemAudioOnly)
                            #expect(stored.diagnosticTraceMode == .fullText)
                            #expect(stored.saveTranscriptsLocally)
                            host.close()
                        } catch { host.close(); throw error }
                    }
                    await embeddings.shutdown()
                } catch { await embeddings.shutdown(); throw error }
            }
            let stopped = await devices.shutdown()
            #expect(stopped)
        } catch {
            _ = await devices.shutdown()
            throw error
        }
    }
}

@MainActor
private final class MountedSettingsAXWindow {
    private let window: NSWindow
    private var host: NSHostingView<SettingsView>?
    init(root: SettingsView) {
        let host = NSHostingView(rootView: root)
        self.host = host
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 780, height: 1000),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Synthetic Settings mounted test"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
    }
    func close() {
        window.orderOut(nil)
        window.contentView = nil
        host = nil
        window.close()
    }
    func requireControls(trace expectedTrace: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        repeat {
            try Task.checkCancellation()
            host?.layoutSubtreeIfNeeded()
            let elements = try ownElements()
            let system = elements.filter { $0.accessibilityRole() == .radioButton && named($0, "System") }
            let combined = elements.filter { $0.accessibilityRole() == .radioButton && named($0, "Mic + System") }
            let traceValues = Set(DiagnosticTraceMode.allCases.map(\.displayName))
            let trace = elements.filter {
                $0.accessibilityRole() == .popUpButton &&
                    ($0.accessibilityValue() as? String).map { traceValues.contains($0) } == true
            }
            if system.count == 1, combined.count == 1, trace.count == 1,
               let on = system[0].accessibilityValue() as? NSNumber,
               let off = combined[0].accessibilityValue() as? NSNumber,
               let value = trace[0].accessibilityValue() as? String,
               on.intValue == 1, off.intValue == 0, value == expectedTrace {
                return
            }
            // Yield the MainActor for actual layout/appearance/observation.
            // Fixed bounded readiness, not a larger existing business timeout.
            try await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
        let observed = try ownElements().filter {
            $0.accessibilityRole() == .radioButton || $0.accessibilityRole() == .popUpButton
        }.map { "role=\(String(describing: $0.accessibilityRole())) label=\($0.accessibilityLabel() ?? "") title=\($0.accessibilityTitle() ?? "") value=\(String(describing: $0.accessibilityValue()))" }
        throw MountedSettingsAXFailure.controlsDidNotMatch(observed)
    }
    private func named(_ element: any NSAccessibilityProtocol, _ value: String) -> Bool {
        element.accessibilityLabel() == value || element.accessibilityTitle() == value
    }
    private func ownElements() throws -> [any NSAccessibilityProtocol] {
        var pending: [Any] = [window]
        var seen = Set<ObjectIdentifier>()
        var result: [any NSAccessibilityProtocol] = []
        while let object = pending.popLast() {
            let identity = ObjectIdentifier(object as AnyObject)
            guard seen.insert(identity).inserted else { continue }
            guard seen.count <= 2048 else { throw MountedSettingsAXFailure.treeLimit }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            guard let element = object as? any NSAccessibilityProtocol else { continue }
            result.append(element)
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
        }
        return result
    }
}

private enum MountedSettingsAXFailure: Error {
    case controlsDidNotMatch([String])
    case treeLimit
}
