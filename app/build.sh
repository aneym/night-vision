#!/bin/bash
# Build NightVision.app from NightVision.swift. Run after editing the source.
set -euo pipefail
cd "$(dirname "$0")"

APP=NightVision.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library -target arm64-apple-macos26.0 \
  NightVision.swift -o "$APP/Contents/MacOS/NightVision"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
