#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp/module-cache build/OpenClam.app/Contents/{MacOS,Resources}
xcrun clang -O2 -Wall -Wextra Vendor/Clamless/clamless-display.c \
  -framework CoreFoundation -framework CoreGraphics -framework IOKit \
  -o build/OpenClam.app/Contents/MacOS/display-helper
xcrun swiftc -swift-version 5 -O -module-cache-path .tmp/module-cache \
  Sources/main.swift -framework AppKit -framework IOKit \
  -o build/OpenClam.app/Contents/MacOS/OpenClam
cp Info.plist build/OpenClam.app/Contents/Info.plist
cp Vendor/Clamless/LICENSE build/OpenClam.app/Contents/Resources/Clamless-LICENSE
codesign --force --sign - build/OpenClam.app/Contents/MacOS/display-helper
codesign --force --sign - build/OpenClam.app
printf 'Built %s/build/OpenClam.app\n' "$PWD"
