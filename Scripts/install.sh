#!/bin/zsh
# Builds Release, replaces ~/Applications/Baby Monitor.app and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-$PWD/.build/DerivedData}"
APP_NAME="Baby Monitor"
DEST="$HOME/Applications/$APP_NAME.app"

# Always regenerate: project.yml may list files a stale project does not know.
xcodegen generate --quiet
LOG="$DD/install-build.log"
mkdir -p "$DD"
# A failed build must stop here, or the previous product would be installed.
if ! xcodebuild -project AventMonitor.xcodeproj -scheme AventMonitor -configuration Release \
  -derivedDataPath "$DD" build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" >&2 || tail -20 "$LOG" >&2
  echo "Release build failed, nothing installed (log: $LOG)" >&2
  exit 1
fi
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
