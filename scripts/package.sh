#!/bin/zsh
# Builds a universal (arm64 + x86_64), ad-hoc-signed NotchMan.app for distribution and zips it as
# build/NotchMan-v<version>.zip, using the version in Support/Info.plist.
# Ad-hoc so the download doesn't carry a personal Apple Development certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

# One build per architecture, merged with lipo: a multi-arch `swift build` uses the Xcode build
# system, which fails on SwiftTerm's build plugin.
for ARCH in arm64 x86_64; do swift build -c release --arch $ARCH; done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"

STAGE="build/package"
APP="$STAGE/NotchMan.app"
ZIP="build/NotchMan-v$VERSION.zip"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/NotchMan" \
    "$(swift build -c release --arch arm64 --show-bin-path)/NotchMan" \
    "$(swift build -c release --arch x86_64 --show-bin-path)/NotchMan"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP ($(lipo -archs "$APP/Contents/MacOS/NotchMan"))"
