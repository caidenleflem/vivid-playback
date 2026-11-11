#!/bin/bash
# Builds the newest Vivid Playback on this Mac and installs it: no waiting for GitHub.
# Usage (Terminal):
#   bash <(curl -fsSL https://raw.githubusercontent.com/caidenleflem/vivid-playback/main/scripts/build-here.sh)
# Needs Apple's free Command Line Tools (it offers to install them). Your shows are kept: they
# live in Documents › Vivid Playback, not in the app. The code is kept in a folder of its own,
# so the next build only compiles what changed.
set -euo pipefail

SRC="$HOME/Library/Caches/VividPlayback-build"
APP="/Applications/Vivid Playback.app"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "This needs Apple's Command Line Tools (free, about 1 GB)."
  echo "A window will ask to install them. When that's done, run this command again."
  xcode-select --install || true
  exit 1
fi

echo "Getting the newest code…"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch -q --depth 1 origin main
  git -C "$SRC" reset -q --hard FETCH_HEAD
else
  rm -rf "$SRC"
  git clone -q --depth 1 https://github.com/caidenleflem/vivid-playback "$SRC"
fi
cd "$SRC"
COMMIT=$(git log -1 --format='%h · %s')
echo "Building: $COMMIT"

# Same numbering as the GitHub builds' 0.2.x, marked as built here.
VERSION="0.2.$(date +%m%d%H%M)" UNIVERSAL=0 ./scripts/make-app.sh

osascript -e 'tell application "Vivid Playback" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$APP"
cp -R "build/Vivid Playback.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Installed Vivid Playback, built here from: $COMMIT"
open "$APP"
