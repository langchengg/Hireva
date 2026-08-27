#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXCLUSIVE_RENAME="$SCRIPT_DIR/exclusive_rename.rb"
# shellcheck source=release_common.sh
source "$SCRIPT_DIR/release_common.sh"
# shellcheck source=../runtime/runtime_contract.sh
source "$SCRIPT_DIR/../runtime/runtime_contract.sh"

HIREVA_PRIVACY_CANONICAL_SHA256="e1c8ede592cf5964604c1187ef80a0217f40cf26a892284b09314cf1056175dd"
GRDB_PRIVACY_CANONICAL_SHA256="ed769c4f27a3ab6474a1fe0e12174745ea1c61c1e601103947445986219f3e1c"
GRDB_INFO_CANONICAL_SHA256="5170cc1d33fe7c6c1d9f073acc2a98509fb275ec219e9aea4c119eda284fad95"
HIREVA_APP_ICON_SHA256="4944629fa431d7c066e9909ef3baefe6c7c8ed1ff4017c8d7b13ca6e504e122f"

usage() {
    cat <<'USAGE'
Usage: package_release.sh [--validate-only] /path/to/signed/Hireva.app

Required environment:
  HIREVA_SIGNING_MODE        adhoc, development, or developer-id
  HIREVA_BUILD_ARCHS         Required architectures, comma or space separated
  HIREVA_RELEASE_OUTPUT_DIR  Existing parent directory for the versioned artifact directory;
                             not required with --validate-only
  HIREVA_EXPECTED_TEAM_IDENTIFIER
                             Explicit 10-character Apple Team ID in developer-id mode

Creates an app copy, ZIP, SHA-256 checksum, and JSON version manifest. Existing
artifact directories are never overwritten. Signing identities, notary profile
names, credentials, and source filesystem paths are never written to metadata.
--validate-only runs the same bundle, runtime, linkage, architecture, and
signature contract without creating an artifact.
USAGE
}

require_exact_directory_entries() {
    local directory="$1"
    local label="$2"
    shift 2
    local entry
    local name
    local expected
    local allowed

    [[ -d "$directory" && ! -L "$directory" ]] || \
        release_die "required $label directory is missing: ${directory#"$RELEASE_APP_PATH/"}"
    while IFS= read -r -d '' entry; do
        name="$(basename "$entry")"
        allowed=0
        for expected in "$@"; do
            if [[ "$name" == "$expected" ]]; then
                allowed=1
                break
            fi
        done
        [[ "$allowed" -eq 1 ]] || \
            release_die "unexpected $label payload: ${entry#"$RELEASE_APP_PATH/"}"
    done < <(/usr/bin/find "$directory" -mindepth 1 -maxdepth 1 -print0)

    for expected in "$@"; do
        [[ -e "$directory/$expected" || -L "$directory/$expected" ]] || \
            release_die "required $label payload is missing: ${directory#"$RELEASE_APP_PATH/"}/$expected"
    done
}

validate_hireva_release_contract() {
    local app="$RELEASE_APP_PATH"
    local helper="$app/Contents/Helpers/parakeet_asr_helper"
    local sherpa="$app/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
    local onnx="$app/Contents/Frameworks/libonnxruntime.1.27.0.dylib"
    local privacy_manifest="$app/Contents/Resources/PrivacyInfo.xcprivacy"
    local runtime_provenance="$app/Contents/Resources/RuntimeProvenance.plist"
    local grdb_bundle="$app/Contents/Resources/GRDB_GRDB.bundle"
    local grdb_privacy_manifest="$grdb_bundle/PrivacyInfo.xcprivacy"
    local source_commit
    local runtime_mode
    local embedded_mode
    local tree_state
    local distribution_build
    local build_configuration
    local actual_arches
    local forbidden
    local forbidden_source
    local required
    local required_macho
    local unexpected
    local unexpected_bundle
    local unexpected_root

    [[ "$RELEASE_PRODUCT_NAME" == "Hireva" ]] || release_die "CFBundleName must be Hireva"
    [[ "$RELEASE_EXECUTABLE_NAME" == "Hireva" ]] || release_die "CFBundleExecutable must be Hireva"
    [[ "$(basename "$RELEASE_APP_PATH")" == "Hireva.app" ]] || \
        release_die "release app bundle filename must be Hireva.app"
    [[ "$RELEASE_BUNDLE_IDENTIFIER" == "com.langcheng.Hireva" ]] || \
        release_die "CFBundleIdentifier must be com.langcheng.Hireva"
    [[ "$(release_plist_value "$RELEASE_INFO_PLIST" LSMinimumSystemVersion || true)" == "14.0" ]] || \
        release_die "LSMinimumSystemVersion must be the reviewed value 14.0"
    [[ "$(release_plist_value "$RELEASE_INFO_PLIST" NSMicrophoneUsageDescription || true)" == \
        "Hireva uses the microphone to transcribe interview audio in real time." ]] || \
        release_die "NSMicrophoneUsageDescription differs from the reviewed release text"
    [[ "$(release_plist_value "$RELEASE_INFO_PLIST" NSSpeechRecognitionUsageDescription || true)" == \
        "Hireva uses Apple Speech to transcribe selected interview audio. Depending on macOS and locale, processing may occur on Apple servers." ]] || \
        release_die "NSSpeechRecognitionUsageDescription differs from the reviewed release text"
    [[ "$(release_plist_value "$RELEASE_INFO_PLIST" NSScreenCaptureUsageDescription || true)" == \
        "Hireva captures system audio to detect interviewer questions automatically." ]] || \
        release_die "NSScreenCaptureUsageDescription differs from the reviewed release text"
    [[ "$(release_plist_value "$RELEASE_INFO_PLIST" NSAudioCaptureUsageDescription || true)" == \
        "Hireva captures system audio for real-time interviewer question detection." ]] || \
        release_die "NSAudioCaptureUsageDescription differs from the reviewed release text"
    if [[ ${#RELEASE_ARCHS[@]} -ne 1 || "${RELEASE_ARCHS[0]}" != "arm64" ]]; then
        release_die "Hireva release packaging requires exactly HIREVA_BUILD_ARCHS=arm64"
    fi

    runtime_mode="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaRuntimeMode || true)"
    embedded_mode="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaSigningMode || true)"
    tree_state="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitTreeState || true)"
    distribution_build="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaDistributionBuild || true)"
    build_configuration="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaBuildConfiguration || true)"
    source_commit="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitCommitHash || true)"
    [[ "$runtime_mode" == "bundled_native" ]] || release_die "HirevaRuntimeMode must be bundled_native"
    [[ "$embedded_mode" == "$RELEASE_SIGNING_MODE" ]] || \
        release_die "embedded signing mode does not match HIREVA_SIGNING_MODE"
    [[ "$build_configuration" == "release" ]] || \
        release_die "HirevaBuildConfiguration must be release"
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || \
        release_die "HirevaGitCommitHash must be a full lowercase Git object ID"
    if release_plist_value "$RELEASE_INFO_PLIST" HirevaSourceRoot >/dev/null || \
       release_plist_value "$RELEASE_INFO_PLIST" HirevaExpectedBundlePath >/dev/null; then
        release_die "release app must not embed development source or bundle paths"
    fi
    case "$tree_state" in
        clean|dirty) ;;
        *) release_die "HirevaGitTreeState must explicitly be clean or dirty" ;;
    esac
    if [[ "$RELEASE_SIGNING_MODE" == "developer-id" ]]; then
        [[ "$tree_state" == "clean" ]] || release_die "developer-id packaging requires a clean source tree"
        [[ "$distribution_build" == "true" ]] || release_die "developer-id app is not marked as a distribution build"
    else
        [[ "$distribution_build" == "false" ]] || release_die "non-distribution signing mode has distribution metadata"
    fi
    validate_hireva_info_plist_contract "$distribution_build"

    forbidden="$(/usr/bin/find "$app" \( \
        -type l -o \
        -type d \( -iname '__pycache__' -o -iname 'site-packages' -o \
            -iname 'numpy' -o -iname 'LocalModels' -o -iname 'Models' -o \
            -iname 'test_wavs' -o -name '.git' -o -name '.build' \) -o \
        -type f \( -iname '*.py' -o -iname '*.pyc' -o -iname '*.pyo' -o \
            -iname 'python' -o -iname 'python[0-9]*' -o -iname 'libpython*' -o \
            -iname '*.onnx' -o -iname '*.ort' -o -iname '*.bin' -o \
            -iname '*.gguf' -o -iname '*.ggml' -o -iname '*.safetensors' -o \
            -iname '*.pt' -o -iname '*.pth' -o -iname '*.mlmodel' -o \
            -iname 'tokens.txt' -o -iname '*.sqlite' -o -iname '*.sqlite3' -o \
            -iname '*.sqlite-*' -o -iname '*.db' -o -iname '*.db-*' -o \
            -iname '*-wal' -o -iname '*-shm' -o -iname '*.wav' -o \
            -iname '*.jsonl' -o -iname '*.trace' -o -iname '*.trace.*' -o \
            -iname '*.log' -o -iname '*.zip' -o -iname '*.dmg' -o \
            -iname '*.tar' -o -iname '*.tar.*' -o -iname '*.bz2' -o \
            -iname '.env' -o -iname '.env.*' -o -iname '*.pem' -o \
            -iname '*.p12' -o -iname '*.key' -o -iname 'auth.json' -o \
            -iname 'credentials.json' -o -iname 'secrets.*' -o \
            -name '.DS_Store' -o -name '._*' \) \
    \) -print -quit)"
    [[ -z "$forbidden" ]] || release_die "forbidden private/runtime payload in app: ${forbidden#"$app/"}"

    forbidden_source=""
    while IFS= read -r -d '' required; do
        if LC_ALL=C /usr/bin/grep -a -Eq \
            '/Users/|/Volumes/|/home/|/private/tmp/hireva-swiftpm-release-' "$required" 2>/dev/null; then
            forbidden_source="$required"
            break
        fi
    done < <(/usr/bin/find "$app" -type f -print0)
    [[ -z "$forbidden_source" ]] || \
        release_die "absolute user path leaked into release app: ${forbidden_source#"$app/"}"

    for required in \
        "$helper" \
        "$sherpa" \
        "$onnx" \
        "$privacy_manifest" \
        "$runtime_provenance" \
        "$grdb_bundle/Info.plist" \
        "$grdb_privacy_manifest" \
        "$app/Contents/Resources/Documentation/release-installation.md" \
        "$app/Contents/Resources/Documentation/local-model-installation.md" \
        "$app/Contents/Resources/Documentation/privacy-and-data-flow.md" \
        "$app/Contents/Resources/Documentation/third-party-licenses.md" \
        "$app/Contents/Resources/Documentation/release-notes-0.1.0.md" \
        "$app/Contents/Resources/ThirdPartyNotices/sherpa-onnx-LICENSE.txt" \
        "$app/Contents/Resources/ThirdPartyNotices/onnxruntime-LICENSE.txt" \
        "$app/Contents/Resources/ThirdPartyNotices/onnxruntime-ThirdPartyNotices.txt" \
        "$app/Contents/Resources/ThirdPartyNotices/GRDB-LICENSE.txt"; do
        [[ -s "$required" ]] || release_die "required Hireva payload is missing or empty: ${required#"$app/"}"
    done
    [[ "$(release_sha256 "$app/Contents/Resources/AppIcon.icns")" == "$HIREVA_APP_ICON_SHA256" ]] || \
        release_die "AppIcon.icns differs from the reviewed release asset"
    [[ "$(release_sha256 "$app/Contents/Resources/Documentation/release-installation.md")" == \
        "d183e6ecac84b77cc62d319a46540f4ffe443738563ca9a64a665549424027a6" ]] || \
        release_die "release-installation.md differs from the reviewed release document"
    [[ "$(release_sha256 "$app/Contents/Resources/Documentation/local-model-installation.md")" == \
        "d2abda1b22fd0560034e9dbe5c57feac512c4ea5b24661a0e776ed940f3898b7" ]] || \
        release_die "local-model-installation.md differs from the reviewed release document"
    [[ "$(release_sha256 "$app/Contents/Resources/Documentation/privacy-and-data-flow.md")" == \
        "b541bad551c5cd600450d9abb6ddc005a135d58a2fae5f0c651725e7be2274e3" ]] || \
        release_die "privacy-and-data-flow.md differs from the reviewed release document"
    [[ "$(release_sha256 "$app/Contents/Resources/Documentation/third-party-licenses.md")" == \
        "fe0d2c755612e38125a4be7eef9fc651b6c1e78b0ac142087d40bdfb7e729097" ]] || \
        release_die "third-party-licenses.md differs from the reviewed release document"
    [[ "$(release_sha256 "$app/Contents/Resources/Documentation/release-notes-0.1.0.md")" == \
        "50f440756a22920841da530fbed93915c5097fa0fbf2de5a72894ddf0ae8a96c" ]] || \
        release_die "release-notes-0.1.0.md differs from the reviewed release document"
    [[ "$(release_sha256 "$app/Contents/Resources/ThirdPartyNotices/sherpa-onnx-LICENSE.txt")" == \
        "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30" ]] || \
        release_die "sherpa-onnx license differs from the pinned upstream notice"
    [[ "$(release_sha256 "$app/Contents/Resources/ThirdPartyNotices/onnxruntime-LICENSE.txt")" == \
        "2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c" ]] || \
        release_die "ONNX Runtime license differs from the pinned upstream notice"
    [[ "$(release_sha256 "$app/Contents/Resources/ThirdPartyNotices/onnxruntime-ThirdPartyNotices.txt")" == \
        "0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2" ]] || \
        release_die "ONNX Runtime third-party notices differ from the pinned upstream notice"
    [[ "$(release_sha256 "$app/Contents/Resources/ThirdPartyNotices/GRDB-LICENSE.txt")" == \
        "b9ce5b40c859a62fa6998995a9d284565aba72e92ca7c655f64777948f885139" ]] || \
        release_die "GRDB license differs from the pinned upstream notice"
    validate_hireva_privacy_manifest "$privacy_manifest"
    [[ "$(canonical_plist_sha256 "$grdb_bundle/Info.plist")" == "$GRDB_INFO_CANONICAL_SHA256" ]] || \
        release_die "GRDB Info.plist differs from the pinned dependency metadata"
    validate_grdb_privacy_manifest "$grdb_privacy_manifest"
    validate_runtime_provenance_manifest "$runtime_provenance" "$sherpa" "$onnx"
    [[ -x "$helper" ]] || release_die "bundled Parakeet helper is not executable"
    if /usr/bin/strings -a "$RELEASE_MAIN_EXECUTABLE" | \
       /usr/bin/grep -F 'GRDB_GRDB.bundle' >/dev/null; then
        release_die "linked code uses GRDB's incompatible app-root SwiftPM resource lookup"
    fi
    [[ "$(/usr/bin/file -b "$helper")" == *Mach-O* ]] || release_die "bundled Parakeet helper is not Mach-O"
    [[ "$(/usr/bin/file -b "$sherpa")" == *"dynamically linked shared library"* ]] || \
        release_die "bundled sherpa runtime is not a dynamic library"
    [[ "$(/usr/bin/file -b "$onnx")" == *"dynamically linked shared library"* ]] || \
        release_die "bundled ONNX runtime is not a dynamic library"

    for required_macho in "$RELEASE_MAIN_EXECUTABLE" "$helper" "$sherpa" "$onnx"; do
        actual_arches="$(/usr/bin/lipo -archs "$required_macho" 2>/dev/null)" || \
            release_die "unable to inspect required Hireva Mach-O: ${required_macho#"$app/"}"
        [[ "$actual_arches" == "arm64" ]] || \
            release_die "required Hireva Mach-O must be exactly arm64: ${required_macho#"$app/"} (found: $actual_arches)"
    done

    unexpected="$(/usr/bin/find "$app/Contents/Helpers" -mindepth 1 -maxdepth 1 \
        ! -name 'parakeet_asr_helper' -print -quit)"
    [[ -z "$unexpected" ]] || release_die "unexpected bundled helper: ${unexpected#"$app/"}"
    unexpected="$(/usr/bin/find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
        ! -name 'libsherpa-onnx-c-api.dylib' \
        ! -name 'libonnxruntime.1.27.0.dylib' -print -quit)"
    [[ -z "$unexpected" ]] || release_die "unexpected bundled framework: ${unexpected#"$app/"}"
    unexpected_bundle="$(/usr/bin/find "$app" -type d -name '*.bundle' \
        ! -path "$grdb_bundle" -print -quit)"
    [[ -z "$unexpected_bundle" ]] || \
        release_die "unexpected SwiftPM resource bundle: ${unexpected_bundle#"$app/"}"
    unexpected_root="$(/usr/bin/find "$app" -mindepth 1 -maxdepth 1 \
        ! -name 'Contents' -print -quit)"
    [[ -z "$unexpected_root" ]] || \
        release_die "unexpected app-root payload: ${unexpected_root#"$app/"}"

    require_exact_directory_entries "$app/Contents" "Contents" \
        Frameworks Helpers Info.plist MacOS Resources _CodeSignature
    require_exact_directory_entries "$app/Contents/MacOS" "MacOS" Hireva
    require_exact_directory_entries "$app/Contents/Resources" "resource" \
        AppIcon.icns Documentation GRDB_GRDB.bundle PrivacyInfo.xcprivacy \
        RuntimeProvenance.plist ThirdPartyNotices
    require_exact_directory_entries "$app/Contents/Resources/Documentation" "documentation" \
        local-model-installation.md privacy-and-data-flow.md release-installation.md \
        release-notes-0.1.0.md third-party-licenses.md
    require_exact_directory_entries "$app/Contents/Resources/ThirdPartyNotices" "third-party notice" \
        GRDB-LICENSE.txt onnxruntime-LICENSE.txt onnxruntime-ThirdPartyNotices.txt \
        sherpa-onnx-LICENSE.txt
    require_exact_directory_entries "$grdb_bundle" "GRDB resource" Info.plist PrivacyInfo.xcprivacy
    require_exact_directory_entries "$app/Contents/_CodeSignature" "code-signature" CodeResources
}

validate_hireva_info_plist_contract() {
    local distribution_build="$1"
    local build_timestamp
    local expected
    local actual_hash
    local expected_hash

    build_timestamp="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaBuildTimestampUTC || true)"
    [[ "$build_timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
        release_die "HirevaBuildTimestampUTC must be an RFC 3339 UTC timestamp"

    expected="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/hireva-info-contract.XXXXXX")" || \
        release_die "unable to create Info.plist comparison file"
    /usr/bin/plutil -create xml1 "$expected"
    /usr/bin/plutil -insert CFBundleDisplayName -string Hireva "$expected"
    /usr/bin/plutil -insert CFBundleExecutable -string Hireva "$expected"
    /usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$expected"
    /usr/bin/plutil -insert CFBundleIdentifier -string com.langcheng.Hireva "$expected"
    /usr/bin/plutil -insert CFBundleName -string Hireva "$expected"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL "$expected"
    /usr/bin/plutil -insert CFBundleShortVersionString -string "$RELEASE_SHORT_VERSION" "$expected"
    /usr/bin/plutil -insert CFBundleVersion -string "$RELEASE_BUNDLE_VERSION" "$expected"
    /usr/bin/plutil -insert HirevaBuildConfiguration -string release "$expected"
    /usr/bin/plutil -insert HirevaBuildTimestampUTC -string "$build_timestamp" "$expected"
    /usr/bin/plutil -insert HirevaDistributionBuild -bool "$distribution_build" "$expected"
    /usr/bin/plutil -insert HirevaGitCommitHash -string \
        "$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitCommitHash)" "$expected"
    /usr/bin/plutil -insert HirevaGitTreeState -string \
        "$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitTreeState)" "$expected"
    /usr/bin/plutil -insert HirevaRuntimeMode -string bundled_native "$expected"
    /usr/bin/plutil -insert HirevaSigningMode -string "$RELEASE_SIGNING_MODE" "$expected"
    /usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$expected"
    /usr/bin/plutil -insert NSAudioCaptureUsageDescription -string \
        "Hireva captures system audio for real-time interviewer question detection." "$expected"
    /usr/bin/plutil -insert NSHighResolutionCapable -bool true "$expected"
    /usr/bin/plutil -insert NSHumanReadableCopyright -string "Copyright 2026" "$expected"
    /usr/bin/plutil -insert NSMicrophoneUsageDescription -string \
        "Hireva uses the microphone to transcribe interview audio in real time." "$expected"
    /usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$expected"
    /usr/bin/plutil -insert NSScreenCaptureUsageDescription -string \
        "Hireva captures system audio to detect interviewer questions automatically." "$expected"
    /usr/bin/plutil -insert NSSpeechRecognitionUsageDescription -string \
        "Hireva uses Apple Speech to transcribe selected interview audio. Depending on macOS and locale, processing may occur on Apple servers." "$expected"

    actual_hash="$(canonical_plist_sha256 "$RELEASE_INFO_PLIST")"
    expected_hash="$(canonical_plist_sha256 "$expected")"
    /bin/rm -f "$expected"
    [[ "$actual_hash" == "$expected_hash" ]] || \
        release_die "Info.plist contains a value or key outside the reviewed release contract"
}

validate_hireva_privacy_manifest() {
    local manifest="$1"
    local value

    /usr/bin/plutil -lint "$manifest" >/dev/null || \
        release_die "app PrivacyInfo.xcprivacy is not a valid property list"

    value="$(/usr/bin/plutil -extract NSPrivacyTracking raw -o - "$manifest" 2>/dev/null || true)"
    [[ "$value" == "false" ]] || release_die "app privacy manifest must declare NSPrivacyTracking=false"
    if /usr/bin/plutil -extract NSPrivacyTrackingDomains.0 raw -o - "$manifest" >/dev/null 2>&1; then
        release_die "app privacy manifest must not declare tracking domains"
    fi

    [[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataType raw -o - "$manifest" 2>/dev/null || true)" == \
        "NSPrivacyCollectedDataTypeOtherUserContent" ]] || \
        release_die "app privacy manifest must declare other user content"
    [[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeLinked raw -o - "$manifest" 2>/dev/null || true)" == "true" ]] || \
        release_die "app privacy manifest must conservatively declare other user content as linked"
    [[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeTracking raw -o - "$manifest" 2>/dev/null || true)" == "false" ]] || \
        release_die "app privacy manifest must declare collected content as non-tracking"
    [[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypePurposes.0 raw -o - "$manifest" 2>/dev/null || true)" == \
        "NSPrivacyCollectedDataTypePurposeAppFunctionality" ]] || \
        release_die "app privacy manifest must declare app-functionality purpose"
    if /usr/bin/plutil -extract NSPrivacyCollectedDataTypes.1 raw -o - "$manifest" >/dev/null 2>&1 || \
       /usr/bin/plutil -extract NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypePurposes.1 raw -o - "$manifest" >/dev/null 2>&1; then
        release_die "app privacy manifest contains an unexpected collected-data declaration"
    fi

    if /usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0 raw -o - "$manifest" >/dev/null 2>&1; then
        release_die "app privacy manifest must not declare required-reason APIs for macOS"
    fi
    [[ "$(canonical_plist_sha256 "$manifest")" == "$HIREVA_PRIVACY_CANONICAL_SHA256" ]] || \
        release_die "app privacy manifest differs from the reviewed release declaration"
}

validate_grdb_privacy_manifest() {
    local manifest="$1"

    /usr/bin/plutil -lint "$manifest" >/dev/null || \
        release_die "GRDB PrivacyInfo.xcprivacy is not a valid property list"
    [[ "$(/usr/bin/plutil -extract NSPrivacyTracking raw -o - "$manifest" 2>/dev/null || true)" == "false" ]] || \
        release_die "GRDB privacy manifest must declare NSPrivacyTracking=false"
    if /usr/bin/plutil -extract NSPrivacyTrackingDomains.0 raw -o - "$manifest" >/dev/null 2>&1 || \
       /usr/bin/plutil -extract NSPrivacyCollectedDataTypes.0 raw -o - "$manifest" >/dev/null 2>&1 || \
       /usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0 raw -o - "$manifest" >/dev/null 2>&1; then
        release_die "GRDB privacy manifest must retain its reviewed empty declarations"
    fi
    [[ "$(canonical_plist_sha256 "$manifest")" == "$GRDB_PRIVACY_CANONICAL_SHA256" ]] || \
        release_die "GRDB privacy manifest differs from the pinned dependency declaration"
}

canonical_plist_sha256() {
    /usr/bin/plutil -convert binary1 -o - "$1" | \
        /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

validate_runtime_provenance_manifest() {
    local manifest="$1"
    local sherpa="$2"
    local onnx="$3"
    local sherpa_payload
    local onnx_payload
    local expected
    local actual_hash
    local expected_hash

    /usr/bin/plutil -lint "$manifest" >/dev/null || \
        release_die "RuntimeProvenance.plist is not a valid property list"
    [[ "$(/usr/bin/plutil -extract schema_version raw -o - "$manifest" 2>/dev/null || true)" == "2" ]] || \
        release_die "runtime provenance schema_version must be 2"
    [[ "$(/usr/bin/plutil -extract source_verification raw -o - "$manifest" 2>/dev/null || true)" == \
        "pinned-full-file-sha256-before-reviewed-path-sanitization-and-bundle-signing" ]] || \
        release_die "runtime provenance has an unexpected source verification method"
    [[ "$(/usr/bin/plutil -extract payload_hash_algorithm raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_RUNTIME_PAYLOAD_HASH_ALGORITHM" ]] || \
        release_die "runtime provenance has an unexpected payload hash algorithm"
    [[ "$(/usr/bin/plutil -extract binary_transform_identifier raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_RUNTIME_BINARY_TRANSFORM_IDENTIFIER" ]] || \
        release_die "runtime provenance has an unexpected binary transformation contract"
    [[ "$(/usr/bin/plutil -extract path_sanitization_identifier raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_RUNTIME_PATH_SANITIZATION_IDENTIFIER" ]] || \
        release_die "runtime provenance has an unexpected path sanitization contract"
    [[ "$(/usr/bin/plutil -extract source_archive_sha256 raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_SHERPA_RUNTIME_ARCHIVE_SHA256" ]] || \
        release_die "runtime provenance archive SHA-256 differs from the pinned source"
    [[ "$(/usr/bin/plutil -extract sherpa_onnx.version raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_SHERPA_ONNX_VERSION" ]] || \
        release_die "runtime provenance sherpa-onnx version differs from the pinned source"
    [[ "$(/usr/bin/plutil -extract sherpa_onnx.source_library_sha256 raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_SHERPA_LIBRARY_SOURCE_SHA256" ]] || \
        release_die "runtime provenance sherpa source SHA-256 differs from the pinned source"
    [[ "$(/usr/bin/plutil -extract sherpa_onnx.source_path_replacement_count raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_SHERPA_SOURCE_PATH_REPLACEMENT_COUNT" ]] || \
        release_die "runtime provenance sherpa path replacement count differs from the reviewed source"
    [[ "$(/usr/bin/plutil -extract onnx_runtime.version raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_ONNX_RUNTIME_VERSION" ]] || \
        release_die "runtime provenance ONNX Runtime version differs from the pinned source"
    [[ "$(/usr/bin/plutil -extract onnx_runtime.source_library_sha256 raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_ONNX_LIBRARY_SOURCE_SHA256" ]] || \
        release_die "runtime provenance ONNX source SHA-256 differs from the pinned source"
    [[ "$(/usr/bin/plutil -extract onnx_runtime.source_path_replacement_count raw -o - "$manifest" 2>/dev/null || true)" == \
        "$HIREVA_ONNX_SOURCE_PATH_REPLACEMENT_COUNT" ]] || \
        release_die "runtime provenance ONNX path replacement count differs from the reviewed source"

    sherpa_payload="$(/usr/bin/plutil -extract sherpa_onnx.macho_payload_sha256 raw -o - "$manifest" 2>/dev/null || true)"
    onnx_payload="$(/usr/bin/plutil -extract onnx_runtime.macho_payload_sha256 raw -o - "$manifest" 2>/dev/null || true)"
    [[ "$sherpa_payload" =~ ^[0-9a-f]{64}$ && "$onnx_payload" =~ ^[0-9a-f]{64}$ ]] || \
        release_die "runtime provenance contains an invalid Mach-O payload SHA-256"

    expected="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/hireva-runtime-provenance.XXXXXX")" || \
        release_die "unable to create runtime provenance comparison file"
    /usr/bin/plutil -create xml1 "$expected"
    /usr/bin/plutil -insert schema_version -integer 2 "$expected"
    /usr/bin/plutil -insert source_verification -string \
        "pinned-full-file-sha256-before-reviewed-path-sanitization-and-bundle-signing" \
        "$expected"
    /usr/bin/plutil -insert payload_hash_algorithm -string \
        "$HIREVA_RUNTIME_PAYLOAD_HASH_ALGORITHM" "$expected"
    /usr/bin/plutil -insert binary_transform_identifier -string \
        "$HIREVA_RUNTIME_BINARY_TRANSFORM_IDENTIFIER" "$expected"
    /usr/bin/plutil -insert path_sanitization_identifier -string \
        "$HIREVA_RUNTIME_PATH_SANITIZATION_IDENTIFIER" "$expected"
    /usr/bin/plutil -insert source_archive_sha256 -string \
        "$HIREVA_SHERPA_RUNTIME_ARCHIVE_SHA256" "$expected"
    /usr/bin/plutil -insert sherpa_onnx -json '{}' "$expected"
    /usr/bin/plutil -insert sherpa_onnx.version -string "$HIREVA_SHERPA_ONNX_VERSION" "$expected"
    /usr/bin/plutil -insert sherpa_onnx.source_library_sha256 -string \
        "$HIREVA_SHERPA_LIBRARY_SOURCE_SHA256" "$expected"
    /usr/bin/plutil -insert sherpa_onnx.source_path_replacement_count -integer \
        "$HIREVA_SHERPA_SOURCE_PATH_REPLACEMENT_COUNT" "$expected"
    /usr/bin/plutil -insert sherpa_onnx.macho_payload_sha256 -string "$sherpa_payload" "$expected"
    /usr/bin/plutil -insert onnx_runtime -json '{}' "$expected"
    /usr/bin/plutil -insert onnx_runtime.version -string "$HIREVA_ONNX_RUNTIME_VERSION" "$expected"
    /usr/bin/plutil -insert onnx_runtime.source_library_sha256 -string \
        "$HIREVA_ONNX_LIBRARY_SOURCE_SHA256" "$expected"
    /usr/bin/plutil -insert onnx_runtime.source_path_replacement_count -integer \
        "$HIREVA_ONNX_SOURCE_PATH_REPLACEMENT_COUNT" "$expected"
    /usr/bin/plutil -insert onnx_runtime.macho_payload_sha256 -string "$onnx_payload" "$expected"
    actual_hash="$(canonical_plist_sha256 "$manifest")"
    expected_hash="$(canonical_plist_sha256 "$expected")"
    /bin/rm -f "$expected"
    [[ "$actual_hash" == "$expected_hash" ]] || \
        release_die "runtime provenance contains an unexpected declaration"

    [[ -x "$SCRIPT_DIR/../runtime/macho_payload_sha256.sh" ]] || \
        release_die "runtime payload verifier is unavailable"
    [[ "$("$SCRIPT_DIR/../runtime/macho_payload_sha256.sh" "$sherpa")" == "$sherpa_payload" ]] || \
        release_die "bundled sherpa Mach-O payload differs from verified source provenance"
    [[ "$("$SCRIPT_DIR/../runtime/macho_payload_sha256.sh" "$onnx")" == "$onnx_payload" ]] || \
        release_die "bundled ONNX Mach-O payload differs from verified source provenance"
}

validate_hireva_macho_linkage() {
    local app="$RELEASE_APP_PATH"
    local macho
    local relative
    local rpath
    local dependency

    release_collect_machos
    for macho in "${RELEASE_MACHO_PATHS[@]}"; do
        relative="${macho#"$app/"}"
        while IFS= read -r rpath; do
            [[ -n "$rpath" ]] || continue
            case "$rpath" in
                @loader_path|@loader_path/../Frameworks|@executable_path/../Frameworks)
                    ;;
                *)
                    release_die "disallowed LC_RPATH in $relative: $rpath"
                    ;;
            esac
        done < <(/usr/bin/otool -l "$macho" | /usr/bin/awk \
            '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')

        while IFS= read -r dependency; do
            [[ -n "$dependency" ]] || continue
            case "$dependency" in
                /System/Library/*|/usr/lib/*|\
                @rpath/libsherpa-onnx-c-api.dylib|\
                @rpath/libonnxruntime.1.27.0.dylib|\
                @loader_path/../Frameworks/libsherpa-onnx-c-api.dylib|\
                @loader_path/../Frameworks/libonnxruntime.1.27.0.dylib|\
                @executable_path/../Frameworks/libsherpa-onnx-c-api.dylib|\
                @executable_path/../Frameworks/libonnxruntime.1.27.0.dylib)
                    ;;
                *)
                    release_die "disallowed LC_LOAD_DYLIB in $relative: $dependency"
                    ;;
            esac
        done < <(/usr/bin/otool -L "$macho" | /usr/bin/sed -n \
            '2,$s/^[[:space:]]*\(.*\) (compatibility version.*$/\1/p')
    done
}

validate_hireva_runtime_health() {
    local app="$RELEASE_APP_PATH"
    local helper="$app/Contents/Helpers/parakeet_asr_helper"
    local health_file
    local health_size
    local probe_status=0

    health_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/hireva-helper-health.XXXXXX")" || \
        release_die "unable to create helper health probe file"
    (
        set -euo pipefail
        set -m
        probe_pid=""
        probe_pgid=""
        cleanup_probe() {
            if [[ -n "$probe_pgid" ]] && /bin/kill -0 -- "-$probe_pgid" >/dev/null 2>&1; then
                /bin/kill -TERM -- "-$probe_pgid" >/dev/null 2>&1 || true
                /bin/sleep 0.1
                /bin/kill -KILL -- "-$probe_pgid" >/dev/null 2>&1 || true
            fi
            if [[ -n "$probe_pid" ]]; then
                wait "$probe_pid" >/dev/null 2>&1 || true
            fi
        }
        trap cleanup_probe EXIT INT TERM
        (
            ulimit -c 0
            ulimit -f 128
            ulimit -n 64
            ulimit -t 5
            ulimit -u 64
            exec /usr/bin/env -i HOME="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
                "$helper" --health
        ) >"$health_file" 2>/dev/null &
        probe_pid=$!
        probe_pgid="$probe_pid"
        deadline=$((SECONDS + 5))
        while /bin/kill -0 "$probe_pid" >/dev/null 2>&1; do
            if (( SECONDS >= deadline )); then
                exit 124
            fi
            /bin/sleep 0.05
        done
        wait "$probe_pid"
        probe_pid=""
    ) || probe_status=$?
    if [[ "$probe_status" -eq 124 ]]; then
        /bin/rm -f "$health_file"
        release_die "bundled Parakeet helper health probe exceeded 5 seconds"
    fi
    if [[ "$probe_status" -ne 0 ]]; then
        /bin/rm -f "$health_file"
        release_die "bundled Parakeet helper health probe failed"
    fi
    health_size="$(/usr/bin/stat -f '%z' "$health_file")" || {
        /bin/rm -f "$health_file"
        release_die "unable to inspect helper health probe output"
    }
    if (( health_size > 65536 )); then
        /bin/rm -f "$health_file"
        release_die "bundled Parakeet helper health probe exceeded 65536 bytes"
    fi
    if [[ "$(/usr/bin/plutil -extract status raw -o - "$health_file" 2>/dev/null || true)" != "ok" ]] || \
       [[ "$(/usr/bin/plutil -extract source raw -o - "$health_file" 2>/dev/null || true)" != "local_parakeet_asr" ]] || \
       [[ "$(/usr/bin/plutil -extract runtimeMode raw -o - "$health_file" 2>/dev/null || true)" != "bundled_native" ]] || \
       [[ "$(/usr/bin/plutil -extract runtimeVersion raw -o - "$health_file" 2>/dev/null || true)" != "1" ]] || \
       [[ "$(/usr/bin/plutil -extract sherpaVersion raw -o - "$health_file" 2>/dev/null || true)" != "1.13.4" ]] || \
       [[ "$(/usr/bin/plutil -extract onnxRuntimeVersion raw -o - "$health_file" 2>/dev/null || true)" != "1.27.0" ]] || \
       [[ "$(/usr/bin/plutil -extract architecture raw -o - "$health_file" 2>/dev/null || true)" != "arm64" ]] || \
       [[ "$(/usr/bin/plutil -extract modelStatus raw -o - "$health_file" 2>/dev/null || true)" != "not_probed" ]]; then
        /bin/rm -f "$health_file"
        release_die "bundled Parakeet helper returned an invalid health contract"
    fi
    /bin/rm -f "$health_file"
}

validate_loaded_release_app() {
    release_load_versions
    release_reject_unstable_metadata
    validate_hireva_release_contract
    release_validate_architectures
    validate_hireva_macho_linkage
    release_assert_signature_mode "$RELEASE_APP_PATH"
    validate_hireva_runtime_health
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
VALIDATE_ONLY=0
if [[ "${1:-}" == "--validate-only" ]]; then
    VALIDATE_ONLY=1
    shift
fi
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

release_validate_mode
release_load_architectures
release_load_app "$1"
if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
    validate_loaded_release_app
    printf 'VALIDATION=passed\n'
    printf 'APP_ARTIFACT=%s\n' "$(basename "$RELEASE_APP_PATH")"
    exit 0
fi

SOURCE_RELEASE_APP="$RELEASE_APP_PATH"
APP_ARTIFACT="$(basename "$SOURCE_RELEASE_APP")"
release_prepare_output_root
if [[ "$RELEASE_OUTPUT_ROOT" == "$SOURCE_RELEASE_APP" || \
      "$RELEASE_OUTPUT_ROOT" == "$SOURCE_RELEASE_APP/"* ]]; then
    release_die "HIREVA_RELEASE_OUTPUT_DIR must not be the source app or one of its descendants"
fi

WORK_DIR="$(/usr/bin/mktemp -d "$RELEASE_OUTPUT_ROOT/.hireva-package.XXXXXX")" || \
    release_die "unable to create packaging work directory"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
SNAPSHOT_APP="$WORK_DIR/$APP_ARTIFACT"

printf '[package] snapshotting signed app without resource-fork metadata\n'
/usr/bin/ditto --norsrc "$SOURCE_RELEASE_APP" "$SNAPSHOT_APP"
release_load_app "$SNAPSHOT_APP"
validate_loaded_release_app

ARTIFACT_STEM="$RELEASE_PRODUCT_NAME-$RELEASE_SHORT_VERSION-$RELEASE_BUNDLE_VERSION-$RELEASE_SIGNING_MODE"
FINAL_RELEASE_DIR="$RELEASE_OUTPUT_ROOT/$ARTIFACT_STEM"
if [[ -e "$FINAL_RELEASE_DIR" ]] || [[ -L "$FINAL_RELEASE_DIR" ]]; then
    release_die "release artifact directory already exists: $FINAL_RELEASE_DIR"
fi

STAGED_RELEASE_DIR="$WORK_DIR/$ARTIFACT_STEM"
/bin/mkdir "$STAGED_RELEASE_DIR"

ZIP_ARTIFACT="$ARTIFACT_STEM.zip"
CHECKSUM_ARTIFACT="$ZIP_ARTIFACT.sha256"
MANIFEST_ARTIFACT="version-manifest.json"
DOCUMENTATION_ARTIFACT="Documentation"
STAGED_APP="$STAGED_RELEASE_DIR/$APP_ARTIFACT"
STAGED_ZIP="$STAGED_RELEASE_DIR/$ZIP_ARTIFACT"
STAGED_CHECKSUM="$STAGED_RELEASE_DIR/$CHECKSUM_ARTIFACT"
STAGED_MANIFEST="$STAGED_RELEASE_DIR/$MANIFEST_ARTIFACT"
STAGED_DOCUMENTATION="$STAGED_RELEASE_DIR/$DOCUMENTATION_ARTIFACT"

/bin/mv "$SNAPSHOT_APP" "$STAGED_APP"
release_load_app "$STAGED_APP"
release_load_versions
if [[ ! -d "$STAGED_APP/Contents/Resources/Documentation" || \
      ! -d "$STAGED_APP/Contents/Resources/ThirdPartyNotices" ]]; then
    release_die "signed app is missing release documentation or third-party notices"
fi
/usr/bin/ditto --norsrc "$STAGED_APP/Contents/Resources/Documentation" "$STAGED_DOCUMENTATION"
/usr/bin/ditto --norsrc "$STAGED_APP/Contents/Resources/ThirdPartyNotices" \
    "$STAGED_DOCUMENTATION/ThirdPartyNotices"

printf '[package] creating notarization-compatible ZIP\n'
/usr/bin/ditto -c -k --keepParent --norsrc "$STAGED_APP" "$STAGED_ZIP"
if ! /usr/bin/unzip -tq "$STAGED_ZIP" >/dev/null; then
    release_die "ZIP integrity validation failed: $STAGED_ZIP"
fi
release_verify_zip_matches_app "$STAGED_APP" "$STAGED_ZIP"

ZIP_SHA256="$(release_sha256 "$STAGED_ZIP")"
printf '%s  %s\n' "$ZIP_SHA256" "$ZIP_ARTIFACT" > "$STAGED_CHECKSUM"

SIGNING_DETAILS="$(release_signature_details "$STAGED_APP")"
TEAM_IDENTIFIER="$(printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
CDHASH="$(printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
ACTUAL_ARCHS="$(/usr/bin/lipo -archs "$RELEASE_MAIN_EXECUTABLE")"
SOURCE_COMMIT="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitCommitHash || true)"
SOURCE_TREE_STATE="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitTreeState || true)"
GENERATED_AT_UTC="$(/bin/date -u +'%Y-%m-%dT%H:%M:%SZ')"

/usr/bin/plutil -create xml1 "$STAGED_MANIFEST"
/usr/bin/plutil -insert schema_version -integer 1 "$STAGED_MANIFEST"
/usr/bin/plutil -insert product_name -string "$RELEASE_PRODUCT_NAME" "$STAGED_MANIFEST"
/usr/bin/plutil -insert bundle_identifier -string "$RELEASE_BUNDLE_IDENTIFIER" "$STAGED_MANIFEST"
/usr/bin/plutil -insert short_version -string "$RELEASE_SHORT_VERSION" "$STAGED_MANIFEST"
/usr/bin/plutil -insert bundle_version -string "$RELEASE_BUNDLE_VERSION" "$STAGED_MANIFEST"
/usr/bin/plutil -insert signing_mode -string "$RELEASE_SIGNING_MODE" "$STAGED_MANIFEST"
/usr/bin/plutil -insert hardened_runtime -bool "$([[ "$RELEASE_SIGNING_MODE" == "developer-id" ]] && printf true || printf false)" "$STAGED_MANIFEST"
/usr/bin/plutil -insert notarized -bool false "$STAGED_MANIFEST"
/usr/bin/plutil -insert app_artifact -string "$APP_ARTIFACT" "$STAGED_MANIFEST"
/usr/bin/plutil -insert zip_artifact -string "$ZIP_ARTIFACT" "$STAGED_MANIFEST"
/usr/bin/plutil -insert checksum_artifact -string "$CHECKSUM_ARTIFACT" "$STAGED_MANIFEST"
/usr/bin/plutil -insert documentation_artifact -string "$DOCUMENTATION_ARTIFACT" "$STAGED_MANIFEST"
/usr/bin/plutil -insert zip_sha256 -string "$ZIP_SHA256" "$STAGED_MANIFEST"
/usr/bin/plutil -insert code_directory_hash -string "${CDHASH:-unavailable}" "$STAGED_MANIFEST"
/usr/bin/plutil -insert team_identifier -string "${TEAM_IDENTIFIER:-none}" "$STAGED_MANIFEST"
/usr/bin/plutil -insert source_commit -string "${SOURCE_COMMIT:-unknown}" "$STAGED_MANIFEST"
/usr/bin/plutil -insert source_tree_state -string "$SOURCE_TREE_STATE" "$STAGED_MANIFEST"
/usr/bin/plutil -insert generated_at_utc -string "$GENERATED_AT_UTC" "$STAGED_MANIFEST"
/usr/bin/plutil -insert requested_architectures -json '[]' "$STAGED_MANIFEST"
index=0
for arch in "${RELEASE_ARCHS[@]}"; do
    /usr/bin/plutil -insert "requested_architectures.$index" -string "$arch" "$STAGED_MANIFEST"
    ((index += 1))
done
/usr/bin/plutil -insert actual_architectures -json '[]' "$STAGED_MANIFEST"
index=0
for arch in $ACTUAL_ARCHS; do
    /usr/bin/plutil -insert "actual_architectures.$index" -string "$arch" "$STAGED_MANIFEST"
    ((index += 1))
done
/usr/bin/plutil -insert entitlements -json '[]' "$STAGED_MANIFEST"
if [[ "$RELEASE_SIGNING_MODE" == "developer-id" ]]; then
    /usr/bin/plutil -insert entitlements.0 -string 'com.apple.security.device.audio-input' "$STAGED_MANIFEST"
fi
/usr/bin/plutil -convert json "$STAGED_MANIFEST"
if ! /usr/bin/plutil -p "$STAGED_MANIFEST" >/dev/null; then
    release_die "generated version manifest is invalid"
fi

[[ -f "$EXCLUSIVE_RENAME" && ! -L "$EXCLUSIVE_RENAME" ]] || \
    release_die "exclusive artifact publisher is unavailable"
/usr/bin/ruby "$EXCLUSIVE_RENAME" "$STAGED_RELEASE_DIR" "$FINAL_RELEASE_DIR"
printf 'RELEASE_DIR=%s\n' "$FINAL_RELEASE_DIR"
printf 'APP_ARTIFACT=%s\n' "$FINAL_RELEASE_DIR/$APP_ARTIFACT"
printf 'ZIP_ARTIFACT=%s\n' "$FINAL_RELEASE_DIR/$ZIP_ARTIFACT"
printf 'ZIP_SHA256=%s\n' "$ZIP_SHA256"
printf 'VERSION_MANIFEST=%s\n' "$FINAL_RELEASE_DIR/$MANIFEST_ARTIFACT"
printf 'DOCUMENTATION=%s\n' "$FINAL_RELEASE_DIR/$DOCUMENTATION_ARTIFACT"
