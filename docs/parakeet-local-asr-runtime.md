# Parakeet Local ASR Runtime

This project has a local Parakeet ASR adapter, but the app must not label
Apple Speech transcripts as Parakeet. Local Parakeet is usable only when both
the model files and a sidecar executable are present.

## Model descriptor

- Descriptor id: `parakeet-tdt-0.6b-v3-int8`
- Display name: `Parakeet TDT 0.6B`
- ASR source metadata: `local_parakeet_asr`
- Local path: `~/Library/Application Support/InterviewCopilotMac/LocalModels/asr/parakeet-tdt-0.6b-v3-int8`
- Download URL: not configured
- Checksum: not configured

Required files under the local path:

- `encoder-model.int8.onnx`, minimum 580 MB
- `decoder_joint-model.int8.onnx`, minimum 8 MB
- `nemo128.onnx`, minimum 100 KB
- `vocab.txt`, minimum 5 KB

Readiness currently verifies required file presence and minimum sizes. It does
not perform cryptographic checksum verification because the descriptor has no
checksum.

## Runtime contract

The app launches a sidecar process from `PARAKEET_ASR_SIDECAR_PATH` or the
`InterviewCopilot.parakeetSidecarPath` user default. The executable must accept:

```text
--model-dir <absolute model directory>
--session-id <session id>
--capture-mode <microphoneOnly|systemAudioOnly|microphoneAndSystem>
--jsonl
```

The sidecar must write newline-delimited JSON transcript events to stdout:

```json
{
  "segmentId": "uuid-or-stable-id",
  "text": "recognized text",
  "isFinal": true,
  "startTime": 0.0,
  "endTime": 1.2,
  "confidence": 0.91
}
```

`startTime`, `endTime`, and `confidence` are optional. The app maps each event
to `TranscriptSegment(asrSource: .localParakeetASR)` and sends it through the
same transcript, question detection, and answer generation pipeline used by
Apple Speech.

## Current blocker

On a clean local machine, Parakeet remains inactive until:

1. The required ONNX/vocabulary files exist in the Application Support path.
2. A real sidecar executable is installed and executable.
3. The user explicitly selects Local Parakeet after both readiness checks pass.

If either the model or runtime is missing, the app reports `model_not_ready` or
`local_asr_runtime_not_implemented` and keeps Apple Speech as the active ASR.
