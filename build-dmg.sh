#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/dist/ZshEnv.app"
DMG="$ROOT/dist/ZshEnv-1.0.0.dmg"
STAGE="$(mktemp -d /private/tmp/zshenv-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

"$ROOT/build.sh"

ditto "$APP" "$STAGE/ZshEnv.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ZshEnv" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "Built: $DMG"
