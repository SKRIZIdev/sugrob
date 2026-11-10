#!/bin/bash
# Сборка Сугроба без Xcode: хватает Command Line Tools.
#   ./build.sh            — собрать build/Sugrob.app
#   ./build.sh install    — собрать и положить в /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Sugrob.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Обход битых Command Line Tools: старый usr/include/swift/module.modulemap (2023) дублирует
# bridging.modulemap из CLT 26 → «redefinition of module 'SwiftBridging'», AppKit не собирается.
# Насовсем лечится: sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.bak}
# Без sudo — подменяем его пустым файлом через VFS-оверлей только на время сборки.
EXTRA=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$STALE" ] && [ -f "${STALE%/*}/bridging.modulemap" ]; then
  mkdir -p build
  sed "s#@EMPTY@#$PWD/scripts/toolchain/empty.modulemap#" scripts/toolchain/clt-fix.yaml.in > build/clt-fix.yaml
  EXTRA=(-vfsoverlay build/clt-fix.yaml -Xcc -ivfsoverlay -Xcc build/clt-fix.yaml)
fi

swiftc -O -swift-version 5 "${EXTRA[@]}" \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
  -framework ServiceManagement -framework ApplicationServices \
  Sources/*.swift -o "$APP/Contents/MacOS/Sugrob"

cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Собрано: $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x Sugrob 2>/dev/null || true
  rm -rf /Applications/Sugrob.app
  cp -R "$APP" /Applications/Sugrob.app
  echo "Установлено: /Applications/Sugrob.app"
fi
