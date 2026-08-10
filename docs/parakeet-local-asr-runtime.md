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
- Checksum: not configured

Required files under the local path:

- `encoder.int8.onnx`, minimum 652 MB
- `decoder.int8.onnx`, minimum 11.8 MB
- `joiner.int8.onnx`, minimum 6.3 MB
- `tokens.txt`, minimum 90 KB

Readiness currently verifies required file presence and minimum sizes. It does
not perform cryptographic checksum verification because the upstream release
does not publish a single checksum manifest for this app to verify.

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
