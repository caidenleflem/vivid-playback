#!/bin/bash
# Installs the newest Vivid Playback from GitHub into /Applications and opens it.
# Usage (Terminal):
#   bash <(curl -fsSL https://raw.githubusercontent.com/caidenleflem/vivid-playback/main/scripts/install-latest.sh)
# Your shows are kept: they live in Documents › Vivid Playback, not in the app.
set -euo pipefail

echo "Finding the newest version…"
URL=$(curl -fsSL https://api.github.com/repos/caidenleflem/vivid-playback/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | cut -d'"' -f4)
if [ -z "$URL" ]; then echo "Couldn't find a release to download."; exit 1; fi
echo "Downloading $(basename "$URL")…"
TMP=$(mktemp -d)
curl -fL --progress-bar -o "$TMP/VividPlayback.dmg" "$URL"

MOUNT=$(hdiutil attach -nobrowse -noautoopen "$TMP/VividPlayback.dmg" | tail -1 | awk -F'\t' '{print $NF}')
# Quit the running copy and wait until it's really gone, so the new one is what opens.
osascript -e 'tell application "Vivid Playback" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 40); do pgrep -x "Vivid Playback" >/dev/null || break; sleep 0.25; done
if pgrep -x "Vivid Playback" >/dev/null; then
  echo "Vivid Playback is still open (a window or a question may be waiting). Quit it, then run this again."
  exit 1
fi
rm -rf "/Applications/Vivid Playback.app"
cp -R "$MOUNT/Vivid Playback.app" /Applications/
hdiutil detach "$MOUNT" -quiet || true
rm -rf "$TMP"
# Downloaded from GitHub, not the App Store: skip the "can't check the developer" step.
xattr -dr com.apple.quarantine "/Applications/Vivid Playback.app" 2>/dev/null || true

VERSION=$(defaults read "/Applications/Vivid Playback.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
echo "Installed Vivid Playback ${VERSION}."
open "/Applications/Vivid Playback.app"
