#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
AISWITCHER_TEST_BROWSER=0
AISWITCHER_TEST_CODEX=0
AISWITCHER_TEST_DESKTOP=0
for option in "$@"; do
    case "$option" in
        --browser) AISWITCHER_TEST_BROWSER=1 ;;
        --codex) AISWITCHER_TEST_CODEX=1 ;;
        --desktop) AISWITCHER_TEST_DESKTOP=1 ;;
        *) printf 'Unknown test option: %s\n' "$option" >&2; exit 1 ;;
    esac
done
swift test --disable-sandbox --cache-path .build/cache

if [[ "$AISWITCHER_TEST_BROWSER" == "1" || "$AISWITCHER_TEST_CODEX" == "1" || "$AISWITCHER_TEST_DESKTOP" == "1" ]]; then
    TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-switcher-smoke.XXXXXX")"
    trap 'rm -rf "$TEST_ROOT"' EXIT
    BINARY="$(swift build --show-bin-path --disable-sandbox)/AISwitcher"
    if [[ "$AISWITCHER_TEST_BROWSER" == "1" ]]; then
        "$BINARY" --data-dir "$TEST_ROOT" --smoke-test
        python3 scripts/verify-isolation.py
    fi
    if [[ "$AISWITCHER_TEST_CODEX" == "1" ]]; then
        "$BINARY" --data-dir "$TEST_ROOT" --quota-smoke-test
    fi
    if [[ "$AISWITCHER_TEST_DESKTOP" == "1" ]]; then
        "$BINARY" --data-dir "$TEST_ROOT" --desktop-smoke-test
    fi
fi
