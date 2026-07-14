# Local Model Installation

> Status: The model installer and manifest are part of current release
> hardening. They have not been exercised on a clean Mac, and this document does
> not make a release-ready claim.

## Parakeet Model Identity

| Field | Value |
| --- | --- |
| Hireva model id | `parakeet-tdt-0.6b-v3-int8` |
| Manifest version | `asr-models-5793d0fd397c5778` |
| Upstream asset size | `487170055` bytes |
| Upstream asset SHA-256 | `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf` |
| Archive root | `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` |

Exact asset URL:

https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2

The installed model is stored outside the application bundle at the versioned
path:

```text
~/Library/Application Support/Hireva/LocalModels/
  asr/parakeet-tdt-0.6b-v3-int8/
    asr-models-5793d0fd397c5778/
```

Do not install a new release into the legacy unversioned
`LocalModels/asr/parakeet-tdt-0.6b-v3-int8` path without the version suffix.

## Recommended In-App Installation

1. Launch the installed `Hireva.app` bundle.
2. Open **Setup & Local Models**.
3. In the Parakeet section, select **Download**. The combined
   **Install Recommended Local Models** action can also request Parakeet and
   ask the external Ollama service to pull Qwen.
4. Keep the app open until download, archive preflight, extraction, and payload
   verification complete.
5. Confirm **Parakeet model status** reports installed/ready and **Parakeet
   runtime status** reports the bundled native runtime ready.
6. Select **Enable Local Parakeet** only after both checks pass.

The installer accepts HTTPS downloads only from `github.com` and
`release-assets.githubusercontent.com`, checks redirects, verifies the exact
archive byte count and SHA-256, rejects unsafe archive paths and link entries,
extracts into staging, verifies the expected payload manifest, and performs an
atomic installation. A failed verification must not be treated as installed.

## Independent Archive Check

For diagnostic use, verify a separately obtained archive before attempting any
manual staging:

```bash
ARCHIVE="$HOME/Downloads/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
stat -f '%z bytes' "$ARCHIVE"
shasum -a 256 "$ARCHIVE"
```

Expected output values are `487170055 bytes` and
`5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`.
Do not extract or install an archive with different values. Prefer the in-app
installer because it also verifies every expected installed file and preserves
the prior verified version for rollback where available.

## Licensing And Attribution

The original NVIDIA Parakeet TDT 0.6B v3 model is licensed CC BY 4.0:
https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3

The downloaded sherpa-onnx asset is a modified form: it was converted to ONNX
and quantized to INT8 using the sherpa-onnx conversion work documented at:

- https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html#sherpa-onnx-nemo-parakeet-tdt-0-6b-v3-int8-25-european-languages
- https://github.com/k2-fsa/sherpa-onnx/tree/master/scripts/nemo/parakeet-tdt-0.6b-v3
- https://creativecommons.org/licenses/by/4.0/

Preserve NVIDIA attribution, the CC BY 4.0 link, sherpa-onnx conversion credit,
and the statement that ONNX conversion and INT8 quantization are modifications.

## Qwen And Ollama Are Separate

Qwen is not installed under Hireva's `LocalModels` directory. Hireva talks to
the separately installed Ollama service at `http://localhost:11434`; Ollama
owns its model storage and may use the network when pulling a model.

- Ollama macOS installer: https://ollama.com/download/mac
- Ollama local API: https://docs.ollama.com/api/introduction

## Failure Handling

- Hash, size, host, archive-layout, or payload mismatch: stop and retain the
  error; do not bypass verification.
- Interrupted download: use **Retry**; partial staging data must not become the
  active model.
- Corrupt installed model: use the app's repair path and re-verify.
- Rollback unavailable: reinstall the pinned archive instead of moving an
  unverified directory into place.
- Model ready but ASR unavailable: verify the native helper status. Model
  installation alone does not prove runtime readiness.
