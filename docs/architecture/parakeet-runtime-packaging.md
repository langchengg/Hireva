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
   SHA-256 values. License and notice texts are vendored separately under
   `Resources/ThirdPartyNotices`; their four upstream SHA-256 values are checked
   before bundling, so notice assembly is not network- or cache-dependent.
4. Before signing, the two vendor dylibs receive an equal-length, exact-count
   replacement of the vendor CI source prefix and are stripped with
   `strip -S -x`. The reviewed replacement counts are 214 for sherpa-onnx and
   584 for ONNX Runtime; any count drift fails the build.
5. `clang++` builds the Objective-C++ helper for `arm64` with an `@rpath`
   dependency on `libsherpa-onnx-c-api.dylib`.
6. The SwiftPM release executable receives a separate equal-length replacement
   of its deterministic temporary build prefix, so dependency diagnostics do
   not retain the host build directory.
7. The build copies and signs the helper and dylibs inside-out before signing
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

`script/release/package_release.sh --validate-only` is the shared artifact
contract. `scripts/package_dmg.sh` accepts an already signed app plus a new,
nonexistent output directory; it does not build or launch. The DMG path emits
an adjacent JSON manifest containing app/DMG hashes, build identity, runtime
hashes and pinned provenance, and the Parakeet descriptor/archive identity.

The runtime records deliberately separate three non-interchangeable hashes:

| Field | Bytes covered | Purpose |
| --- | --- | --- |
| `source_library_sha256` | Complete vendor dylib before any local transformation | Binds the input to the pinned upstream archive |
| `macho_payload_sha256` | Canonical, post-sanitization and post-strip Mach-O payload, excluding the mutable code-signature allocation | Proves the reviewed executable payload survives signing or re-signing |
| `signed_artifact_sha256` | Complete final signed dylib | Binds a particular packaged artifact, including its signature bytes |

`source_archive_sha256` separately binds the downloaded vendor archive. The
canonical payload algorithm is identified as
`hireva-thin-arm64-macho-canonical-sha256-v1`. Its repository-owned parser
accepts only a regular, non-symlink, thin `arm64` Mach-O no larger than 64 MiB;
it bounds load-command, section, and code-signature entry counts and validates
segment/section ranges, `__LINKEDIT` page sizing, and the embedded-signature
SuperBlob. It removes `LC_CODE_SIGNATURE` and its final allocation, rewrites the
canonical header command counts, and normalizes `__LINKEDIT` file/virtual sizes
before hashing the canonical header, commands, zero padding, and retained
file-backed payload. Signature bytes, signer identity, timestamp, and unused
signature allocation therefore cannot change the payload hash, while any
retained code or data change does.

The DMG app-content hash uses the manifest algorithm identifier
`sha256-v1-of-lowercase-file-sha256-hex-tab-relative-path-nul-in-lc-all-c-find-s-order`.
For each regular app file in `LC_ALL=C find -s` order, it serializes lowercase
file SHA-256 hex, one tab, the app-relative path, and one NUL byte, then hashes
the concatenated stream. The mounted read-only image must reproduce that value.

Release validation rejects absolute user paths, development path keys, and
Mach-O load commands outside the reviewed system and bundled-runtime allowlist.
The completed image is mounted read-only and non-browsing, the mounted app is
revalidated, and its deterministic content hash must match the staged app before
the image is accepted. Developer ID input requires an explicit expected
10-character Team ID, an explicitly installed Developer ID Application identity,
and explicit distribution-DMG authorization. In that mode only, the completed
DMG is signed with the selected identity and its strict signature, authority,
TeamIdentifier, and secure timestamp are verified before hashing. The packaging
script itself never notarizes, staples, or publishes.

`script/release/notarize_release.sh` consumes the resulting immutable DMG and
manifest. It verifies the upload hash, size, UDIF integrity, Developer ID
signature, TeamIdentifier, and timestamp before `notarytool` access. A Keychain
profile is insufficient by itself: the operator must also set the separate
notarization-submit authorization. After an `Accepted` result, the original
upload remains unchanged while a private copy is stapled, validated, assessed
by Gatekeeper as a disk image, and published as a separate `.notarized.dmg` with
its checksum and schema-3 manifest. The response, Apple log, and upload/final
hashes are retained without serializing identity, Team ID, profile, or
credential values into either manifest.

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
