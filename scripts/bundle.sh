#!/bin/zsh
# Builds NotchMan and wraps it into build/NotchMan.app.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/NotchMan"

APP="build/NotchMan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchMan"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Prefer a stable Apple Development identity so TCC (Apple Events) and Keychain
# grants survive rebuilds; fall back to ad-hoc signing.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"
