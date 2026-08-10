# Hireva 0.1.0 Release Notes

> Draft release-candidate notes, updated 2026-07-14. Version `0.1.0` has not
> completed clean-Mac validation, Developer ID signing, or notarization. It is
> not release-ready, and these notes are not a release announcement.

## Candidate Scope

Hireva `0.1.0` is an Apple Silicon macOS 14+ interview-copilot candidate. This
hardening pass establishes a native local Parakeet ASR packaging path, pinned
runtime dependencies, verified model installation, and explicit release,
privacy, and licensing documentation.

## Runtime And Packaging

- Selected a native `arm64` Parakeet helper bundled in
  `Hireva.app/Contents/Helpers`.
- Pinned sherpa-onnx `v1.13.4` and ONNX Runtime `1.27.0` native libraries.
- Removed the release dependency on a Python sidecar. Python and `numpy` are not
  bundled.
- Constrained the candidate to Apple Silicon `arm64`; Intel and universal
  binaries are not included.
- Kept the Parakeet model outside the app bundle in a versioned Application
  Support path.

## Local Model Hardening

- Pinned the Parakeet archive to exactly `487170055` bytes and SHA-256
  `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`.
- Added trusted-host and redirect checks, archive-path preflight, per-file
  payload verification, staged installation, repair, and verified rollback
  behavior.
- Recorded NVIDIA CC BY 4.0 attribution and the sherpa-onnx ONNX conversion and
  INT8 quantization modifications.

## Local And Remote Services

- Local Parakeet inference runs through the bundled native helper after its
  separately downloaded model is installed.
- Local Qwen uses Ollama at `http://localhost:11434`. Ollama and its models are
  external and are not bundled with Hireva.
- DeepSeek remains an optional remote provider; selected prompt and interview
  context leave the Mac when it is used.

## Third-Party Components

- sherpa-onnx `1.13.4`: Apache License 2.0.
- ONNX Runtime `1.27.0`: MIT, with the full versioned
  `ThirdPartyNotices.txt` required in a distribution.
- GRDB `6.29.3`: MIT.
- NVIDIA Parakeet TDT 0.6B v3 model: CC BY 4.0; installed derivative converted
  to ONNX and quantized to INT8 by sherpa-onnx.

See `docs/third-party-licenses.md` for official source URLs and the release
notice gate.

## Known Limitations And Blockers

- No clean-Mac install, first-launch, permission, model-download, or uninstall
  validation has been completed.
- Developer ID and notarization credentials are unavailable in the current
  environment. Current ad-hoc builds are for local/internal validation only.
- Gatekeeper acceptance without an override has not been demonstrated.
- Third-party full license and notice files are fetched from pinned official
  sources with SHA-256 verification during the build; they still require final
  inspection in the exact Developer ID distribution artifact.
- Public update, support, privacy-policy, and retention commitments are not
  established by this candidate.

## Official References

- sherpa-onnx `v1.13.4`: https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.4
- ONNX Runtime `v1.27.0`: https://github.com/microsoft/onnxruntime/releases/tag/v1.27.0
- GRDB `v6.29.3`: https://github.com/groue/GRDB.swift/releases/tag/v6.29.3
- NVIDIA Parakeet model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Apple notarization requirements:
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
