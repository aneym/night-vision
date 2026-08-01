#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
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
  internal) ensure_brew_package brightness brightness ;;
  *) printf 'Unsupported display backend: %s\n' "$backend" >&2; exit 1 ;;
esac

for file in phase override; do
  [[ -e "$STATE/$file" ]] || [[ ! -e "$OLD_STATE/$file" ]] || cp "$OLD_STATE/$file" "$STATE/$file"
done
clang -fobjc-arc -framework Foundation -F/System/Library/PrivateFrameworks -framework CoreBrightness \
  "$ROOT/nshift.m" -o "$ROOT/bin/nshift"
"$ROOT/app/build.sh"
ln -sfn "$ROOT/nightvision" "$CLI"
chmod +x "$ROOT/nightvision" "$ROOT/app/build.sh"

labels=()
while IFS=$'\t' read -r id time; do
  hour=$((10#${time%:*}))
  minute=$((10#${time#*:}))
  label="com.aneyman.nightvision.$id"
  target="$AGENTS/$label.plist"
  sed -e "s|__PHASE__|$id|g" -e "s|__CLI__|$CLI|g" -e "s|__HOUR__|$hour|g" \
    -e "s|__MINUTE__|$minute|g" -e "s|__STATE__|$STATE|g" \
    "$ROOT/launchd/phase.plist.template" > "$target"
  labels+=("$label")
done < <(jq -r '.phases[] | [.id, .time] | @tsv' "$CONFIG")

menubar_label="com.aneyman.nightvision.menubar"
menubar_target="$AGENTS/$menubar_label.plist"
sed -e "s|__APP__|$APP|g" -e "s|__STATE__|$STATE|g" \
  "$ROOT/launchd/menubar.plist.template" > "$menubar_target"
labels+=("$menubar_label")

for label in "${labels[@]}"; do
  launchctl bootout "gui/$UID/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$AGENTS/$label.plist"
done

pkill -f '/NightVision.app/Contents/MacOS/NightVision' 2>/dev/null || true
/usr/bin/open -a "$APP"
printf 'Night Vision installed from %s\n' "$ROOT"
