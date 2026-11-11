#!/bin/bash
# Builds AventCore (aventproxy's bridge + login/discovery) as a static library.
# Output: Build/core/libaventcore.a and Build/core/libaventcore.h
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Build/core"
VENDOR="$ROOT/Vendor/aventproxy"
mkdir -p "$OUT"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:$PATH"
if [ ! -f "$VENDOR/avent-webrtc-bridge/go.mod" ]; then
  echo "error: Vendor/aventproxy is missing. Run: git submodule update --init" >&2
  exit 1
fi

python3 -I "$ROOT/Scripts/gen-keys.py" \
  "$VENDOR/custom_components/philips_avent/const.py" "$ROOT/Core/keys_gen.go"

cd "$ROOT/Core"
[ -f go.sum ] || go mod tidy
export CGO_ENABLED=1 GOOS=darwin GOARCH=arm64
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
export CGO_CFLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CGO_LDFLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
go build -buildmode=c-archive -trimpath -o "$OUT/libaventcore.a" .
echo "Built $OUT/libaventcore.a"
