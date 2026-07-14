#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="1.13.4"
ARCH="${HIREVA_RUNTIME_ARCH:-arm64}"
CACHE_ROOT="${HIREVA_RUNTIME_CACHE_DIR:-$ROOT_DIR/.build/runtime}"
RUNTIME_NAME="sherpa-onnx-v${VERSION}-osx-${ARCH}-shared-no-tts-lib"
ARCHIVE_NAME="${RUNTIME_NAME}.tar.bz2"
ARCHIVE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${ARCHIVE_NAME}"
ARCHIVE_SHA256="c003242369046d3c2adc6b48c3c96e0ff129e76738b7f3aa5342828ec8ba410d"
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${VERSION}/sherpa-onnx/c-api/c-api.h"
HEADER_SHA256="587e1039cc4ee242169494f3c0ba5baecc22482341168d88d57db965e1e77fa9"
SHERPA_LIBRARY_SHA256="08caf3346b82648540c8c9b738ee10b06e728a5ea525184230b25321ec57f047"
ONNX_RUNTIME_LIBRARY_SHA256="8e822d761fac13e47c6725baf1e65d9858ea00bf0af3e61a43b7c6a65a794439"
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
      ! -f "$SDK_ROOT/lib/libonnxruntime.1.27.0.dylib" ]] || \
      ! verify_sha256 "$SDK_ROOT/lib/libsherpa-onnx-c-api.dylib" "$SHERPA_LIBRARY_SHA256" || \
      ! verify_sha256 "$SDK_ROOT/lib/libonnxruntime.1.27.0.dylib" "$ONNX_RUNTIME_LIBRARY_SHA256"; then
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
          ! -f "$extracted/lib/libonnxruntime.1.27.0.dylib" ]]; then
        echo "[runtime] ERROR: verified archive is missing required libraries." >&2
        rm -rf "$staging"
        exit 1
    fi
    if ! verify_sha256 "$extracted/lib/libsherpa-onnx-c-api.dylib" "$SHERPA_LIBRARY_SHA256" || \
       ! verify_sha256 "$extracted/lib/libonnxruntime.1.27.0.dylib" "$ONNX_RUNTIME_LIBRARY_SHA256"; then
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
    "$SDK_ROOT/lib/libonnxruntime.1.27.0.dylib"; do
    if ! file "$library" | grep -q 'arm64'; then
        echo "[runtime] ERROR: unexpected architecture for $library" >&2
        exit 1
    fi
done

verify_sha256 "$SDK_ROOT/lib/libsherpa-onnx-c-api.dylib" "$SHERPA_LIBRARY_SHA256"
verify_sha256 "$SDK_ROOT/lib/libonnxruntime.1.27.0.dylib" "$ONNX_RUNTIME_LIBRARY_SHA256"
verify_sha256 "$HEADER_PATH" "$HEADER_SHA256"

printf '%s\n' "$SDK_ROOT"
