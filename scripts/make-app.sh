#!/bin/bash
# Builds "Vivid Playback.app" into ./build. Needs Xcode (free from the App Store).
# Usage: ./scripts/make-app.sh            (version 0.1.0)
#        VERSION=0.2.0 ./scripts/make-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="$(date +%Y%m%d%H%M)"
APP="build/Vivid Playback.app"

echo "Building Vivid Playback $VERSION…"
# Universal (Apple silicon and Intel) when the full Xcode toolchain is there; this Mac's chip otherwise.
if swift build -c release --product VividPlayback --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN="$(swift build -c release --product VividPlayback --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release --product VividPlayback
  BIN="$(swift build -c release --product VividPlayback --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VividPlayback" "$APP/Contents/MacOS/Vivid Playback"
cp -R Sources/VividPlayback/Resources/Fonts "$APP/Contents/Resources/Fonts"
cp -R Sources/VividPlayback/Resources/Images "$APP/Contents/Resources/Images"
[ -f Packaging/AppIcon.icns ] && cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS will run it. A Developer ID signature (and notarization) is only
# needed to open it on other Macs without the right-click > Open step.
codesign --force --deep --sign - "$APP"
echo "Built $APP"
