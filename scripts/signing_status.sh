#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${SIGNING_STATUS_APP_BUNDLE:-$ROOT_DIR/dist/Hireva.app}"

echo "=== Hireva Signing Status ==="
echo "App bundle: $APP_BUNDLE"
echo ""
echo "Available code signing identities:"
IDENTITY_OUTPUT="$(security find-identity -v -p codesigning 2>&1 || true)"
if [[ -n "$IDENTITY_OUTPUT" ]]; then
    printf '%s\n' "$IDENTITY_OUTPUT"
else
    echo "(unable to query identities)"
fi

APPLE_DEVELOPMENT_COUNT="$(printf '%s\n' "$IDENTITY_OUTPUT" | grep -c '"Apple Development:' || true)"
DEVELOPER_ID_COUNT="$(printf '%s\n' "$IDENTITY_OUTPUT" | grep -c '"Developer ID Application:' || true)"
echo "Apple Development identities: $APPLE_DEVELOPMENT_COUNT"
echo "Developer ID Application identities: $DEVELOPER_ID_COUNT"

if [[ -n "${HIREVA_SIGNING_IDENTITY:-${INTERVIEW_COPILOT_SIGNING_IDENTITY:-}}" ]]; then
    echo "HIREVA_SIGNING_IDENTITY: ${HIREVA_SIGNING_IDENTITY:-$INTERVIEW_COPILOT_SIGNING_IDENTITY}"
else
    echo "HIREVA_SIGNING_IDENTITY: unset"
fi

echo ""
echo "Current app signature information:"
SIGNING_DETAILS=""
if [[ -d "$APP_BUNDLE" ]]; then
    SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
    printf '%s\n' "$SIGNING_DETAILS"
else
    echo "App bundle does not exist."
fi

echo ""
echo "Gatekeeper assessment:"
if [[ -d "$APP_BUNDLE" ]]; then
    spctl --assess --type execute --verbose=4 "$APP_BUNDLE" 2>&1 || true
else
    echo "Skipped: app bundle does not exist."
fi

if [[ "$DEVELOPER_ID_COUNT" -gt 0 ]]; then
    STATUS="DEVELOPER_ID_AVAILABLE"
elif [[ "$APPLE_DEVELOPMENT_COUNT" -gt 0 ]]; then
    STATUS="APPLE_DEVELOPMENT_AVAILABLE"
elif printf '%s\n' "$SIGNING_DETAILS" | grep -q '^Signature=adhoc$'; then
    STATUS="AD_HOC_ONLY"
else
    STATUS="UNKNOWN"
fi

echo "Signing status: $STATUS"
exit 0
