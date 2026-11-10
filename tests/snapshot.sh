#!/bin/bash
# Прогон симуляции без экрана: проверки + кадры в PNG.
#   ./tests/snapshot.sh [папка для png]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/snapshots}"
mkdir -p build "$OUT"

EXTRA=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$STALE" ] && [ -f "${STALE%/*}/bridging.modulemap" ]; then
  sed "s#@EMPTY@#$PWD/scripts/toolchain/empty.modulemap#" scripts/toolchain/clt-fix.yaml.in > build/clt-fix.yaml
  EXTRA=(-vfsoverlay build/clt-fix.yaml -Xcc -ivfsoverlay -Xcc build/clt-fix.yaml)
fi

swiftc -O -swift-version 5 "${EXTRA[@]}" -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework ApplicationServices \
  Sources/Support.swift Sources/Heightmap.swift Sources/WindowTracker.swift Sources/World.swift \
  Sources/Render.swift Sources/Overlay.swift tests/snapshot/main.swift -o build/snapshot

./build/snapshot "$OUT"
