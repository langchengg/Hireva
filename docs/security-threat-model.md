# Hireva Threat Model

## Scope

Hireva is a local native macOS SwiftUI app. In scope: candidate/opportunity
document storage, transcript/session storage, Keychain API-key storage, local
Parakeet and Ollama processing, optional DeepSeek/cloud calls, microphone,
Speech and Screen/System Audio permissions, exports, and local diagnostics. Out
of scope: stealth overlays, anti-detection behavior, and services operated by
the user outside the Hireva process.

## Assets

- DeepSeek API key stored in macOS Keychain.
- CV, job description, transcripts, suggestions, and recaps stored in local SQLite.
- Exported markdown files under Application Support.
- User permission state for microphone, speech recognition, and future capture surfaces.
- Prompt/model metadata and diagnostics, excluding secrets.

## Trust Boundaries

- User input to local SQLite: CV/JD text, mock transcript, session metadata.
- Local app to DeepSeek over HTTPS: only recent transcript and top retrieved CV/JD chunks should be sent.
- Local app to Keychain Services: API key read/write/delete.
- Local app to Apple microphone and Speech frameworks: permission-gated audio/transcription.
- Local app to filesystem exports: user-owned markdown output.

## Threats and Mitigations

1. API key exposure through logs or database.
   - Impact: unauthorized API usage.
   - Mitigation: store only in Keychain, never in SQLite, never in diagnostics, and redact from UI outputs.

2. Oversharing CV/JD or transcripts to the LLM provider.
   - Impact: unnecessary disclosure of private candidate data.
   - Mitigation: deterministic retrieval, CV limit 1,500 words, JD limit 1,000 words, transcript limit 800 words, and visible Settings explanation of what is sent.

3. Fabricated interview suggestions.
   - Impact: user may overclaim experience.
   - Mitigation: prompt truthfulness constraints, evidence_used and risk_level fields, and caution text when evidence is thin.

4. Unauthorized capture expectations.
   - Impact: privacy or policy violation.
   - Mitigation: only public APIs, explicit permissions, no stealth/anti-detection features, and user-facing responsible-use notice.

5. Local data persistence risk on shared machines.
   - Impact: CV/JD and transcript disclosure to local account users or backups.
   - Mitigation: local delete controls, per-session/document deletion,
     transcript-saving toggle, diagnostic trace default-off/metadata modes,
     active-plus-rotated trace deletion, Application Support storage, and
     Keychain for secrets.

6. Stale generation or cross-profile answer disclosure.
   - Impact: an answer can be shown or persisted for the wrong question or
     context.
   - Mitigation: immutable session/question/generation/context ownership,
     cancellation guards before UI and persistence, and rapid-follow-up tests.

7. Source confusion between microphone and system audio.
   - Impact: candidate speech can trigger an answer or be attributed to the
     interviewer.
   - Mitigation: capture-mode validation, separate Parakeet source segmenters,
     explicit speaker metadata, and candidate-speech gating.

## Remaining Production Work

- Add sandbox/network/audio entitlements when moving from local SwiftPM bundle to a signed Xcode archive.
- Sign with a Developer ID certificate, enable hardened runtime, then notarize the distributable artifact.
- Consider SQLCipher or file-level encryption if local transcript confidentiality becomes a distribution requirement.
