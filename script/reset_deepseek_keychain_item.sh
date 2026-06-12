#!/usr/bin/env bash
set -euo pipefail

SERVICE="com.langcheng.InterviewCopilotMac.LLMProviderKeys"
ACCOUNT="deepseek.default"

cat <<EOF
This will delete only this InterviewCopilotMac Keychain item:

  service: $SERVICE
  account: $ACCOUNT

It will not print the saved API key and will not delete unrelated Keychain items.
Use this only after changing to a stable signing identity, then re-save the key once.

Type exactly: DELETE deepseek.default
EOF

read -r -p "> " CONFIRMATION
if [[ "$CONFIRMATION" != "DELETE deepseek.default" ]]; then
    echo "Aborted. No Keychain item was changed."
    exit 1
fi

if security delete-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
    echo "Deleted the specific DeepSeek Keychain item."
else
    echo "No matching DeepSeek Keychain item was found, or deletion was cancelled."
fi
