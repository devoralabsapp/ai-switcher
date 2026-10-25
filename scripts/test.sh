#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift test --disable-sandbox --cache-path .build/cache

if [[ "${1:-}" == "--browser" ]]; then
    TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-switcher-smoke.XXXXXX")"
    trap 'rm -rf "$TEST_ROOT"' EXIT
    BINARY="$(swift build --show-bin-path --disable-sandbox)/AISwitcher"
    "$BINARY" --data-dir "$TEST_ROOT" --smoke-test
    python3 scripts/verify-isolation.py
fi
