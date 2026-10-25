#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$PROJECT_ROOT/dist"
APP="$OUTPUT/AI Switcher.app"

if [[ ! -x "$APP/Contents/MacOS/AISwitcher" ]]; then
    printf 'Build the app first: bash scripts/build.sh --universal\n' >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/AISwitcher" --localization-smoke-test
ditto -c -k --norsrc --keepParent "$APP" "$OUTPUT/AI-Switcher-macOS.zip"
(
    cd "$OUTPUT"
    shasum -a 256 AI-Switcher-macOS.zip > SHA256SUMS.txt
)
printf 'Packaged: %s\n' "$OUTPUT/AI-Switcher-macOS.zip"
