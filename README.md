<div align="center">

# Hireva

### Local-First AI Interview Copilot for macOS

Real-time interview transcription, complete-question detection, evidence-grounded answer generation, and context-aware assistance in a native floating interface.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-555555?logo=apple&logoColor=white)
![Local AI](https://img.shields.io/badge/AI-Local--First-2E8B57)
![Parakeet](https://img.shields.io/badge/ASR-Parakeet-5B5FC7)
![Qwen](https://img.shields.io/badge/LLM-Qwen3.5-7A5AF8)
![Developer Preview](https://img.shields.io/badge/status-developer%20preview-orange)

</div>

## Table of Contents

- [Introduction](#introduction)
- [Why Hireva?](#why-hireva)
- [Features](#features)
- [Installation](#installation)
- [Key Features in Action](#key-features-in-action)
- [How Hireva Works](#how-hireva-works)
- [System Architecture](#system-architecture)
- [Technology Stack](#technology-stack)
- [Evidence-Grounded Assistance](#evidence-grounded-assistance)
- [Privacy & Data Flow](#privacy--data-flow)
- [For Developers](#for-developers)
- [Current Limitations](#current-limitations)
- [Contributing](#contributing)
- [License](#license)

## Introduction

Hireva is a native macOS AI interview copilot. During a live interview, it captures the microphone, system audio, or both; transcribes the selected audio; identifies complete interviewer questions; and retrieves relevant facts from the candidate's profile, CV, project evidence, opportunity context, job description, and current dialogue. It then produces concise, directly usable answer guidance in a floating assistant.

The runtime is more than a `question → LLM` bridge. Each accepted question is tied to a session, question ID, generation ID, and frozen context snapshot. Retrieved candidate and opportunity evidence is kept distinct, generated claims are checked for alignment, and stale callbacks are rejected before a card can replace the current answer or be persisted.

```text
Microphone / System Audio
        ↓
Apple Speech or Local Parakeet
        ↓
Transcript normalization and source/speaker attribution
        ↓
Question extraction and dialogue understanding
        ↓
Candidate Profile + Opportunity Context + RAG
        ↓
Question / Generation / Context Snapshot
        ↓
Local Qwen or optional DeepSeek
        ↓
Evidence and answer-alignment validation
        ↓
Floating Interview Assistant + local SQLite history
```

Hireva is built with Swift, SwiftUI, Swift Package Manager, ScreenCaptureKit, AVFoundation, Apple Speech, Swift Concurrency, GRDB, and SQLite. Its local ASR path runs NVIDIA Parakeet TDT through a bundled native `sherpa-onnx` and ONNX Runtime helper, while local answer generation uses Qwen3.5 through Ollama's streaming API. DeepSeek remains an optional cloud-backed provider for users who explicitly configure it.

Hireva is **local-first**, not local-only. The recommended Parakeet + Qwen configuration can keep interview transcription and answer generation on the Mac. Apple Speech behavior depends on macOS, while optional DeepSeek or cloud embedding providers send selected content to their configured remote services.

## Why Hireva?

### Real-time assistance

Most interview tools stop at preparation. Hireva is designed for the live conversation: capture complete questions, recognize boundaries and follow-ups, retrieve relevant personal evidence, draft a concise answer, and prepare likely follow-up points.

### Context-aware answers

Hireva combines the current question with candidate evidence, opportunity context, retrieved document chunks, and the active dialogue. The result is grounded in the interview at hand instead of being generated from the question alone.

### Local-first privacy

Local Parakeet performs speech recognition through the bundled native runtime, and local Qwen runs through the user's Ollama service. Remote generation is opt-in and remains visibly separate from the local path.

### Answer ownership

Session, question, generation, and context-snapshot identities prevent an older answer from overwriting a rapid follow-up. Superseded work may retain an audit snapshot, but it cannot become the visible answer for the newer question.

### Evidence grounding

Candidate evidence and opportunity evidence are modeled separately. Validation guards against unsupported personal claims, turning job requirements or future plans into past experience, cross-profile context bleed, and unaligned answers.

## Features

- **🎙️ System and microphone capture** — ScreenCaptureKit and AVFoundation support **Microphone Only**, **System Audio Only**, and **Microphone + System Audio** modes.
- **📝 Two ASR paths** — use Apple Speech or the experimental local Parakeet TDT 0.6B v3 INT8 pipeline. The current Parakeet integration finalizes text at utterance boundaries; it does not claim word-by-word partial streaming.
- **🧠 Local Qwen answers** — Qwen3.5 4B runs through Ollama's `/api/chat` endpoint with cancellable NDJSON streaming and hidden model-thinking output.
- **☁️ Optional DeepSeek** — configure a remote provider only when a cloud-backed answer path is wanted. Provider credentials are stored in macOS Keychain.
- **📚 Candidate-aware retrieval** — Candidate Profile, CV/project evidence, Opportunity Context, job-description chunks, and additional notes are retrieved into a frozen request snapshot.
- **🔒 Evidence and alignment checks** — unsupported personal claims, opportunity-to-experience conversion, future-to-past claims, answer mismatch, and context bleed are checked before publication.
- **⚡ Rapid follow-up protection** — question and generation ownership rejects stale callbacks, old-answer replacement, and duplicate suggestion publication.
- **💬 Dialogue understanding** — handles multi-part questions, follow-ups, intentional repeats, ASR partial/final reconciliation, cumulative replay suppression, small-talk suppression, and candidate/interviewer attribution.
- **🪟 Floating assistant** — presents **Say First**, **Key Points**, and **Follow-up Ready** guidance in compact, normal, or diagnostic display modes.
- **💾 Local history and diagnostics** — GRDB/SQLite stores sessions, transcript segments when enabled, detected questions, suggestion cards, context snapshots, and retrieved-evidence links. Diagnostic text capture is independently controlled.

## Installation

### 🍎 macOS

Hireva currently ships as a source-built developer preview for Apple Silicon Macs running macOS 14 or later. There is no public GitHub Release asset yet.

#### Option 1 — Install from a local DMG

Build a release-configuration app without launching it, then create the DMG in
a new output directory:

```bash
git clone https://github.com/langchengg/Hireva.git
cd Hireva
HIREVA_SIGNING_MODE=adhoc HIREVA_BUILD_CONFIGURATION=release \
  ./script/build_and_run.sh --identity-check
mkdir -p release-candidates
./scripts/package_dmg.sh dist/Hireva.app release-candidates/0.1.0-1-adhoc
```

The package and its JSON provenance manifest are written to:

```text
release-candidates/0.1.0-1-adhoc/Hireva-0.1.0-1-arm64.dmg
release-candidates/0.1.0-1-adhoc/Hireva-0.1.0-1-arm64.manifest.json
```

1. Open `Hireva-0.1.0-1-arm64.dmg`.
2. Drag **Hireva** into the **Applications** folder.
3. Launch Hireva from Applications.
4. Complete the requested microphone and/or Screen & System Audio Recording permissions.
5. Open **Setup & Local Models** to complete local-model setup.

> **Developer Preview:** Current local DMG builds are ad-hoc signed and are not Apple-notarized public releases. Gatekeeper can therefore block a copied or downloaded build. Public distribution requires Developer ID Application signing, hardened runtime, Apple notarization, ticket stapling, and clean-Mac validation.

### Local AI Setup

The recommended local configuration is:

| Role | Recommended model | Installation |
| --- | --- | --- |
| Speech recognition | Parakeet TDT 0.6B v3 INT8 | Use **Setup & Local Models** inside Hireva |
| Answer generation | Qwen3.5 4B via Ollama | Install Ollama, then pull the model below |

```bash
ollama pull qwen3.5:4b
ollama list
```

Hireva's Local Model Manager downloads and verifies the Parakeet model under:

```text
~/Library/Application Support/Hireva/LocalModels/
```

The `.app` bundles the native Parakeet helper, `sherpa-onnx`, and ONNX Runtime libraries; users do not need to install Python or the Python `sherpa-onnx` package. Ollama and Qwen are separate installations managed by the user. See [Local Model Installation](docs/local-model-installation.md) for the pinned model identity and verification details.

### Build from Source

```bash
git clone https://github.com/langchengg/Hireva.git
cd Hireva
swift package resolve
swift test
./script/build_and_run.sh --verify
```

For macOS permission testing, always use `dist/Hireva.app`. Do not launch the raw SwiftPM executable as a production-like app.

## Key Features in Action

Hireva's primary workflow is exposed through native SwiftUI screens:

| Surface | What it does |
| --- | --- |
| **Home / Setup & Local Models** | Checks permissions, Parakeet runtime/model state, Ollama, and answer-provider readiness |
| **Live Interview** | Selects capture mode, starts the session, and shows transcript/question state |
| **Floating Assistant** | Keeps the current question, Say First answer, key points, and follow-up preparation visible |
| **Documents and Context** | Imports candidate evidence and opportunity context used by retrieval |
| **History and Diagnostics** | Reviews sessions, cards, provider state, retrieval provenance, and privacy-controlled runtime metadata |

## How Hireva Works

```text
┌───────────────────────────────────────────────┐
│              Interview Audio                  │
│         Microphone / System Audio             │
└───────────────────────┬───────────────────────┘
                        ↓
              Audio Capture
      ScreenCaptureKit + AVFoundation
                        ↓
             Speech Recognition
        Apple Speech / Local Parakeet
                        ↓
    Transcript normalization and reconciliation
                        ↓
       Speaker and audio-source attribution
                        ↓
       Question and dialogue understanding
                        ↓
      Candidate + Opportunity retrieval (RAG)
                        ↓
         Frozen request context snapshot
                        ↓
           Qwen / optional DeepSeek
                        ↓
       Evidence and answer-alignment checks
                        ↓
      Floating answer card + SQLite history
```

## System Architecture

| Layer | Primary implementation | Responsibility |
| --- | --- | --- |
| Application state | `AppState` and focused extensions | Coordinates sessions, capture, ASR, dialogue, retrieval, generation, permissions, and UI state |
| Audio capture | ScreenCaptureKit + AVFoundation | Captures system and microphone audio and preserves source identity |
| ASR providers | Apple Speech / Local Parakeet | Produces provider-attributed transcript events |
| Local ASR runtime | Native helper + sherpa-onnx + ONNX Runtime | Runs the downloaded Parakeet model without a Python release dependency |
| Transcript pipeline | Canonicalizer, reconciler, attribution policies | Normalizes ASR output and reconciles partial/final or cumulative replay events |
| Question and dialogue | Candidate pipeline, completeness gate, dialogue policy | Extracts complete interviewer questions and manages repeats, follow-ups, and suppression |
| Context retrieval | Candidate/opportunity context engine + hybrid RAG | Selects relevant evidence and freezes identity-bound context |
| Prompt and generation | Prompt context builder, coordinator, Qwen/DeepSeek clients | Streams answer content while preserving request ownership |
| Alignment | Claim validator and answer-alignment policies | Rejects unsupported, mismatched, stale, or cross-context answers |
| Persistence | GRDB + SQLite repositories | Stores sessions, questions, cards, context snapshots, evidence links, and allowed transcript data |
| Diagnostics | Runtime trace store and diagnostics views | Exposes provider, latency, retrieval, and lifecycle metadata under explicit privacy controls |

## Technology Stack

### Native macOS

- Swift and SwiftUI
- Swift Package Manager
- AppKit where window and platform integration require it
- Swift Concurrency

### Audio and Speech

- ScreenCaptureKit
- AVFoundation
- Apple Speech framework

### Local AI

- NVIDIA Parakeet TDT 0.6B v3 INT8
- sherpa-onnx 1.13.4
- ONNX Runtime 1.27.0
- Ollama
- Qwen3.5 4B

### Optional AI

- DeepSeek-compatible remote generation
- Configurable OpenAI-compatible cloud embeddings

### Data and Retrieval

- GRDB and SQLite
- Candidate Profile, project/CV evidence, and Opportunity Context
- Hybrid retrieval and frozen context snapshots

### Testing and Validation

- Swift Testing
- RuntimeSmoke and synthetic dialogue scenarios
- ThreadSanitizer and AddressSanitizer gates
- Real `.app`, ScreenCaptureKit, Parakeet, Apple Speech, Qwen, persistence, and lifecycle verification
- Release-package privacy scanning and signature verification

## Evidence-Grounded Assistance

Hireva does not simply place every document into a prompt. For each accepted question, it records and carries:

- session, transcript, question, and generation identities;
- a frozen candidate/opportunity context snapshot;
- selected candidate and opportunity evidence IDs;
- prompt-question and provider provenance;
- alignment, grounding, unsupported-claim, and context-isolation results.

This provenance supports stale-generation rejection, candidate/opportunity separation, unsupported personal-claim checks, context isolation, and persisted answer ownership. It is the core difference between Hireva and a generic `speech → chatbot` pipeline.

## Privacy & Data Flow

### Recommended local-first path

```text
Audio → bundled Parakeet runtime → local Ollama/Qwen → local GRDB/SQLite
```

Interview audio is processed locally after the Parakeet model is installed. Qwen prompts are sent to the user-managed Ollama service on loopback. Models, attachments, transcripts, and application data remain separate from the `.app` bundle.

### Other processing paths

| Choice | Data boundary |
| --- | --- |
| Apple Speech | Audio is processed through Apple's Speech framework; do not assume offline behavior for every macOS/locale configuration |
| DeepSeek | The prompt and selected interview context are sent over HTTPS to the configured remote provider |
| Cloud embeddings | Selected text is sent to the user-configured embedding endpoint |
| Parakeet model installation | Downloads the pinned model from trusted GitHub release hosts; interview content is not sent with the model request |

Local application data is stored under `~/Library/Application Support/Hireva/`. Provider keys are stored in macOS Keychain, not in SQLite. `Save transcripts locally` controls transcript-row persistence. Diagnostic tracing is separate and offers **Off**, **Metadata only**, and explicit **Full text (sensitive)** modes; full-text tracing requires opt-in, and disabling transcript storage limits effective trace detail.

See [Privacy and Data Flow](docs/privacy-and-data-flow.md) for the code-derived data map and removal boundaries.

## For Developers

```bash
git clone https://github.com/langchengg/Hireva.git
cd Hireva
swift package resolve
swift build
swift test
./scripts/runtime_smoke.sh --suite all
./scripts/verify_runtime_stability.sh
./script/build_and_run.sh --verify
HIREVA_SIGNING_MODE=adhoc HIREVA_BUILD_CONFIGURATION=release \
  ./script/build_and_run.sh --identity-check
mkdir -p release-candidates
./scripts/package_dmg.sh dist/Hireva.app release-candidates/0.1.0-1-adhoc
```

`script/build_and_run.sh` is the canonical build/sign/launch entrypoint for the SwiftPM GUI application. It creates `dist/Hireva.app`, bundles the native Parakeet runtime and required notices, signs nested code according to the explicit signing mode, launches the bundle, and verifies the running process.
`scripts/package_dmg.sh` consumes that existing signed app, reuses the strict
release validator before and after a read-only image mount, refuses existing
output directories, and does not build, launch, re-sign the app, notarize,
staple, or publish. Ad-hoc DMG behavior is unchanged. Developer ID input
additionally requires an explicit signing identity, 10-character
`HIREVA_EXPECTED_TEAM_IDENTIFIER`, and
`HIREVA_ALLOW_DISTRIBUTION_DMG=1` operator authorization; only that mode signs
and strictly verifies the completed DMG. `script/release/notarize_release.sh`
submits the checksummed signed DMG only after separate explicit authorization,
preserves Apple's response and log, and emits a separately checksummed stapled
DMG after ticket and Gatekeeper validation. Never place a real Team ID, signing
identity, notary profile, or credential in repository files or artifact
metadata.

Useful engineering references:

- [Code Map](docs/code-map.md)
- [Release Runbook](docs/release-runbook.md)
- [Runtime Regression Checklist](docs/runtime-regression-checklist.md)
- [macOS Local Signing](docs/macos-local-signing.md)
- [Notarization Preparation](docs/notarization-prep.md)

## Current Limitations

- Hireva supports macOS 14 or later; Apple Silicon `arm64` is the only packaged and validated architecture.
- Local Parakeet is experimental and produces final utterance transcripts rather than true word-by-word partial ASR.
- Ollama is a separately installed and operated local service; Qwen is not bundled in the DMG.
- Apple Speech availability and on-device behavior depend on macOS and locale.
- Current DMGs are ad-hoc signed, not Developer ID signed, not notarized, and rejected by Gatekeeper as public distribution artifacts.
- Bluetooth audio-route switching and failure recovery have not yet been validated on physical Bluetooth hardware.
- DeepSeek and cloud embeddings require user-supplied configuration and transmit selected content off-device when enabled.

The latest local dialogue validation marks the tested Parakeet + Qwen and Apple Speech + Qwen paths as suitable for controlled local use, while public distribution remains blocked. See the [Dialogue End-to-End Release Validation](docs/verification/hireva-dialogue-e2e-validation-20260809.md).

## Contributing

Issues and focused pull requests are welcome. Keep changes small, preserve question/generation/context ownership, add regression coverage for behavior changes, and run the targeted tests before the full validation commands above. Do not commit models, interview data, local databases, traces, credentials, `.app` bundles, or DMG files.

## License

This repository does not currently contain a project-level license file. Public source visibility alone does not grant permission to copy, modify, or redistribute the project. Open an issue with the repository owner for licensing questions; third-party component notices are documented separately in [Third-Party Licenses](docs/third-party-licenses.md).
