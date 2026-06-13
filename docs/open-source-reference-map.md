# Open-Source Reference Map

This document maps selected open-source repositories to InterviewCopilotMac subsystems. It is a research and architecture reference only. It does not add dependencies, vendor source code, or recommend production behavior changes in this pass.

License notes below are conservative engineering guidance, not legal advice. Before copying or vendoring any third-party code, re-check the upstream license, notices, dependency tree, platform support, and distribution requirements.

## Subsystem Mapping

| Repository | Primary subsystem mapping | Recommended use in InterviewCopilotMac |
|---|---|---|
| [insidegui/AudioCap](https://github.com/insidegui/AudioCap) | System/process audio capture | Conceptual reference for future macOS 14.4+ Core Audio process tap work. |
| [argmaxinc/argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) / WhisperKit | Future local/on-device ASR architecture | Reference only for ASR stream architecture, model selection, and local server ideas. |
| [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Low-level local ASR runtime | Reference only for C/C++ Whisper runtime design and streaming examples. |
| [soffes/HotKey](https://github.com/soffes/HotKey) | Global shortcut handling | Future SPM dependency candidate if shortcut UX becomes product scope. |
| [kishikawakatsumi/KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) | Keychain wrapper ergonomics | Reference for service/account/accessibility API shape. Keep current wrapper for now. |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) | Swift provider API, streaming, SSE/session patterns | Reference for streaming parser/session tests and request/response model separation. |
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite persistence, migrations, transactions, observation | Current app already uses GRDB. Use upstream docs/patterns without changing the DB layer now. |

## Files And Classes Worth Reading

### insidegui/AudioCap

- `AudioCap/ProcessTap/ProcessTap.swift`
- `AudioCap/ProcessTap/AudioProcessController.swift`
- `AudioCap/ProcessTap/CoreAudioUtils.swift`
- `AudioCap/ProcessTap/AudioRecordingPermission.swift`
- `AudioCap/RecordingView.swift`
- `AudioCap/ProcessSelectionView.swift`
- README sections around `NSAudioCaptureUsageDescription`, process tap setup, aggregate device setup, IO proc lifecycle, and cleanup.

### argmaxinc/argmax-oss-swift / WhisperKit

- `Sources/*WhisperKit*`
- `Sources/ArgmaxCLI/TranscribeCLI.swift`
- `Sources/ArgmaxCLI/TranscribeCLIArguments.swift`
- `Sources/ArgmaxCLI/TranscribeCLIUtils.swift`
- `Sources/ArgmaxCLI/Server/OpenAIHandler.swift`
- `Sources/ArgmaxCLI/Server/ServeCLI.swift`
- `Examples/WhisperAX`
- `Examples/ServeCLIClient/Swift`
- README sections around WhisperKit, local server, model selection, model download/management, and CLI usage.

### ggml-org/whisper.cpp

- `include/whisper.h`
- `src/whisper.cpp`
- `examples/stream/stream.cpp`
- `examples/server/server.cpp`
- `examples/common-whisper.cpp`
- `examples/common.h`
- `models/generate-coreml-model.sh`
- README sections around Core ML support, quantization, model files, and streaming/server examples.

### soffes/HotKey

- `Sources/HotKey/HotKey.swift`
- `Sources/HotKey/HotKeysController.swift`
- `Sources/HotKey/KeyCombo.swift`
- `Sources/HotKey/KeyCombo+System.swift`
- `Sources/HotKey/Key.swift`
- `Sources/HotKey/NSEventModifierFlags+HotKey.swift`
- `Tests/HotKeyTests/KeyComboTests.swift`

### kishikawakatsumi/KeychainAccess

- `Sources/Keychain.swift`
- `Lib/KeychainAccess/Keychain.swift`
- `Lib/KeychainAccessTests/KeychainAccessTests.swift`
- `Lib/KeychainAccessTests/ErrorTypeTests.swift`
- `Lib/KeychainAccessTests/EnumTests.swift`
- README sections around service-based keychains, accessibility, synchronizable behavior, access groups, and error handling.

### MacPaw/OpenAI

- `Sources/OpenAI/Private/Streaming/ServerSentEventsStreamParser.swift`
- `Sources/OpenAI/Private/Streaming/ServerSentEventsStreamInterpreter.swift`
- `Sources/OpenAI/Private/Streaming/StreamingSession.swift`
- `Sources/OpenAI/Private/Streaming/StreamingClient.swift`
- `Sources/OpenAI/Private/Streaming/StreamingError.swift`
- `Sources/OpenAI/Public/Models/ChatStreamResult.swift`
- `Sources/OpenAI/Public/Models/ChatQuery.swift`
- `Sources/OpenAI/Public/Models/EmbeddingsQuery.swift`
- `Sources/OpenAI/Public/Models/EmbeddingsResult.swift`
- `Sources/OpenAI/Private/JSONRequest.swift`
- `Sources/OpenAI/Private/JSONResponseDecoder.swift`
- `Sources/OpenAI/Private/JSONResponseErrorDecoder.swift`
- `Tests/OpenAITests/ServerSentEventsStreamParserTests.swift`
- `Tests/OpenAITests/StreamingSessionTests.swift`
- `Tests/OpenAITests/StreamingClientTests.swift`

### groue/GRDB.swift

- `Documentation/Migrations.md`
- `Documentation/Concurrency.md`
- `Documentation/FullTextSearch.md`
- `Documentation/FTS5Tokenizers.md`
- `Documentation/SharingADatabase.md`
- `Documentation/DemoApps/GRDBDemo/GRDBDemo/Database/AppDatabase.swift`
- `GRDB/Migration/DatabaseMigrator.swift`
- `GRDB/Core/DatabasePool.swift`
- `GRDB/Core/DatabaseQueue.swift`
- `GRDB/Core/TransactionObserver.swift`
- `GRDB/FTS/FTS5.swift`
- `GRDB/FTS/FTS5Tokenizer.swift`

## Patterns To Copy Conceptually

### Audio Capture

- Model capture as an explicit lifecycle: select source, create tap/stream, create device/session, start IO, publish buffers, stop IO, destroy all Core Audio resources.
- Treat aggregate device setup and teardown as one failure-prone transaction. Any partial setup should have deterministic cleanup.
- Track permission and cleanup failure modes separately from audio-buffer delivery failures.
- Keep user-visible permission explanations explicit. Do not implement stealth, bypass, or private permission probing.
- Do not copy AudioCap private TCC permission code into production. If process taps are added later, use public APIs and first-run permission behavior.

### ASR

- Keep a segment/transcription stream abstraction between capture and downstream question detection.
- Treat partial and final transcripts as separate events, with source, speaker, timing, and confidence metadata.
- Use the argmax local server concept only as a future option if the product later scopes local ASR. It should remain behind the existing transcription/provider protocol boundary.
- Do not add a local ASR runtime now. The current direction remains Apple Speech/cloud ASR adapters plus API-based LLM providers.

### Provider Streaming

- Keep request model, streaming session, parser, result model, and error classifier as separate units.
- Test SSE edge cases: split lines, empty events, retry/id fields, `[DONE]`, malformed chunks, cancellation, timeout, and late tokens after session invalidation.
- Make session invalidation explicit so stale streaming output cannot overwrite the current suggestion.
- Normalize provider-specific streaming payloads into app-owned result types instead of leaking OpenAI-only types through the provider layer.

### Keychain

- Keep stable service/account naming. For this app, provider keys should remain account-scoped rather than inferred from key prefixes.
- Centralize accessibility, synchronizable behavior, access group policy, and error mapping.
- Never log raw secrets. Diagnostics should show only configured/missing state and masked previews.
- A wrapper library does not solve ad-hoc signing, changing CDHash, or Keychain/TCC prompts by itself. Stable signing and bundle identity remain separate requirements.

### Global Shortcuts

- If global shortcuts become product scope, use a lifecycle-bound hotkey object that unregisters when deallocated or disabled.
- Prefer a small SPM dependency such as HotKey later instead of hand-rolling Carbon registration.
- Avoid adding shortcut support until the UX is scoped: default shortcut, conflict handling, settings UI, enable/disable state, and accessibility expectations.

### Database

- Keep migrations idempotent and append-only. Avoid ad hoc schema mutation outside the migrator.
- Use transactions for multi-table writes such as sessions, transcript segments, suggestions, sources, and recap reports.
- Keep database queue/pool ownership centralized. UI code should not manage raw SQLite connections.
- Consider observation patterns for read-heavy UI surfaces such as session lists and diagnostics, but do not migrate the app now.
- Use FTS only if transcript/session search becomes product scope. Current keyword RAG does not require a GRDB FTS migration yet.

## Do Not Copy Or Vendor

- Do not copy AudioCap private TCC permission code into production.
- Do not vendor the whisper.cpp C/C++ runtime now.
- Do not add argmax/WhisperKit as a production dependency until local ASR is explicitly scoped.
- Do not copy MacPaw/OpenAI wholesale or couple the provider layer to OpenAI-only types.
- Do not vendor GRDB source. The app already depends on GRDB through SPM.
- Do not vendor KeychainAccess source.
- Do not change current SQLite or Keychain wrappers in this documentation pass.
- Do not add HotKey, WhisperKit, argmax, whisper.cpp, AudioCap, KeychainAccess, MacPaw/OpenAI, or any new OpenAI client dependency as part of this task.

## Recommendation Matrix

| Subsystem | Recommendation | Rationale |
|---|---|---|
| Audio capture | Keep current implementation; imitate AudioCap architecture only | Current MVP should keep its existing ScreenCaptureKit/system audio path. AudioCap is most useful for future macOS 14.4+ process-tap lifecycle and cleanup design. |
| ASR | Keep current cloud/Apple Speech adapter direction | argmax/WhisperKit and whisper.cpp are future local ASR references only. Adding model runtimes now conflicts with the API-provider MVP focus. |
| Provider streaming | Keep custom abstraction; imitate MacPaw/OpenAI tests and parser/session separation | The app needs DeepSeek and OpenAI-compatible provider routing, not an OpenAI-only client dependency. |
| Keychain | Keep current `KeychainService`; consider KeychainAccess later only if wrapper complexity grows | Existing service/account behavior is already app-specific. KeychainAccess is useful as an ergonomics reference. |
| Global shortcuts | Add HotKey via SPM later only if shortcut UX is scoped | HotKey is a reasonable dependency candidate, but shortcuts are not part of the current acceptance surface. |
| DB layer | Keep current GRDB persistence; use upstream GRDB docs/patterns | The app already uses GRDB. Do not migrate the DB layer now. |
| Transcript/session search | Future investigation | GRDB FTS may help later, but current keyword RAG and session storage should remain unchanged. |

## Recommended Next Engineering Actions

1. Finish runtime question boundary acceptance before Phase 2F.
2. Add provider streaming parser edge-case tests inspired by MacPaw/OpenAI.
3. Add an audio lifecycle cleanup checklist inspired by AudioCap.
4. Consider HotKey SPM dependency only when shortcut UX is scoped.
5. Defer local ASR dependencies until the API-provider MVP is stable.

## Source And License Notes

| Repository | License signal observed | Engineering note |
|---|---|---|
| AudioCap | BSD-2-Clause | Permissive, but private TCC code is not production-acceptable for this app. |
| argmax-oss-swift | MIT, with third-party notices | Do not add until local ASR is explicitly scoped and model/download/privacy UX is designed. |
| whisper.cpp | MIT | Avoid vendoring due to native build, model distribution, and runtime complexity. |
| HotKey | MIT | Prefer SPM dependency later if shortcuts are scoped. |
| KeychainAccess | MIT | Reference only for now; do not replace current wrapper in this pass. |
| MacPaw/OpenAI | MIT | Reference only for streaming/client design; avoid OpenAI-only coupling. |
| GRDB.swift | MIT | Already used through SPM. Follow docs and upgrade guidance rather than vendoring source. |
