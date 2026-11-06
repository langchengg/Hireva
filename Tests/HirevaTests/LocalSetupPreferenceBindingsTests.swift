import Foundation
import Testing
@testable import Hireva

@MainActor
@Suite(.serialized)
struct LocalSetupPreferenceBindingsTests {
    @Test
    func setupBindingsReadAndWriteTheApplicationPreferenceOwner() async throws {
        let suite = "HirevaSetupBinding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic-qwen-a", forKey: HirevaPreferenceKeys.selectedQwenModel)
        defaults.set(AnswerProviderMode.deepSeekWithLocalQwenFallback.rawValue,
            forKey: HirevaPreferenceKeys.answerProviderMode)
        let app = AppState(database: try AppDatabase(inMemory: true), dialogueDefaults: defaults)
        let view = LocalModelsSetupView(appState: app)
        #expect(!app.settingsState.parakeetContextBiasEnabled)
        app.settingsState.setParakeetContextBiasEnabled(true)
        #expect(defaults.bool(forKey: HirevaPreferenceKeys.parakeetContextBias))
        app.settingsState.setParakeetContextBiasEnabled(false)
        #expect(!app.settingsState.parakeetContextBiasEnabled)
        #expect(view.qwenModelSelection.wrappedValue == app.selectedQwenModelName)
        #expect(view.answerProviderSelection.wrappedValue == app.selectedAnswerProviderMode.rawValue)
        // A red assertion must not write to the old unscoped AppStorage store.
        if view.qwenModelSelection.wrappedValue == "synthetic-qwen-a",
           view.answerProviderSelection.wrappedValue == AnswerProviderMode.deepSeekWithLocalQwenFallback.rawValue {
            view.qwenModelSelection.wrappedValue = "synthetic-qwen-b"
            #expect(app.selectedQwenModelName == "synthetic-qwen-b")
            defaults.set("synthetic-qwen-c", forKey: HirevaPreferenceKeys.selectedQwenModel)
            #expect(view.qwenModelSelection.wrappedValue == "synthetic-qwen-c")
            view.answerProviderSelection.wrappedValue = AnswerProviderMode.localQwenPrimary.rawValue
            #expect(app.selectedAnswerProviderMode == .localQwenPrimary)
            app.setSelectedAnswerProviderMode(.deepSeekWithLocalQwenFallback)
            #expect(view.answerProviderSelection.wrappedValue == AnswerProviderMode.deepSeekWithLocalQwenFallback.rawValue)
        }
        await app.shutdownForTesting()
    }
}
