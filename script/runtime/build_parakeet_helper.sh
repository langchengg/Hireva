#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/parakeet-helper}"
SDK_ROOT="$("$ROOT_DIR/script/runtime/prepare_sherpa_runtime.sh")"
SOURCE="$ROOT_DIR/native/parakeet_asr_helper.mm"
HELPERS="$OUTPUT_DIR/Helpers"
HELPER="$HELPERS/parakeet_asr_helper"
FRAMEWORKS="$OUTPUT_DIR/Frameworks"

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
cp "$SDK_ROOT/lib/libonnxruntime.1.27.0.dylib" "$FRAMEWORKS/"

chmod 0755 "$HELPER"
xattr -cr "$OUTPUT_DIR" 2>/dev/null || true
codesign --force --sign - "$FRAMEWORKS/libonnxruntime.1.27.0.dylib"
codesign --force --sign - "$FRAMEWORKS/libsherpa-onnx-c-api.dylib"
codesign --force --sign - "$HELPER"
file "$HELPER" | grep -q 'arm64'
otool -L "$HELPER" | grep -q '@rpath/libsherpa-onnx-c-api.dylib'
codesign --verify --strict --verbose=2 "$HELPER"

printf '%s\n' "$OUTPUT_DIR"
