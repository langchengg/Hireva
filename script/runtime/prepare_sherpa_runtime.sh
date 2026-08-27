#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=runtime_contract.sh
source "$ROOT_DIR/script/runtime/runtime_contract.sh"
VERSION="$HIREVA_SHERPA_ONNX_VERSION"
ARCH="${HIREVA_RUNTIME_ARCH:-arm64}"
CACHE_ROOT="${HIREVA_RUNTIME_CACHE_DIR:-$ROOT_DIR/.build/runtime}"
RUNTIME_NAME="sherpa-onnx-v${VERSION}-osx-${ARCH}-shared-no-tts-lib"
ARCHIVE_NAME="${RUNTIME_NAME}.tar.bz2"
ARCHIVE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${ARCHIVE_NAME}"
ARCHIVE_SHA256="$HIREVA_SHERPA_RUNTIME_ARCHIVE_SHA256"
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${VERSION}/sherpa-onnx/c-api/c-api.h"
HEADER_SHA256="587e1039cc4ee242169494f3c0ba5baecc22482341168d88d57db965e1e77fa9"
SHERPA_LIBRARY_SHA256="$HIREVA_SHERPA_LIBRARY_SOURCE_SHA256"
ONNX_RUNTIME_LIBRARY_SHA256="$HIREVA_ONNX_LIBRARY_SOURCE_SHA256"
SDK_ROOT="$CACHE_ROOT/$RUNTIME_NAME"
ARCHIVE_PATH="$CACHE_ROOT/$ARCHIVE_NAME"
HEADER_PATH="$SDK_ROOT/include/sherpa-onnx/c-api/c-api.h"

if [[ "$ARCH" != "arm64" ]]; then
    echo "[runtime] ERROR: Hireva currently packages only the audited arm64 sherpa-onnx runtime." >&2
    exit 2
fi

verify_sha256() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "[runtime] ERROR: SHA-256 mismatch for $path" >&2
        echo "[runtime] Expected: $expected" >&2
        echo "[runtime] Actual:   $actual" >&2
        return 1
    fi
}

download_verified() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    local temporary="${destination}.partial.$$"

    if [[ -f "$destination" ]] && verify_sha256 "$destination" "$expected"; then
        return 0
    fi
    rm -f "$temporary"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 \
        "$url" -o "$temporary"
    verify_sha256 "$temporary" "$expected"
    mv -f "$temporary" "$destination"
}

mkdir -p "$CACHE_ROOT"
download_verified "$ARCHIVE_URL" "$ARCHIVE_PATH" "$ARCHIVE_SHA256"

if [[ ! -f "$SDK_ROOT/lib/libsherpa-onnx-c-api.dylib" || \
      ! -f "$SDK_ROOT/lib/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib" ]] || \
      ! verify_sha256 "$SDK_ROOT/lib/libsherpa-onnx-c-api.dylib" "$SHERPA_LIBRARY_SHA256" || \
      ! verify_sha256 "$SDK_ROOT/lib/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib" "$ONNX_RUNTIME_LIBRARY_SHA256"; then
    staging="${SDK_ROOT}.staging.$$"
    rm -rf "$staging"
    mkdir -p "$staging"

    while IFS= read -r entry; do
        normalized="${entry#./}"
        if [[ "$normalized" == /* || "$normalized" == ../* || "$normalized" == *'/../'* ]]; then
            echo "[runtime] ERROR: unsafe archive entry: $entry" >&2
            rm -rf "$staging"
            exit 1
        fi
    done < <(tar -tjf "$ARCHIVE_PATH")

    tar -xjf "$ARCHIVE_PATH" -C "$staging"
    extracted="$staging/$RUNTIME_NAME"
    if [[ ! -f "$extracted/lib/libsherpa-onnx-c-api.dylib" || \
          ! -f "$extracted/lib/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib" ]]; then
        echo "[runtime] ERROR: verified archive is missing required libraries." >&2
        rm -rf "$staging"
        exit 1
    fi
    if ! verify_sha256 "$extracted/lib/libsherpa-onnx-c-api.dylib" "$SHERPA_LIBRARY_SHA256" || \
       ! verify_sha256 "$extracted/lib/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib" "$ONNX_RUNTIME_LIBRARY_SHA256"; then
        echo "[runtime] ERROR: verified archive contains an unexpected runtime payload." >&2
        rm -rf "$staging"
        exit 1
    fi
    rm -rf "$SDK_ROOT"
    mv "$extracted" "$SDK_ROOT"
    rm -rf "$staging"
fi

mkdir -p "$(dirname "$HEADER_PATH")"
download_verified "$HEADER_URL" "$HEADER_PATH" "$HEADER_SHA256"

for library in \
    "$SDK_ROOT/lib/libsherpa-onnx-c-api.dylib" \
    "$SDK_ROOT/lib/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib"; do
    if ! file "$library" | grep -q 'arm64'; then
        echo "[runtime] ERROR: unexpected architecture for $library" >&2
        exit 1
    fi
done

verify_sha256 "$SDK_ROOT/lib/libsherpa-onnx-c-api.dylib" "$SHERPA_LIBRARY_SHA256"
verify_sha256 "$SDK_ROOT/lib/libonnxruntime.$HIREVA_ONNX_RUNTIME_VERSION.dylib" "$ONNX_RUNTIME_LIBRARY_SHA256"
verify_sha256 "$HEADER_PATH" "$HEADER_SHA256"

printf '%s\n' "$SDK_ROOT"
