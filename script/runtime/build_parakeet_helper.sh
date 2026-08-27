#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=runtime_contract.sh
source "$ROOT_DIR/script/runtime/runtime_contract.sh"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/parakeet-helper}"
SDK_ROOT="$("$ROOT_DIR/script/runtime/prepare_sherpa_runtime.sh")"
SOURCE="$ROOT_DIR/native/parakeet_asr_helper.mm"
HELPERS="$OUTPUT_DIR/Helpers"
HELPER="$HELPERS/parakeet_asr_helper"
FRAMEWORKS="$OUTPUT_DIR/Frameworks"
RUNTIME_PROVENANCE="$OUTPUT_DIR/RuntimeProvenance.plist"
PAYLOAD_HASH_SCRIPT="$ROOT_DIR/script/runtime/macho_payload_sha256.sh"
PATH_SANITIZER="$ROOT_DIR/script/runtime/sanitize_runtime_paths.sh"

mkdir -p "$HELPERS" "$FRAMEWORKS"

xcrun clang++ \
    -std=c++17 \
    -fobjc-arc \
    -O2 \
    -mmacosx-version-min=14.0 \
    -arch arm64 \
    -I "$SDK_ROOT/include" \
    "$SOURCE" \
    -L "$SDK_ROOT/lib" \
    -lsherpa-onnx-c-api \
    -framework Foundation \
    -Wl,-rpath,@executable_path/../Frameworks \
    -o "$HELPER"

cp "$SDK_ROOT/lib/libsherpa-onnx-c-api.dylib" "$FRAMEWORKS/"
cp "$SDK_ROOT/lib/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib" "$FRAMEWORKS/"

SHERPA_SOURCE_SHA256="$(/usr/bin/shasum -a 256 "$SDK_ROOT/lib/libsherpa-onnx-c-api.dylib" | /usr/bin/awk '{print $1}')"
ONNX_SOURCE_SHA256="$(/usr/bin/shasum -a 256 "$SDK_ROOT/lib/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib" | /usr/bin/awk '{print $1}')"
[[ "$SHERPA_SOURCE_SHA256" == "$HIREVA_SHERPA_LIBRARY_SOURCE_SHA256" ]] || {
    printf 'error: sherpa source library changed after verification\n' >&2
    exit 1
}
[[ "$ONNX_SOURCE_SHA256" == "$HIREVA_ONNX_LIBRARY_SOURCE_SHA256" ]] || {
    printf 'error: ONNX source library changed after verification\n' >&2
    exit 1
}

"$PATH_SANITIZER" "$FRAMEWORKS/libsherpa-onnx-c-api.dylib" \
    "$HIREVA_SHERPA_SOURCE_PATH_REPLACEMENT_COUNT" >/dev/null
"$PATH_SANITIZER" "$FRAMEWORKS/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib" \
    "$HIREVA_ONNX_SOURCE_PATH_REPLACEMENT_COUNT" >/dev/null
/usr/bin/strip -S -x "$FRAMEWORKS/libsherpa-onnx-c-api.dylib"
/usr/bin/strip -S -x "$FRAMEWORKS/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib"

SHERPA_PAYLOAD_SHA256="$("$PAYLOAD_HASH_SCRIPT" "$FRAMEWORKS/libsherpa-onnx-c-api.dylib")"
ONNX_PAYLOAD_SHA256="$("$PAYLOAD_HASH_SCRIPT" "$FRAMEWORKS/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib")"

/usr/bin/plutil -create xml1 "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert schema_version -integer 2 "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert source_verification -string \
    "pinned-full-file-sha256-before-reviewed-path-sanitization-and-bundle-signing" \
    "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert payload_hash_algorithm -string \
    "$HIREVA_RUNTIME_PAYLOAD_HASH_ALGORITHM" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert binary_transform_identifier -string \
    "$HIREVA_RUNTIME_BINARY_TRANSFORM_IDENTIFIER" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert path_sanitization_identifier -string \
    "$HIREVA_RUNTIME_PATH_SANITIZATION_IDENTIFIER" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert source_archive_sha256 -string \
    "$HIREVA_SHERPA_RUNTIME_ARCHIVE_SHA256" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert sherpa_onnx -json '{}' "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert sherpa_onnx.version -string \
    "$HIREVA_SHERPA_ONNX_VERSION" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert sherpa_onnx.source_library_sha256 -string \
    "$SHERPA_SOURCE_SHA256" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert sherpa_onnx.source_path_replacement_count -integer \
    "$HIREVA_SHERPA_SOURCE_PATH_REPLACEMENT_COUNT" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert sherpa_onnx.macho_payload_sha256 -string \
    "$SHERPA_PAYLOAD_SHA256" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert onnx_runtime -json '{}' "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert onnx_runtime.version -string \
    "$HIREVA_ONNX_RUNTIME_VERSION" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert onnx_runtime.source_library_sha256 -string \
    "$ONNX_SOURCE_SHA256" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert onnx_runtime.source_path_replacement_count -integer \
    "$HIREVA_ONNX_SOURCE_PATH_REPLACEMENT_COUNT" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -insert onnx_runtime.macho_payload_sha256 -string \
    "$ONNX_PAYLOAD_SHA256" "$RUNTIME_PROVENANCE"
/usr/bin/plutil -lint "$RUNTIME_PROVENANCE" >/dev/null

chmod 0755 "$HELPER"
xattr -cr "$OUTPUT_DIR" 2>/dev/null || true
codesign --force --sign - "$FRAMEWORKS/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib"
codesign --force --sign - "$FRAMEWORKS/libsherpa-onnx-c-api.dylib"
codesign --force --sign - "$HELPER"
[[ "$("$PAYLOAD_HASH_SCRIPT" "$FRAMEWORKS/libsherpa-onnx-c-api.dylib")" == "$SHERPA_PAYLOAD_SHA256" ]] || {
    printf 'error: sherpa Mach-O payload changed during signing\n' >&2
    exit 1
}
[[ "$("$PAYLOAD_HASH_SCRIPT" "$FRAMEWORKS/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib")" == "$ONNX_PAYLOAD_SHA256" ]] || {
    printf 'error: ONNX Mach-O payload changed during signing\n' >&2
    exit 1
}
file "$HELPER" | grep -q 'arm64'
otool -L "$HELPER" | grep -q '@rpath/libsherpa-onnx-c-api.dylib'
codesign --verify --strict --verbose=2 "$HELPER"

printf '%s\n' "$OUTPUT_DIR"
