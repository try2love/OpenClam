#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/research
xcrun clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -Wall -Wextra \
  -framework Foundation -framework CoreGraphics -framework IOKit \
  Sources/clamshell-probe.m -o build/research/clamshell-probe
codesign --force --sign - build/research/clamshell-probe
