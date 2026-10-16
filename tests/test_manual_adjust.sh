#!/bin/bash
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
ROOT="$TMP/root"
DEV="$TMP/device"
mkdir -p "$ROOT/bin" "$TMP/fakebin" "$DEV" "$HOME"
cp "$SRC/nightvision" "$ROOT/nightvision"

cat > "$ROOT/bin/nvbrightness" <<'FAKE'
#!/bin/bash
case "$1" in
  set) printf '%s\n' "$2" > "$NV_DEV/brightness" ;;
  get) cat "$NV_DEV/brightness" ;;
  *) exit 1 ;;
esac
FAKE
cat > "$ROOT/bin/nshift" <<'FAKE'
#!/bin/bash
case "$1" in
  temp) printf '%s\n' "$2" > "$NV_DEV/warmth" ;;
  off) printf '0\n' > "$NV_DEV/warmth" ;;
  status) w=$(cat "$NV_DEV/warmth"); if (( w > 0 )); then echo "enabled=yes strength=$w"; else echo "enabled=no"; fi ;;
esac
FAKE
cat > "$TMP/fakebin/osascript" <<'FAKE'
#!/bin/bash
args="$*"
case "$args" in
  *"set dark mode to "*) d="${args##*set dark mode to }"; printf '%s\n' "${d%% *}" > "$NV_DEV/dark" ;;
  *"get dark mode"*) cat "$NV_DEV/dark" ;;
esac
FAKE
cat > "$TMP/fakebin/defaults" <<'FAKE'
#!/bin/bash
FAKE
cat > "$TMP/fakebin/date" <<'FAKE'
#!/bin/bash
exec /bin/date -j -f '%Y-%m-%d %H:%M' "$NV_NOW" "$@"
FAKE
chmod +x "$ROOT/nightvision" "$ROOT/bin/"* "$TMP/fakebin/"*
printf '0\n' > "$DEV/warmth"
printf '0.5\n' > "$DEV/brightness"

cat > "$TMP/config.json" <<'JSON'
{"display":"internal","phases":[{"id":"day","time":"07:00","lum":50,"warmth":0},{"id":"evening","time":"18:00","lum":30,"warmth":60},{"id":"winddown","time":"21:00","lum":15,"warmth":90},{"id":"cutoff","time":"23:00","lum":5,"warmth":100}]}
JSON
export NIGHT_VISION_CONFIG="$TMP/config.json"
export NIGHT_VISION_OSASCRIPT="$TMP/fakebin/osascript"
export NIGHT_VISION_DEFAULTS="$TMP/fakebin/defaults"
export NV_DEV="$DEV"
export PATH="$TMP/fakebin:$PATH"
nv() { "$ROOT/nightvision" "$@" >/dev/null; }
state() { "$ROOT/nightvision" status-json | jq -r "[.schedule, .paused, .manual, .lum, .warmth] | map(tostring) | join(\",\")"; }
expect() {
  local got
  got=$(state)
  [[ "$got" == "$1" ]] || { printf 'at %s after %s: expected %s, got %s\n' "$NV_NOW" "$2" "$1" "$got" >&2; exit 1; }
}

export NV_NOW="2026-10-15 18:00"
nv auto evening
expect "true,false,false,30,60" "evening starts"

export NV_NOW="2026-10-15 19:30"
nv lum 70
nv temp 20
expect "true,false,true,70,20" "manual adjust mid-evening"
nv auto evening
expect "true,false,true,70,20" "a repeat evening run"

export NV_NOW="2026-10-15 21:00"
expect "true,false,false,70,20" "the winddown boundary passes"
nv auto winddown
expect "true,false,false,15,90" "winddown starts"

export NV_NOW="2026-10-15 22:00"
nv pause
nv auto cutoff
expect "true,true,false,15,90" "pause, then cutoff"

export NV_NOW="2026-10-16 07:00"
nv auto day
expect "true,false,false,50,0" "the next day starts"
printf 'manual adjust: lasts until the next phase; schedule stays on; pause still skips\n'
