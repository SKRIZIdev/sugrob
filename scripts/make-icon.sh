#!/bin/bash
# Собирает Resources/AppIcon.icns из scripts/icon/main.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build Resources

EXTRA=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$STALE" ] && [ -f "${STALE%/*}/bridging.modulemap" ]; then
  sed "s#@EMPTY@#$PWD/scripts/toolchain/empty.modulemap#" scripts/toolchain/clt-fix.yaml.in > build/clt-fix.yaml
  EXTRA=(-vfsoverlay build/clt-fix.yaml -Xcc -ivfsoverlay -Xcc build/clt-fix.yaml)
fi

swiftc -swift-version 5 ${EXTRA[@]+"${EXTRA[@]}"} -framework AppKit scripts/icon/main.swift -o build/make-icon
./build/make-icon build/icon-1024.png

SET=build/AppIcon.iconset
rm -rf "$SET" && mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Иконка: Resources/AppIcon.icns"
