#!/bin/bash
# Adds your Notion integration token to Quill without going through the Settings window.
# Prompts for the token (input hidden), hands it to Quill, and Quill stores it in the Keychain.
set -euo pipefail

DIR="$HOME/Library/Application Support/Quill"
mkdir -p "$DIR"
FILE="$DIR/notion-token.txt"

printf "Paste your Notion integration token (it stays hidden), then press Return:\n> "
read -rs TOKEN
printf "\n"

TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
if [ ${#TOKEN} -lt 21 ]; then
    echo "That's only ${#TOKEN} characters — too short for a Notion token. Nothing was saved."
    exit 1
fi

umask 077
printf '%s' "$TOKEN" > "$FILE"
echo "Handed a ${#TOKEN}-character token to Quill."

osascript -e 'tell application "Quill" to quit' >/dev/null 2>&1 || true
sleep 1
open -a Quill
sleep 4

if security find-generic-password -s com.ania.quill -a notion-token >/dev/null 2>&1; then
    echo "Stored in your Keychain. Open Quill's Settings (Cmd-,) → Notion and pick your database."
else
    echo "Quill didn't store it. Check: $DIR/diagnostics.log"
    exit 1
fi
