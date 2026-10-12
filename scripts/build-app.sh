#!/bin/sh
# Builds dist/EliteForge.app on macOS: the app, the root helper and forgectl.
# Usage: scripts/build-app.sh [--dev-helper]
#   --dev-helper  build the helper with raw-send and init switches for protocol work
set -eu
cd "$(dirname "$0")/.."

HELPER_FLAGS=""
if [ "${1:-}" = "--dev-helper" ]; then
	HELPER_FLAGS="-Xswiftc -DHELPER_RAW_SEND"
fi

swift build -c release --product EliteForge
swift build -c release --product forgectl
# shellcheck disable=SC2086
swift build -c release --product eliteforge-helper $HELPER_FLAGS
BIN="$(swift build -c release --show-bin-path)"

APP=dist/EliteForge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchServices"
cp "$BIN/EliteForge" "$APP/Contents/MacOS/EliteForge"
cp "$BIN/eliteforge-helper" "$APP/Contents/Library/LaunchServices/com.eliteforge.helper"
cp "$BIN/forgectl" "$APP/Contents/Resources/forgectl"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/com.eliteforge.helper.plist scripts/install-helper.sh scripts/uninstall-helper.sh "$APP/Contents/Resources/"

# App icon from assets/icon.svg, rendered with a transparent background.
ICONWORK="$(mktemp -d)"
if swiftc -O scripts/image-tools/render-icon.swift -o "$ICONWORK/render-icon" 2>/dev/null; then
	SET="$ICONWORK/AppIcon.iconset"
	mkdir -p "$SET"
	for size in 16 32 128 256 512; do
		"$ICONWORK/render-icon" assets/icon.svg "$SET/icon_${size}x${size}.png" $size
		"$ICONWORK/render-icon" assets/icon.svg "$SET/icon_${size}x${size}@2x.png" $((size * 2))
	done
	iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
rm -rf "$ICONWORK"

# Ad-hoc signatures, inside out.
codesign --force --sign - --identifier com.eliteforge.helper "$APP/Contents/Library/LaunchServices/com.eliteforge.helper"
codesign --force --sign - --identifier com.eliteforge.forgectl "$APP/Contents/Resources/forgectl"
codesign --force --sign - --identifier com.eliteforge.app "$APP"
echo "built $APP"
