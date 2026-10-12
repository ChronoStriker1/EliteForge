#!/bin/sh
# Removes the EliteForge root helper (and the older XBElite2 one). Run with sudo.
set -eu
LABEL=com.eliteforge.helper
if [ "$(id -u)" -ne 0 ]; then
	echo "uninstall-helper.sh: run with sudo" >&2
	exit 1
fi
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" "/Library/PrivilegedHelperTools/$LABEL.clients"
launchctl bootout system/com.xbelite2.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.xbelite2.helper.plist /Library/PrivilegedHelperTools/com.xbelite2.helper
echo "EliteForge helper removed"
