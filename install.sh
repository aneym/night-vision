#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd -P)"

# launchd cannot exec scripts on external volumes (TCC denies its bash; exit 126),
# so the runtime must live on the internal disk. When installing from an external
# checkout, sync to the internal runtime copy and install from there.
RUNTIME="$HOME/.local/share/night-vision"
if [[ "$ROOT" == /Volumes/* ]]; then
  mkdir -p "$RUNTIME"
  rsync -a --delete --exclude '.git' "$ROOT/" "$RUNTIME/"
  exec "$RUNTIME/install.sh"
fi

CONFIG="$HOME/.config/night-vision/config.json"
STATE="$HOME/.local/state/night-vision"
OLD_STATE="$HOME/.claude/tools/night-vision/state"
AGENTS="$HOME/Library/LaunchAgents"
CLI="$HOME/.local/bin/nightvision"
APP="$ROOT/app/NightVision.app"

[[ -f "$CONFIG" ]] || { printf 'Missing config: %s\n' "$CONFIG" >&2; exit 1; }
mkdir -p "$STATE" "$HOME/.local/bin" "$AGENTS" "$ROOT/bin"

ensure_brew_package() {
  if ! command -v "$1" >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || { printf 'Homebrew is required to install %s\n' "$2" >&2; exit 1; }
    brew install "$2"
  fi
}

ensure_brew_package jq jq
backend=$(jq -r '.display' "$CONFIG")
case "$backend" in
  ddc) ensure_brew_package m1ddc m1ddc ;;
  internal)
    # The native helper is built below and is the primary Apple-silicon path.
    # Keep the Homebrew utility only as a compatibility fallback for source
    # trees that do not carry the helper.
    [[ -f "$ROOT/nvbrightness.m" ]] || ensure_brew_package brightness brightness
    ;;
  *) printf 'Unsupported display backend: %s\n' "$backend" >&2; exit 1 ;;
esac

for file in phase override; do
  [[ -e "$STATE/$file" ]] || [[ ! -e "$OLD_STATE/$file" ]] || cp "$OLD_STATE/$file" "$STATE/$file"
done
clang -fobjc-arc -framework Foundation -F/System/Library/PrivateFrameworks -framework CoreBrightness \
  "$ROOT/nshift.m" -o "$ROOT/bin/nshift"
if [[ -f "$ROOT/nvbrightness.m" ]]; then
  clang -fobjc-arc -framework Foundation -framework AppKit -framework CoreGraphics \
    -F/System/Library/PrivateFrameworks -framework DisplayServices \
    "$ROOT/nvbrightness.m" -o "$ROOT/bin/nvbrightness"
fi
"$ROOT/app/build.sh"
ln -sfn "$ROOT/nightvision" "$CLI"
chmod +x "$ROOT/nightvision" "$ROOT/app/build.sh"

"$CLI" schedule-sync

menubar_label="com.aneyman.nightvision.menubar"
menubar_target="$AGENTS/$menubar_label.plist"
sed -e "s|__APP__|$APP|g" -e "s|__STATE__|$STATE|g" \
  "$ROOT/launchd/menubar.plist.template" > "$menubar_target"
launchctl bootout "gui/$UID/$menubar_label" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$menubar_target"

pkill -f '/NightVision.app/Contents/MacOS/NightVision' 2>/dev/null || true
/usr/bin/open -a "$APP"
printf 'Night Vision installed from %s\n' "$ROOT"
