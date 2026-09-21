#!/bin/bash
# Builds VOLM Voice.app and installs it in ~/Applications.
# Signs with the local "VOLM Dev" certificate when present (see make-cert.sh) so macOS keeps the
# mic and speech permissions across rebuilds; falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product VOLMVoice
BIN="$(swift build -c release --show-bin-path)/VOLMVoice"

APP="build/VOLM Voice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/VOLM Voice"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/siri-speak.swift "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Fonts are optional and not in the repo (licensed). Drop your own .otf/.ttf in Resources/Fonts.
find Resources/Fonts -maxdepth 1 \( -name "*.otf" -o -name "*.ttf" \) -exec cp {} "$APP/Contents/Resources/Fonts/" \; 2>/dev/null || true

IDENTITY="VOLM Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --identifier studio.volm.voice "$APP"
else
  echo "warning: no \"$IDENTITY\" certificate, signing ad-hoc (permissions will be asked again after each build)"
  codesign --force --sign - --identifier studio.volm.voice "$APP"
fi

DEST="$HOME/Applications/VOLM Voice.app"
mkdir -p "$HOME/Applications"
pkill -x "VOLM Voice" 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
