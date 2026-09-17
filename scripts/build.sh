#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp/module-cache build/OpenClam.app/Contents/{MacOS,Resources}
xcrun clang -O2 -Wall -Wextra Vendor/Clamless/clamless-display.c \
  -framework CoreFoundation -framework CoreGraphics -framework IOKit \
  -o build/OpenClam.app/Contents/MacOS/display-helper
xcrun swiftc -swift-version 5 -O -module-cache-path .tmp/module-cache \
  Sources/main.swift Sources/Routing.swift Sources/DisplayRecovery.swift Sources/RoutingDiagnostics.swift -framework AppKit -framework IOKit \
  -o build/OpenClam.app/Contents/MacOS/OpenClam
xcrun clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -O2 -Wall -Wextra \
  Sources/clamshell-driver.m -framework Foundation -framework CoreGraphics -framework IOKit \
  -o build/OpenClam.app/Contents/MacOS/clamshell-driver
xcrun clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -O2 -Wall -Wextra \
  Sources/display-link.m -framework Foundation -framework CoreGraphics -framework IOKit \
  -o build/OpenClam.app/Contents/MacOS/display-link
xcrun clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -O2 -Wall -Wextra \
  Sources/display-rebind.m -framework Foundation -framework CoreGraphics -framework IOKit \
  -o build/OpenClam.app/Contents/MacOS/display-rebind
cp Info.plist build/OpenClam.app/Contents/Info.plist
cp Vendor/Clamless/LICENSE build/OpenClam.app/Contents/Resources/Clamless-LICENSE
codesign --force --sign - build/OpenClam.app/Contents/MacOS/display-helper
codesign --force --sign - build/OpenClam.app/Contents/MacOS/clamshell-driver
codesign --force --sign - build/OpenClam.app/Contents/MacOS/display-link
codesign --force --sign - build/OpenClam.app/Contents/MacOS/display-rebind
codesign --force --sign - build/OpenClam.app
printf 'Built %s/build/OpenClam.app\n' "$PWD"
