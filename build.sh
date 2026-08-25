#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/dist/ZshEnv.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$ROOT/.build/module-cache"
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
swiftc "$ROOT/Sources/ZshEnvLogic.swift" "$ROOT/Sources/ZshEnvApp.swift" -o "$APP/Contents/MacOS/ZshEnv" \
  -target arm64-apple-macosx13.0 -framework SwiftUI -framework AppKit -framework Security -parse-as-library
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP"
