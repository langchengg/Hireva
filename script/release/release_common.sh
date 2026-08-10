#!/usr/bin/env bash

# Shared validation helpers for Hireva release scripts. This file is sourced by
# the entry points in this directory and is not intended to be run directly.

RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RELEASE_ENTITLEMENTS_PATH="$RELEASE_SCRIPT_DIR/HirevaRelease.entitlements"

release_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

release_require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        release_die "$name must be set explicitly"
    fi
}

release_validate_mode() {
    release_require_env HIREVA_SIGNING_MODE
    case "$HIREVA_SIGNING_MODE" in
        adhoc|development|developer-id)
            RELEASE_SIGNING_MODE="$HIREVA_SIGNING_MODE"
            ;;
        *)
            release_die "HIREVA_SIGNING_MODE must be one of: adhoc, development, developer-id"
            ;;
    esac
}

release_load_architectures() {
    local raw
    local arch
    local existing

    release_require_env HIREVA_BUILD_ARCHS
    raw="${HIREVA_BUILD_ARCHS//,/ }"
    read -r -a RELEASE_ARCHS <<< "$raw"
    if [[ ${#RELEASE_ARCHS[@]} -eq 0 ]]; then
        release_die "HIREVA_BUILD_ARCHS must contain at least one architecture"
    fi

    for arch in "${RELEASE_ARCHS[@]}"; do
        if [[ ! "$arch" =~ ^[A-Za-z0-9_]+$ ]]; then
            release_die "invalid architecture in HIREVA_BUILD_ARCHS: $arch"
        fi
        for existing in "${RELEASE_SEEN_ARCHS[@]:-}"; do
            if [[ "$arch" == "$existing" ]]; then
                release_die "duplicate architecture in HIREVA_BUILD_ARCHS: $arch"
            fi
        done
        RELEASE_SEEN_ARCHS+=("$arch")
    done
}

release_plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

release_load_app() {
    local requested_path="$1"
    local parent
    local package_type

    if [[ ! -d "$requested_path" ]]; then
        release_die "app bundle does not exist: $requested_path"
    fi
    if [[ -L "$requested_path" ]]; then
        release_die "app bundle must not be a symbolic link: $requested_path"
    fi
    if [[ "$requested_path" != *.app ]]; then
        release_die "expected a .app bundle: $requested_path"
    fi

    parent="$(cd "$(dirname "$requested_path")" && pwd -P)"
    RELEASE_APP_PATH="$parent/$(basename "$requested_path")"
    RELEASE_INFO_PLIST="$RELEASE_APP_PATH/Contents/Info.plist"
    if [[ ! -f "$RELEASE_INFO_PLIST" ]] || ! /usr/bin/plutil -lint "$RELEASE_INFO_PLIST" >/dev/null; then
        release_die "missing or invalid Info.plist: $RELEASE_INFO_PLIST"
    fi

    RELEASE_EXECUTABLE_NAME="$(release_plist_value "$RELEASE_INFO_PLIST" CFBundleExecutable)" || \
        release_die "CFBundleExecutable is missing from $RELEASE_INFO_PLIST"
    case "$RELEASE_EXECUTABLE_NAME" in
        */*|.|..)
            release_die "CFBundleExecutable must be a safe bundle-relative filename"
            ;;
    esac
    RELEASE_BUNDLE_IDENTIFIER="$(release_plist_value "$RELEASE_INFO_PLIST" CFBundleIdentifier)" || \
        release_die "CFBundleIdentifier is missing from $RELEASE_INFO_PLIST"
    RELEASE_PRODUCT_NAME="$(release_plist_value "$RELEASE_INFO_PLIST" CFBundleName)" || \
        release_die "CFBundleName is missing from $RELEASE_INFO_PLIST"
    package_type="$(release_plist_value "$RELEASE_INFO_PLIST" CFBundlePackageType)" || \
        release_die "CFBundlePackageType is missing from $RELEASE_INFO_PLIST"
    if [[ "$package_type" != "APPL" ]]; then
        release_die "CFBundlePackageType must be APPL, found: $package_type"
    fi

    RELEASE_MAIN_EXECUTABLE="$RELEASE_APP_PATH/Contents/MacOS/$RELEASE_EXECUTABLE_NAME"
    if [[ ! -f "$RELEASE_MAIN_EXECUTABLE" ]] || [[ ! -x "$RELEASE_MAIN_EXECUTABLE" ]]; then
        release_die "main executable is missing or not executable: $RELEASE_MAIN_EXECUTABLE"
    fi
    if [[ "$(/usr/bin/file -b "$RELEASE_MAIN_EXECUTABLE")" != *Mach-O* ]]; then
        release_die "main executable is not Mach-O: $RELEASE_MAIN_EXECUTABLE"
    fi
}

release_load_versions() {
    RELEASE_SHORT_VERSION="$(release_plist_value "$RELEASE_INFO_PLIST" CFBundleShortVersionString)" || \
        release_die "CFBundleShortVersionString is missing from $RELEASE_INFO_PLIST"
    RELEASE_BUNDLE_VERSION="$(release_plist_value "$RELEASE_INFO_PLIST" CFBundleVersion)" || \
        release_die "CFBundleVersion is missing from $RELEASE_INFO_PLIST"

    if [[ ! "$RELEASE_PRODUCT_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        release_die "CFBundleName contains characters unsafe for an artifact name: $RELEASE_PRODUCT_NAME"
    fi
    if [[ ! "$RELEASE_SHORT_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
        release_die "CFBundleShortVersionString contains characters unsafe for an artifact name: $RELEASE_SHORT_VERSION"
    fi
    if [[ ! "$RELEASE_BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
        release_die "CFBundleVersion contains characters unsafe for an artifact name: $RELEASE_BUNDLE_VERSION"
    fi
}

release_collect_machos() {
    local candidate
    RELEASE_MACHO_PATHS=()
    while IFS= read -r -d '' candidate; do
        if [[ "$(/usr/bin/file -b "$candidate")" == *Mach-O* ]]; then
            RELEASE_MACHO_PATHS+=("$candidate")
        fi
    done < <(/usr/bin/find "$RELEASE_APP_PATH" -type f -print0)

    if [[ ${#RELEASE_MACHO_PATHS[@]} -eq 0 ]]; then
        release_die "no Mach-O code found in $RELEASE_APP_PATH"
    fi
}

release_validate_architectures() {
    local macho
    local actual
    local expected
    local present
    local actual_arch

    release_collect_machos
    for macho in "${RELEASE_MACHO_PATHS[@]}"; do
        actual="$(/usr/bin/lipo -archs "$macho" 2>/dev/null)" || \
            release_die "unable to inspect architectures for Mach-O file: $macho"
        for expected in "${RELEASE_ARCHS[@]}"; do
            present=0
            for arch in $actual; do
                if [[ "$arch" == "$expected" ]]; then
                    present=1
                    break
                fi
            done
            if [[ "$present" -ne 1 ]]; then
                release_die "Mach-O file is missing required architecture '$expected': $macho (found: $actual)"
            fi
        done
        for actual_arch in $actual; do
            present=0
            for expected in "${RELEASE_ARCHS[@]}"; do
                if [[ "$actual_arch" == "$expected" ]]; then
                    present=1
                    break
                fi
            done
            if [[ "$present" -ne 1 ]]; then
                release_die "Mach-O file has architecture '$actual_arch' outside HIREVA_BUILD_ARCHS: $macho"
            fi
        done
    done
}

release_reject_unstable_metadata() {
    local forbidden_file
    local xattrs

    forbidden_file="$(/usr/bin/find "$RELEASE_APP_PATH" \( -name '._*' -o -name '.DS_Store' \) -print -quit)"
    if [[ -n "$forbidden_file" ]]; then
        release_die "remove AppleDouble/Finder metadata before release signing: $forbidden_file"
    fi

    xattrs="$(/usr/bin/xattr -lr "$RELEASE_APP_PATH" 2>/dev/null || true)"
    if printf '%s\n' "$xattrs" | /usr/bin/grep -Eq 'com\.apple\.(ResourceFork|FinderInfo):'; then
        release_die "remove resource-fork/FinderInfo extended attributes before release signing"
    fi
}

release_validate_identity_for_signing() {
    local requested="${HIREVA_SIGNING_IDENTITY:-}"
    local expected_prefix
    local identity_output
    local line
    local fingerprint
    local label
    local requested_fingerprint

    RELEASE_SIGNING_VALUE=""
    RELEASE_IDENTITY_LABEL=""

    if [[ "$RELEASE_SIGNING_MODE" == "adhoc" ]]; then
        if [[ -n "$requested" ]]; then
            release_die "HIREVA_SIGNING_IDENTITY must be unset when HIREVA_SIGNING_MODE=adhoc"
        fi
        RELEASE_SIGNING_VALUE="-"
        return
    fi

    release_require_env HIREVA_SIGNING_IDENTITY
    case "$RELEASE_SIGNING_MODE" in
        development) expected_prefix="Apple Development:" ;;
        developer-id) expected_prefix="Developer ID Application:" ;;
    esac

    identity_output="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)" || \
        release_die "unable to query code-signing identities from the keychain"
    RELEASE_MATCHING_FINGERPRINTS=()
    RELEASE_MATCHING_LABELS=()
    requested_fingerprint="$(printf '%s' "$requested" | /usr/bin/tr '[:lower:]' '[:upper:]')"

    while IFS= read -r line; do
        fingerprint="$(printf '%s\n' "$line" | /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+".*"$/\1/p')"
        [[ -n "$fingerprint" ]] || continue
        label="${line#*\"}"
        label="${label%\"}"
        if [[ "$requested" == "$label" ]] || [[ "$requested_fingerprint" == "$fingerprint" ]]; then
            RELEASE_MATCHING_FINGERPRINTS+=("$fingerprint")
            RELEASE_MATCHING_LABELS+=("$label")
        fi
    done <<< "$identity_output"

    if [[ ${#RELEASE_MATCHING_FINGERPRINTS[@]} -eq 0 ]]; then
        release_die "HIREVA_SIGNING_IDENTITY is not a valid installed code-signing identity"
    fi
    if [[ ${#RELEASE_MATCHING_FINGERPRINTS[@]} -ne 1 ]]; then
        release_die "HIREVA_SIGNING_IDENTITY is ambiguous; use the certificate SHA-1 fingerprint"
    fi

    RELEASE_IDENTITY_LABEL="${RELEASE_MATCHING_LABELS[0]}"
    if [[ "$RELEASE_IDENTITY_LABEL" != "$expected_prefix"* ]]; then
        release_die "identity class does not match HIREVA_SIGNING_MODE=$RELEASE_SIGNING_MODE; expected $expected_prefix"
    fi
    RELEASE_SIGNING_VALUE="${RELEASE_MATCHING_FINGERPRINTS[0]}"
}

release_collect_nested_bundles() {
    local candidate
    local i
    local j
    local depth_i
    local depth_j
    local swap

    RELEASE_NESTED_BUNDLES=()
    while IFS= read -r -d '' candidate; do
        if [[ "$candidate" != "$RELEASE_APP_PATH" ]] && release_directory_contains_macho "$candidate"; then
            RELEASE_NESTED_BUNDLES+=("$candidate")
        fi
    done < <(/usr/bin/find "$RELEASE_APP_PATH" -type d \( \
        -name '*.app' -o -name '*.framework' -o -name '*.xpc' -o \
        -name '*.appex' -o -name '*.plugin' -o -name '*.bundle' \
    \) -print0)

    for ((i = 0; i < ${#RELEASE_NESTED_BUNDLES[@]}; i++)); do
        for ((j = i + 1; j < ${#RELEASE_NESTED_BUNDLES[@]}; j++)); do
            release_path_depth "${RELEASE_NESTED_BUNDLES[$i]}"
            depth_i="$RELEASE_PATH_DEPTH"
            release_path_depth "${RELEASE_NESTED_BUNDLES[$j]}"
            depth_j="$RELEASE_PATH_DEPTH"
            if (( depth_j > depth_i )); then
                swap="${RELEASE_NESTED_BUNDLES[$i]}"
                RELEASE_NESTED_BUNDLES[$i]="${RELEASE_NESTED_BUNDLES[$j]}"
                RELEASE_NESTED_BUNDLES[$j]="$swap"
            fi
        done
    done
}

release_directory_contains_macho() {
    local directory="$1"
    local candidate

    while IFS= read -r -d '' candidate; do
        if [[ "$(/usr/bin/file -b "$candidate")" == *Mach-O* ]]; then
            return 0
        fi
    done < <(/usr/bin/find "$directory" -type f -print0)
    return 1
}

release_path_depth() {
    local value="$1"
    local depth=0
    while [[ "$value" == */* ]]; do
        value="${value#*/}"
        ((depth += 1))
    done
    RELEASE_PATH_DEPTH="$depth"
}

release_signature_details() {
    /usr/bin/codesign -dv --verbose=4 "$1" 2>&1
}

release_assert_release_entitlements() {
    local app="$1"
    local temporary
    local expected_json
    local actual_json

    temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hireva-entitlements.XXXXXX")" || \
        release_die "unable to create temporary entitlements directory"
    if ! /usr/bin/codesign -d --entitlements :- "$app" > "$temporary/actual.plist" 2>/dev/null; then
        /bin/rm -rf "$temporary"
        release_die "unable to read signed entitlements from $app"
    fi
    if ! /usr/bin/plutil -lint "$temporary/actual.plist" >/dev/null 2>&1; then
        /bin/rm -rf "$temporary"
        release_die "developer-id signature has no readable entitlements"
    fi
    expected_json="$(/usr/bin/plutil -convert json -o - "$RELEASE_ENTITLEMENTS_PATH")"
    actual_json="$(/usr/bin/plutil -convert json -o - "$temporary/actual.plist")"
    /bin/rm -rf "$temporary"
    if [[ "$actual_json" != "$expected_json" ]]; then
        release_die "signed entitlements differ from reviewed release entitlements"
    fi
}

release_assert_signature_mode() {
    local app="$1"
    local details
    local macho
    local macho_details

    if ! /usr/bin/codesign --verify --deep --strict --verbose=4 "$app"; then
        release_die "code signature verification failed: $app"
    fi
    details="$(release_signature_details "$app")" || release_die "unable to inspect signature: $app"

    case "$RELEASE_SIGNING_MODE" in
        adhoc)
            if ! printf '%s\n' "$details" | /usr/bin/grep -q '^Signature=adhoc$'; then
                release_die "signature does not match HIREVA_SIGNING_MODE=adhoc"
            fi
            ;;
        development)
            if ! printf '%s\n' "$details" | /usr/bin/grep -q '^Authority=Apple Development:'; then
                release_die "signature does not match HIREVA_SIGNING_MODE=development"
            fi
            ;;
        developer-id)
            if ! printf '%s\n' "$details" | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
                release_die "signature does not match HIREVA_SIGNING_MODE=developer-id"
            fi
            if ! printf '%s\n' "$details" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)'; then
                release_die "developer-id signature is missing hardened runtime"
            fi
            if ! printf '%s\n' "$details" | /usr/bin/grep -q '^Timestamp='; then
                release_die "developer-id signature is missing a secure timestamp"
            fi
            release_assert_release_entitlements "$app"
            release_collect_machos
            for macho in "${RELEASE_MACHO_PATHS[@]}"; do
                macho_details="$(release_signature_details "$macho")" || \
                    release_die "unable to inspect nested Mach-O signature: $macho"
                if ! printf '%s\n' "$macho_details" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)'; then
                    release_die "nested Mach-O is missing hardened runtime: $macho"
                fi
                if ! printf '%s\n' "$macho_details" | /usr/bin/grep -q '^Timestamp='; then
                    release_die "nested Mach-O is missing a secure timestamp: $macho"
                fi
            done
            ;;
    esac
}

release_prepare_output_root() {
    local requested
    release_require_env HIREVA_RELEASE_OUTPUT_DIR
    requested="$HIREVA_RELEASE_OUTPUT_DIR"
    if [[ -L "$requested" ]]; then
        release_die "HIREVA_RELEASE_OUTPUT_DIR must not be a symbolic link: $requested"
    fi
    if [[ -e "$requested" ]] && [[ ! -d "$requested" ]]; then
        release_die "HIREVA_RELEASE_OUTPUT_DIR is not a directory: $requested"
    fi
    /bin/mkdir -p "$requested"
    RELEASE_OUTPUT_ROOT="$(cd "$requested" && pwd -P)"
}

release_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

release_manifest_value() {
    local manifest="$1"
    local key="$2"
    /usr/bin/plutil -extract "$key" raw -o - "$manifest" 2>/dev/null
}

release_verify_zip_matches_app() {
    local app="$1"
    local zip="$2"
    local temporary
    local extracted_app
    local entry
    local entry_count=0
    local listing

    if [[ -L "$zip" ]]; then
        release_die "ZIP artifact must not be a symbolic link: $zip"
    fi
    listing="$(/usr/bin/unzip -Z1 "$zip")" || release_die "unable to inspect ZIP entries: $zip"
    if [[ -z "$listing" ]]; then
        release_die "ZIP artifact is empty: $zip"
    fi
    while IFS= read -r entry; do
        case "$entry" in
            /*|../*|*/../*|*/..)
                release_die "ZIP contains an unsafe path: $entry"
                ;;
            "$(basename "$app")"|"$(basename "$app")/"|"$(basename "$app")/"*)
                ;;
            *)
                release_die "ZIP contains content outside $(basename "$app"): $entry"
                ;;
        esac
    done <<< "$listing"

    temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hireva-zip-verify.XXXXXX")" || \
        release_die "unable to create ZIP verification directory"
    if ! /usr/bin/ditto -x -k "$zip" "$temporary"; then
        /bin/rm -rf "$temporary"
        release_die "unable to extract ZIP for exact-artifact verification: $zip"
    fi
    while IFS= read -r -d '' entry; do
        entry_count=$((entry_count + 1))
        extracted_app="$entry"
    done < <(/usr/bin/find "$temporary" -mindepth 1 -maxdepth 1 -print0)
    if [[ "$entry_count" -ne 1 ]]; then
        /bin/rm -rf "$temporary"
        release_die "ZIP must contain exactly one top-level app bundle: $zip"
    fi
    if [[ "$(basename "$extracted_app")" != "$(basename "$app")" ]] || [[ ! -d "$extracted_app" ]]; then
        /bin/rm -rf "$temporary"
        release_die "ZIP top-level artifact does not match $(basename "$app")"
    fi
    if ! /usr/bin/diff -qr "$app" "$extracted_app" >/dev/null; then
        /bin/rm -rf "$temporary"
        release_die "ZIP contents do not exactly match the packaged app"
    fi
    if ! /usr/bin/codesign --verify --deep --strict --verbose=4 "$extracted_app"; then
        /bin/rm -rf "$temporary"
        release_die "ZIP-extracted app signature verification failed"
    fi
    /bin/rm -rf "$temporary"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'error: release_common.sh must be sourced by a release entry point\n' >&2
    exit 2
fi
