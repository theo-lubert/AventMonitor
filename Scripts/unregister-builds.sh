#!/bin/zsh
# Xcode registers every app it builds with Launch Services, so build products in
# DerivedData show up as extra copies of the app (Open With, Spotlight, notifications).
# Unregister them: only the installed copy in ~/Applications should exist for macOS.
set -uo pipefail
cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-$PWD/.build/DerivedData}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in "$DD"/Build/Products/*/*.app(N); do
  "$LSREGISTER" -u "$app" 2>/dev/null || true
done
