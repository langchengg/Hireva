#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="${HIREVA_NOTICE_CACHE_DIR:-$ROOT_DIR/.build/third-party-notices}"

download_verified() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    local temporary="${destination}.partial.$$"
    local actual=""

    if [[ -f "$destination" ]]; then
        actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
        if [[ "$actual" == "$expected" ]]; then
            return 0
        fi
    fi

    rm -f "$temporary"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 \
        "$url" -o "$temporary"
    actual="$(shasum -a 256 "$temporary" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$temporary"
        echo "[notices] ERROR: SHA-256 mismatch for $url" >&2
        exit 1
    fi
    mv -f "$temporary" "$destination"
}

mkdir -p "$CACHE_DIR"
download_verified \
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.4/LICENSE" \
    "$CACHE_DIR/sherpa-onnx-LICENSE.txt" \
    "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
download_verified \
    "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.0/LICENSE" \
    "$CACHE_DIR/onnxruntime-LICENSE.txt" \
    "2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c"
download_verified \
    "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.0/ThirdPartyNotices.txt" \
    "$CACHE_DIR/onnxruntime-ThirdPartyNotices.txt" \
    "0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2"
download_verified \
    "https://raw.githubusercontent.com/groue/GRDB.swift/v6.29.3/LICENSE" \
    "$CACHE_DIR/GRDB-LICENSE.txt" \
    "b9ce5b40c859a62fa6998995a9d284565aba72e92ca7c655f64777948f885139"

printf '%s\n' "$CACHE_DIR"
