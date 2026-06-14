#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Local Meter"
DIST_APP="$ROOT_DIR/dist/$APP_NAME.app"
DEST_APP="$HOME/Applications/$APP_NAME.app"
DEST_DIR="$(dirname "$DEST_APP")"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$DIST_APP" ]]; then
  "$ROOT_DIR/scripts/package-app.sh"
fi

pkill -x "Codex Local Meter" 2>/dev/null || true
pkill -x "CodexLocalMeter" 2>/dev/null || true

mkdir -p "$DEST_DIR"

if [[ -d "$DEST_APP" ]]; then
  rm -rf "$DEST_APP"
fi

cp -R "$DIST_APP" "$DEST_APP"
touch "$DEST_APP"
"$LSREGISTER" -f "$DEST_APP"

echo "Installed: $DEST_APP"
echo "Launch with: open \"$DEST_APP\""
