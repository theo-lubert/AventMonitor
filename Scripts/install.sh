#!/bin/zsh
# Builds Release, replaces ~/Applications/Baby Monitor.app and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-$PWD/.build/DerivedData}"
APP_NAME="Baby Monitor"
DEST="$HOME/Applications/$APP_NAME.app"

[[ -d AventMonitor.xcodeproj ]] || xcodegen generate
xcodebuild -project AventMonitor.xcodeproj -scheme AventMonitor -configuration Release \
  -derivedDataPath "$DD" build | grep -E "error:|\*\* BUILD" || true
APP="$DD/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Build not found: $APP" >&2; exit 1; }

osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.25; done
pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST ($(stat -f '%Sm' "$DEST/Contents/MacOS/$APP_NAME"))"
