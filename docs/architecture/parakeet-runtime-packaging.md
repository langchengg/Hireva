# Parakeet Runtime Packaging

> Status: This document describes the current release-hardening design. It has
> not been validated on a clean Mac and does not make a release-ready claim.

## Selected Runtime

Hireva packages a native, arm64-only Parakeet helper. The selected runtime is
`Contents/Helpers/parakeet_asr_helper`, built from
`native/parakeet_asr_helper.mm`. It calls the sherpa-onnx C API and loads ONNX
Runtime through bundled dynamic libraries.

The release bundle must not contain the legacy Python sidecar, a Python
interpreter, `numpy`, or Python packages. Development overrides may be useful in
debug builds, but a release build resolves the helper from the app bundle and
does not rely on an external executable path.

## Pinned Components

| Component | Pinned version | Bundle role |
| --- | --- | --- |
| `parakeet_asr_helper` | Hireva native source | Child process receiving audio and emitting transcript JSONL |
| sherpa-onnx | `v1.13.4` | C API and offline NeMo transducer inference |
| ONNX Runtime | `1.27.0` | Native ONNX execution used by sherpa-onnx |
| Parakeet model | `parakeet-tdt-0.6b-v3-int8` | Separately downloaded ONNX weights and tokens |

The app and helper are built only for Apple Silicon `arm64`. Intel and universal
artifacts are outside the `0.1.0` scope.

## Build And Bundle Flow

1. `script/build_and_run.sh` requires `HIREVA_BUILD_ARCHS=arm64`.
2. `script/runtime/build_parakeet_helper.sh` calls
   `script/runtime/prepare_sherpa_runtime.sh`.
3. The preparation script downloads the pinned sherpa-onnx macOS arm64 shared
   archive and matching C API header over HTTPS and verifies their pinned
   SHA-256 values.
4. `clang++` builds the Objective-C++ helper for `arm64` with an `@rpath`
   dependency on `libsherpa-onnx-c-api.dylib`.
5. The build copies and signs the helper and dylibs inside-out before signing
   the app bundle.

Expected release layout:

```text
Hireva.app/Contents/
  MacOS/Hireva
  Helpers/parakeet_asr_helper
  Frameworks/libsherpa-onnx-c-api.dylib
  Frameworks/libonnxruntime.1.27.0.dylib
```

The Parakeet model archive is not embedded in `Hireva.app`. The app downloads
and verifies it separately, then installs it at:

```text
~/Library/Application Support/Hireva/LocalModels/
  asr/parakeet-tdt-0.6b-v3-int8/
    asr-models-5793d0fd397c5778/
```

## Runtime Data Flow

1. Hireva captures the selected microphone and/or system-audio stream.
2. The app starts the bundled native helper with the verified model directory.
3. The app writes control records and mono Float32 audio records as JSONL to the
   helper's standard input.
4. The helper runs local sherpa-onnx inference and writes transcript JSONL to
   standard output.
5. Hireva validates and maps those events to the
   `local_parakeet_asr` transcript source.

The helper does not need a network connection for inference after the model is
installed. Model acquisition is a separate HTTPS flow.

## Packaging Invariants

Before any distribution candidate is accepted, verify all of the following:

- `file` reports `arm64` for the app executable, helper, and both dylibs.
- `otool -L` resolves the helper's sherpa dependency through `@rpath`.
- the bundle contains no `parakeet_asr_sidecar.py`, Python runtime, or `numpy`;
- the helper health response reports sherpa-onnx `1.13.4`, ONNX Runtime
  `1.27.0`, `arm64`, and runtime mode `bundled_native`;
- the model is absent from the app bundle and present only in the versioned
  Application Support path after installation;
- third-party license and notice payloads described in
  `docs/third-party-licenses.md` accompany the distribution.

## Unresolved Release Gates

The current environment has no Developer ID/notarization credentials. Ad-hoc
signing can verify bundle integrity locally but does not establish an identified
developer or satisfy notarized distribution. A Developer ID signature,
notarization, ticket stapling, Gatekeeper assessment, and clean-Mac validation
remain required before any release-ready statement.

## Official References

- sherpa-onnx `v1.13.4` release:
  https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.4
- sherpa-onnx Parakeet v3 conversion and model instructions:
  https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html#sherpa-onnx-nemo-parakeet-tdt-0-6b-v3-int8-25-european-languages
- ONNX Runtime `v1.27.0` release:
  https://github.com/microsoft/onnxruntime/releases/tag/v1.27.0
- Apple notarization requirements:
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
