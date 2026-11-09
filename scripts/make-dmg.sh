#!/bin/bash
# Builds the app and wraps it in a drag-to-Applications disk image in ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
VERSION="$VERSION" ./scripts/make-app.sh

STAGE="build/dmg"
DMG="build/Vivid Playback $VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/Vivid Playback.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vivid Playback" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
echo "Open it and drag Vivid Playback to Applications."
