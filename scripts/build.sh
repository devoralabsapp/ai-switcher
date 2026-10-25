#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_CUSTOM_CACHE_PATH="$PROJECT_ROOT/.build/cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_CUSTOM_CACHE_PATH" "$PROJECT_ROOT/dist"

if [[ "${1:-}" == "--universal" ]]; then
    swift build -c release --arch arm64 --arch x86_64 --disable-sandbox
    BINARY="$PROJECT_ROOT/.build/apple/Products/Release/AISwitcher"
else
    swift build -c release --disable-sandbox
    BINARY="$(swift build -c release --show-bin-path --disable-sandbox)/AISwitcher"
fi
RESOURCE_BUNDLE="$(dirname "$BINARY")/AISwitcher_AISwitcherCore.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    printf 'Missing localization resource bundle: %s\n' "$RESOURCE_BUNDLE" >&2
    exit 1
fi

APP="$PROJECT_ROOT/dist/AI Switcher.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AISwitcher"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
rm -rf "$APP/Contents/Resources/AISwitcher_AISwitcherCore.bundle"
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/AISwitcher_AISwitcherCore.bundle"
swift "$PROJECT_ROOT/scripts/make-icon.swift" "$PROJECT_ROOT/.build/AppIcon.iconset"
python3 "$PROJECT_ROOT/scripts/make-icns.py" "$PROJECT_ROOT/.build/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
printf '\nBuilt: %s\n' "$APP"
