#!/bin/sh
# Copies the working tree to a Mac over SSH for building and testing.
# Usage: scripts/sync-to-mac.sh [host] [remote-dir]
set -eu
HOST="${1:-macbook-pro.local}"
DEST="${2:-/tmp/eliteforge}"
cd "$(dirname "$0")/.."
tar --exclude=.build --exclude=.git --exclude=dist -czf - . | ssh -o BatchMode=yes "$HOST" "mkdir -p '$DEST' && rm -rf '$DEST/Sources' '$DEST/Tests' '$DEST/scripts' '$DEST/Support' && tar -xzf - -C '$DEST'"
