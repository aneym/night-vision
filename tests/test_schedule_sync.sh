#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$TMP/agents"
cat > "$TMP/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$NIGHT_VISION_TEST_LOG"
EOF
chmod +x "$TMP/launchctl"
cat > "$TMP/config.json" <<'EOF'
{"display":"internal","scheduleEnabled":false,"scheduleOffOn":"TODAY","appearance":"dark","keySteps":{"brightness":7},"phases":[{"id":"day","time":"06:42","lum":20,"warmth":0},{"id":"evening","time":"18:15","lum":18,"warmth":60},{"id":"winddown","time":"21:10","lum":10,"warmth":80},{"id":"cutoff","time":"23:05","lum":4,"warmth":100}]}
EOF
sed -i '' "s/TODAY/$(date +%F)/" "$TMP/config.json"
export NIGHT_VISION_CONFIG="$TMP/config.json"
export NIGHT_VISION_AGENTS_DIR="$TMP/agents"
export NIGHT_VISION_LAUNCHCTL="$TMP/launchctl"
export NIGHT_VISION_CLI="$ROOT/nightvision"
export NIGHT_VISION_TEST_LOG="$TMP/launchctl.log"

"$ROOT/nightvision" schedule-sync
[[ "$(grep -c 'bootout ' "$NIGHT_VISION_TEST_LOG")" == 4 ]]
# Off today: only the day job stays loaded, so tomorrow can turn the schedule back on.
[[ "$(grep -c 'bootstrap ' "$NIGHT_VISION_TEST_LOG")" == 1 ]]
grep 'bootstrap ' "$NIGHT_VISION_TEST_LOG" | grep -q 'nightvision.day.plist'
grep -A1 '<key>Minute</key>' "$TMP/agents/com.aneyman.nightvision.day.plist" | grep -q '<integer>42</integer>'
"$ROOT/nightvision" auto day
[[ "$(jq -r .scheduleEnabled "$TMP/config.json")" == false ]]

# Switched off yesterday: the next check turns it back on and loads every job.
jq '.scheduleOffOn = "2000-01-01"' "$TMP/config.json" > "$TMP/next.json"
mv "$TMP/next.json" "$TMP/config.json"
: > "$NIGHT_VISION_TEST_LOG"
"$ROOT/nightvision" schedule-check
[[ "$(jq -r '.scheduleEnabled, (.scheduleOffOn // "none")' "$TMP/config.json" | paste -sd, -)" == "true,none" ]]
[[ "$(grep -c 'bootstrap ' "$NIGHT_VISION_TEST_LOG")" == 4 ]]

jq '.scheduleEnabled = true | .phases[0].time = "08:07"' "$TMP/config.json" > "$TMP/next.json"
mv "$TMP/next.json" "$TMP/config.json"
: > "$NIGHT_VISION_TEST_LOG"
"$ROOT/nightvision" schedule-sync
[[ "$(grep -c 'bootstrap ' "$NIGHT_VISION_TEST_LOG")" == 4 ]]
grep -A1 '<key>Hour</key>' "$TMP/agents/com.aneyman.nightvision.day.plist" | grep -q '<integer>8</integer>'
grep -A1 '<key>Minute</key>' "$TMP/agents/com.aneyman.nightvision.day.plist" | grep -q '<integer>7</integer>'
jq '.phases[1].time = "08:07"' "$TMP/config.json" > "$TMP/next.json"
mv "$TMP/next.json" "$TMP/config.json"
: > "$NIGHT_VISION_TEST_LOG"
if "$ROOT/nightvision" schedule-sync 2>"$TMP/error"; then
  printf 'duplicate phase time was accepted\n' >&2
  exit 1
fi
grep -q 'duplicate time' "$TMP/error"
[[ ! -s "$NIGHT_VISION_TEST_LOG" ]]
printf 'schedule sync: off lasts one day; enabled jobs use edited times\n'
