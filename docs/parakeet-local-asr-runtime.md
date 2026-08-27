# Parakeet Local ASR Runtime

Hireva's optional Local Parakeet ASR is an experimental, arm64-only, final-only
provider. The release app runs the bundled native helper at
`Contents/Helpers/parakeet_asr_helper`; it must never label Apple Speech output
as Parakeet or silently fall back to Apple Speech.

## Model descriptor

- Descriptor id: `parakeet-tdt-0.6b-v3-int8`
- Display name: `Parakeet TDT 0.6B`
- ASR source metadata: `local_parakeet_asr`
- Local path: `~/Library/Application Support/Hireva/LocalModels/asr/parakeet-tdt-0.6b-v3-int8`
- Download URL: `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`
- Descriptor version: `asr-models-5793d0fd397c5778`
- Archive size: exactly `487170055` bytes
- Archive SHA-256: `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`

Required files under the local path:

- `encoder.int8.onnx`, exactly `652184281` bytes, SHA-256
  `acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247`
- `decoder.int8.onnx`, exactly `11845275` bytes, SHA-256
  `179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e`
- `joiner.int8.onnx`, exactly `6355277` bytes, SHA-256
  `3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3`
- `tokens.txt`, exactly `93939` bytes, SHA-256
  `d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d`

Installation and readiness verify the app-pinned archive identity and the
exact size and SHA-256 of every required model payload. The pinned values are
part of Hireva's reviewed descriptor; they are not inferred from mutable
upstream metadata at install time.

## Native runtime contract

The release app launches its bundled helper with:

```text
--model-dir <absolute model directory>
--session-id <session id>
--capture-mode <microphoneOnly|systemAudioOnly|microphoneAndSystem>
--jsonl
```

The app sends newline-delimited JSON audio events to the sidecar on stdin.
Audio events contain mono Float32 little-endian PCM samples encoded as base64
and an explicit source channel:

```json
{
  "type": "audio",
  "sequence": 1,
  "sampleRate": 48000.0,
  "channels": 1,
  "encoding": "float32le",
  "audioSource": "systemAudio",
  "audio": "base64..."
}
```

The sidecar may also receive control events:

```json
{"type": "flush"}
{"type": "stop"}
```

The sidecar must run real ASR inference and write newline-delimited JSON
transcript events to stdout:

```json
{
  "segmentId": "uuid-or-stable-id",
  "text": "recognized text",
  "isFinal": true,
  "startTime": 0.0,
  "endTime": 1.2,
  "confidence": 0.91,
  "source": "local_parakeet_asr",
  "audioSource": "systemAudio",
  "speaker": "interviewer"
}
```

`startTime`, `endTime`, and `confidence` are optional. `source`, `audioSource`,
and `speaker` are validated against the active capture mode. The helper keeps a
separate utterance segmenter for microphone and system audio so samples cannot
be concatenated across sources. The app maps each accepted event
to `TranscriptSegment(asrSource: .localParakeetASR)` and sends it through the
same transcript, question detection, and answer generation pipeline used by
Apple Speech.

Direct WAV validation:

```bash
say -o /tmp/parakeet_test.aiff "How did the robot decide which object to approach?"
afconvert -f WAVE -d LEI16@16000 /tmp/parakeet_test.aiff /tmp/parakeet_test.wav
dist/Hireva.app/Contents/Helpers/parakeet_asr_helper \
  --model-dir "$HOME/Library/Application Support/Hireva/LocalModels/asr/parakeet-tdt-0.6b-v3-int8" \
  --session-id direct-test \
  --capture-mode systemAudioOnly \
  --jsonl \
  --wav /tmp/parakeet_test.wav
```

Release discovery rejects external Python or user-default helper overrides.
The legacy Python implementation is development-only and is not packaged.

## Limitations

The native helper uses sherpa-onnx offline transducer inference with local
silence-based utterance segmentation. It emits final transcript events after an
utterance boundary, not low-latency partials. It does not use Apple Speech and
must not be treated as active unless the app receives transcript events whose
source is `local_parakeet_asr`.

## Current blocker

On a clean local machine, Parakeet remains inactive until:

1. The required ONNX/vocabulary files exist in the Application Support path.
2. The bundled native helper health check and model probe succeed.
3. The selected ASR provider is Local Parakeet and both readiness checks pass.

If either the model or runtime is missing, the app reports a concrete model or
native-runtime readiness failure. Apple Speech is available only when the
user explicitly selects it; the app must not silently run Apple Speech while
labeling transcripts as Parakeet.
