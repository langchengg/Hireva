# Third-Party Licenses And Notices

> Status: This inventory records release obligations; it is not legal advice and
> is not itself a substitute for the complete license and notice files that must
> accompany a distribution. No clean-Mac validation has been completed, and
> this document does not make a release-ready claim.

Do not paste full upstream license texts into this document. Package exact,
versioned copies from the official sources identified below.

## Bundled Software

### sherpa-onnx 1.13.4

- Use: bundled native `libsherpa-onnx-c-api.dylib` and C API integration.
- License: Apache License 2.0.
- Distribution action: include the Apache 2.0 license, retain applicable
  copyright, attribution, and NOTICE material, and identify modifications where
  required by the license.
- Official release: https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.4
- Official license: https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.4/LICENSE

### ONNX Runtime 1.27.0

- Use: bundled `libonnxruntime.1.27.0.dylib`, supplied through the pinned
  sherpa-onnx runtime.
- License: MIT.
- Distribution action: include the ONNX Runtime copyright and MIT permission
  notice with copies or substantial portions of the software.
- Additional mandatory notice action: ship the complete, unedited
  `ThirdPartyNotices.txt` for `v1.27.0`. The MIT summary alone does not cover the
  notices for third-party code incorporated into ONNX Runtime.
- Official release: https://github.com/microsoft/onnxruntime/releases/tag/v1.27.0
- Official license: https://github.com/microsoft/onnxruntime/blob/v1.27.0/LICENSE
- Official third-party notices:
  https://github.com/microsoft/onnxruntime/blob/v1.27.0/ThirdPartyNotices.txt

### GRDB 6.29.3

- Use: Swift package dependency for SQLite access.
- License: MIT.
- Distribution action: include the GRDB copyright and MIT permission notice
  with copies or substantial portions of GRDB.
- Official release: https://github.com/groue/GRDB.swift/releases/tag/v6.29.3
- Official license: https://github.com/groue/GRDB.swift/blob/v6.29.3/LICENSE

### Workflow dependencies (SPM, exact versions)

| Dependency | Pinned version / commit | Actual product call | License |
|---|---|---|---|
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 / 22787ffb59de99e5dc1fbfe80b19c97a904ad48d | `MaterialExtractionService` reads DOCX entries; replaces the previous unsupported-format path, no custom ZIP decoder | MIT |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | 2.13.9 / 18b80329749eca5ea29fc50211dca5c7eff5bfec | `PublicRoleBriefService` parses user-requested HTML into source excerpts | MIT, retain jsoup and SwiftSoup notices |
| [swift-fsrs](https://github.com/open-spaced-repetition/swift-fsrs) | 4.1.0 / 1d3cd7a4e72b210b31ca47c23efe4b464673bb54 | `PracticeController.rate` schedules knowledge cards from explicit user ratings | MIT |

These are dependencies, not copied implementations. `PracticeWorkflowTests` adapts the
interval vector from swift-fsrs `Tests/FSRSTests/FSRSTests.swift` at the commit above
(Copyright 2023 Ben Smiley, MIT). This checks adapter compatibility; it is not an
independent evaluation of interview quality. Full copyright/permission texts for all
three packages are hash-verified by `script/runtime/prepare_third_party_notices.sh`
and copied by the existing bundle script. Native PDFKit/Vision extract PDF/image
text; Foundation XMLParser interprets a bounded subset of DOCX XML. No complete DOCX
layout or image-diagram understanding is claimed.

WhisperKit was evaluated but is not a dependency: no new model was installed and
Chinese audio has not been verified. Existing Parakeet and Apple Speech remain the
configured ASR routes. No external multi-agent framework or generic code runtime
was incorporated.

## Separately Downloaded Model

### NVIDIA Parakeet TDT 0.6B v3

- Original work: NVIDIA `parakeet-tdt-0.6b-v3`.
- License: Creative Commons Attribution 4.0 International, CC BY 4.0.
- Hireva-installed derivative: the sherpa-onnx asset
  `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`.
- Modification statement: the installed asset was converted from NVIDIA's
  original model to ONNX and quantized to INT8 by the sherpa-onnx project. It is
  not represented as an unmodified NVIDIA artifact, and no NVIDIA endorsement
  is implied.
- Attribution action: identify NVIDIA as the original model creator, link the
  CC BY 4.0 license, identify sherpa-onnx and its conversion script, and state
  the ONNX conversion and INT8 quantization changes wherever the model is
  distributed or made available.

Official sources:

- NVIDIA model card: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- CC BY 4.0 license summary and legal-code link:
  https://creativecommons.org/licenses/by/4.0/
- sherpa-onnx conversion and download documentation:
  https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html#sherpa-onnx-nemo-parakeet-tdt-0-6b-v3-int8-25-european-languages
- conversion scripts:
  https://github.com/k2-fsa/sherpa-onnx/tree/master/scripts/nemo/parakeet-tdt-0.6b-v3
- exact upstream asset:
  https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2

## External Service Not Bundled

Ollama is an external application and localhost service. Hireva does not bundle
the Ollama executable, Ollama runtime files, or Ollama-managed language models.
Users who select local Qwen must install and run Ollama separately and remain
responsible for the terms of Ollama and the selected model.

- Official macOS download: https://ollama.com/download/mac
- Official local API documentation: https://docs.ollama.com/api/introduction

## Explicit Non-Dependencies

The selected Parakeet release runtime does not bundle Python, `numpy`, the
Python `sherpa-onnx` package, or the retired Python sidecar. They must not appear
in the application bundle or release archive.

## Release Notice Gate

Before distribution, the release owner must verify that the final artifact
contains the exact license and notice payloads for the versions actually
shipped. At minimum this includes sherpa-onnx's Apache 2.0 license, ONNX
Runtime's MIT license and full `ThirdPartyNotices.txt`, GRDB's MIT license, and
the Parakeet attribution/change notice with a CC BY 4.0 link. This repository's
current documentation inventory does not prove that the final artifact already
contains those files.
