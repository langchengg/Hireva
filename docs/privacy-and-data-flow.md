# Privacy And Data Flow

> Status: This is a code-derived privacy map for release hardening, not a
> published privacy policy. It has not been validated on a clean Mac and does
> not support a release-ready claim.

## Data Categories

Hireva can process sensitive interview material, including microphone audio,
system audio, transcripts, questions, generated answers, candidate context,
attachments, provider credentials, and operational diagnostics. Treat all such
content as confidential unless the user has explicitly classified it otherwise.

## Processing Paths

| User choice or action | Data sent | Destination | Network behavior |
| --- | --- | --- | --- |
| Local Parakeet ASR | Captured PCM audio and local model path | Bundled `parakeet_asr_helper` child process | Local process only after model installation |
| Apple Speech ASR | Captured audio | Apple's Speech framework | Do not assume offline operation; behavior depends on the OS and recognizer |
| Local Qwen answers | Prompt, transcript/question context, and generation settings | User-installed Ollama at `http://localhost:11434/api/chat` | Loopback request; Ollama is external and may use the network to pull models |
| DeepSeek answers | Prompt and selected interview context | `https://api.deepseek.com/chat/completions` | Remote HTTPS request when the user selects/configures DeepSeek |
| Configured cloud embeddings | Text selected for embedding | User-configured OpenAI-compatible embedding endpoint | Remote HTTPS request when that optional provider is enabled |
| Parakeet installation | Model asset request | GitHub and trusted GitHub release-asset host | HTTPS download; no interview content is sent |

Local Parakeet inference does not send captured audio to NVIDIA, sherpa-onnx,
Microsoft, or GitHub. The model download is a separate network operation.

## Local Storage

Hireva stores runtime data under:

```text
~/Library/Application Support/Hireva/
```

Known contents include:

- `hireva.sqlite`: sessions, transcript-derived questions, suggestions, and
  related application records;
- `runtime_transcript_trace.jsonl`: runtime diagnostics that can contain or
  identify interview activity;
- `Attachments/` and `Exports/`: user-selected source files and generated
  exports;
- `LocalModels/`: versioned locally downloaded model payloads, including the
  Parakeet ONNX files.

Preferences are stored through macOS user defaults. Provider API keys are
stored in macOS Keychain rather than in the repository or SQLite database.
Ollama owns its own process, model storage, logs, and update behavior outside
Hireva's Application Support directory.

## Permission Boundaries

- Microphone capture requires the macOS Microphone permission.
- System-audio capture requires Screen & System Audio Recording permission.
- Permission changes can require quitting and reopening the same signed app
  bundle before they take effect.
- Denying a permission must disable the affected capture path without silently
  substituting a different data source.

Apple guidance:

- Microphone access:
  https://support.apple.com/en-ca/guide/mac-help/mchla1b1e1fe/mac
- Screen and system-audio recording:
  https://support.apple.com/guide/mac-help/allow-apps-to-use-screen-and-audio-recording-mchl592e5686/mac
- Speech framework:
  https://developer.apple.com/documentation/speech/

## User And Operator Controls

- Select Local Parakeet only when its native runtime and verified local model
  both report ready.
- Select local Qwen only when the user accepts the separately installed Ollama
  service and model.
- Do not enable DeepSeek or cloud embeddings without clearly disclosing that
  prompt or text content leaves the Mac.
- Never include API keys in logs, release diagnostics, issue reports, or the
  SQLite database.
- Redact transcripts, candidate context, answers, file paths, and provider
  responses before sharing diagnostics.
- Removing `Hireva.app` does not remove Application Support data, Keychain
  items, or Ollama-managed models. Data removal must address each store
  separately and should be confirmed before destructive action.

## Current Gaps Before Release

- No clean-Mac permission and data-residue validation has been completed.
- No public release privacy policy or retention commitment is established by
  this engineering document.
- External-provider behavior and terms can change independently and must be
  reviewed for the actual release date.
- The final release candidate must be observed under representative local-only
  and cloud-enabled configurations to confirm that network traffic matches this
  map.

## Official Service References

- Ollama local API base URL: https://docs.ollama.com/api/introduction
- DeepSeek chat completion API:
  https://api-docs.deepseek.com/api/create-chat-completion
- Parakeet model source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
