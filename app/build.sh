#!/bin/bash
# Build NightVision.app from NightVision.swift. Run after editing the source.
set -euo pipefail
cd "$(dirname "$0")"

APP=NightVision.app

# TCC grants are matched against the code's designated requirement. Ad-hoc
# signing normally makes that requirement a changing CDHash. Supply an explicit,
# stable bundle-identifier requirement instead, so rebuilds at this fixed path
# remain the same TCC client. Never fall back to the implicit CDHash form.
SIGN_REQUIREMENT='=designated => identifier "com.aneyman.nightvision.menubar"'

mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library -target arm64-apple-macos26.0 \
  NightVision.swift -o "$APP/Contents/MacOS/NightVision"
# The Accessibility grant is pinned to the "Apple Development" certificate
# requirement, so sign with that identity whenever it can be used. From a
# background (ssh/agent) session the login keychain refuses the key with
# errSecInternalComponent; run the build from a GUI Terminal, or run this
# codesign line through a one-shot launch agent in gui/$UID.
IDENTITY="${NIGHT_VISION_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]] && codesign --force --options runtime --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Built $PWD/$APP (signed: $IDENTITY)"
else
  codesign --force --options runtime --requirements "$SIGN_REQUIREMENT" --sign - "$APP"
  echo "Built $PWD/$APP (ad-hoc, stable requirement: $SIGN_REQUIREMENT)"
  echo "WARNING: ad-hoc signature does not match an Accessibility grant made for a" >&2
  echo "developer-signed build; F1/F2 keys stay off until re-signed or re-granted." >&2
fi
