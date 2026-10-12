#!/bin/sh
# Installs the EliteForge root helper as a LaunchDaemon. Run with sudo.
# Usage: install-helper.sh [helper-binary] [launchd-plist] [app-executable] [forgectl]
# Without arguments it uses a release build from this checkout.
#
# The helper only accepts the exact app and forgectl binaries given here: it
# records their code hashes in a root-owned file. After rebuilding the app,
# install the helper again.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="${1:-$DIR/../.build/release/eliteforge-helper}"
PLIST="${2:-$DIR/../Support/com.eliteforge.helper.plist}"
# Inside the app bundle this script is in Contents/Resources.
if [ -x "$DIR/../MacOS/EliteForge" ]; then
	APP_BIN="${3:-$DIR/../MacOS/EliteForge}"
	CLI_BIN="${4:-$DIR/forgectl}"
else
	APP_BIN="${3:-$DIR/../dist/EliteForge.app/Contents/MacOS/EliteForge}"
	CLI_BIN="${4:-$DIR/../dist/EliteForge.app/Contents/Resources/forgectl}"
fi
LABEL=com.eliteforge.helper
CLIENTS="/Library/PrivilegedHelperTools/$LABEL.clients"

if [ "$(id -u)" -ne 0 ]; then
	echo "install-helper.sh: run with sudo" >&2
	exit 1
fi
[ -x "$HELPER" ] || { echo "install-helper.sh: helper binary not found: $HELPER" >&2; exit 1; }
[ -f "$PLIST" ] || { echo "install-helper.sh: launchd plist not found: $PLIST" >&2; exit 1; }

# "<signing identifier> <cdhash>" for each client the helper will accept.
cdhash() {
	codesign -dvvv --arch "$(uname -m)" "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1
}
CLIENT_LIST=""
for pair in "com.eliteforge.app:$APP_BIN" "com.eliteforge.forgectl:$CLI_BIN"; do
	id="${pair%%:*}"
	bin="${pair#*:}"
	[ -x "$bin" ] || { echo "install-helper.sh: skipping missing client $bin" >&2; continue; }
	hash="$(cdhash "$bin")"
	[ -n "$hash" ] || { echo "install-helper.sh: $bin isn't code signed" >&2; exit 1; }
	CLIENT_LIST="$CLIENT_LIST$id $hash
"
done
[ -n "$CLIENT_LIST" ] || { echo "install-helper.sh: no client binaries found; the helper would refuse every client" >&2; exit 1; }

launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout returns before the old helper has exited, and bootstrapping the
# label again meanwhile fails with "Bootstrap failed: 5: Input/output error".
for _ in 1 2 3 4 5 6 7 8 9 10; do
	launchctl print "system/$LABEL" >/dev/null 2>&1 || break
	sleep 1
done
# Remove the helper from before the app was renamed (XBElite2).
launchctl bootout system/com.xbelite2.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.xbelite2.helper.plist /Library/PrivilegedHelperTools/com.xbelite2.helper
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$HELPER" "/Library/PrivilegedHelperTools/$LABEL"
install -o root -g wheel -m 644 "$PLIST" "/Library/LaunchDaemons/$LABEL.plist"
TMP="$(mktemp)"
printf '%s' "$CLIENT_LIST" > "$TMP"
install -o root -g wheel -m 644 "$TMP" "$CLIENTS"
rm -f "$TMP"
for attempt in 1 2 3 4 5; do
	launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" && break
	[ "$attempt" -lt 5 ] || exit 1
	sleep 1
done
echo "EliteForge helper installed"
