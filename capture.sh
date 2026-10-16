#!/bin/bash
# capture.sh — Snapshot current window positions for the connected external monitor
# Usage: ./capture.sh
# Requires: displayplacer (brew install displayplacer), yabai (brew install yabai)

LAYOUTS_DIR="$HOME/.config/monitor-layouts/layouts"
mkdir -p "$LAYOUTS_DIR"

# Ensure yabai is running
if ! yabai -m query --windows &>/dev/null; then
  echo "⚙️  Starting yabai..."
  yabai --start-service &>/dev/null
  sleep 2
  if ! yabai -m query --windows &>/dev/null; then
    echo "❌ Could not start yabai. Run: yabai --start-service"
    exit 1
  fi
fi

# Get the persistent ID of the external (non-built-in) monitor
EXTERNAL_ID=$(displayplacer list 2>/dev/null | awk '
  /Persistent screen id:/ { id = $NF }
  /Type:.*external/       { print id; exit }
')

if [ -z "$EXTERNAL_ID" ]; then
  echo "❌ No external monitor detected. Connect a monitor first."
  exit 1
fi

LAYOUT_FILE="$LAYOUTS_DIR/$EXTERNAL_ID.json"

echo "📸 Capturing layout for monitor: $EXTERNAL_ID"

# Capture window state via yabai (handles Electron, fullscreen, Spaces)
yabai -m query --windows > "$LAYOUT_FILE" 2>&1
if [ $? -ne 0 ] || grep -q "failed to connect" "$LAYOUT_FILE"; then
  echo "❌ yabai is not running. Start it with: yabai --start-service"
  rm -f "$LAYOUT_FILE"
  exit 1
fi

# Save the current displayplacer command (display arrangement) for this monitor
DISPLAY_CONFIG_FILE="$HOME/.config/monitor-layouts/display-configs.json"
DISPLAY_CMD_FILE="$(mktemp)"
displayplacer list 2>/dev/null | grep "^displayplacer" | tail -1 > "$DISPLAY_CMD_FILE"

python3 - "$EXTERNAL_ID" "$DISPLAY_CONFIG_FILE" "$DISPLAY_CMD_FILE" <<'PYEOF'
import json, sys

monitor_id  = sys.argv[1]
config_file = sys.argv[2]
cmd_file    = sys.argv[3]

with open(cmd_file) as f:
    display_cmd = f.read().strip()

try:
    with open(config_file) as f:
        configs = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    configs = {}

configs[monitor_id] = display_cmd

with open(config_file, 'w') as f:
    json.dump(configs, f, indent=2)
PYEOF

rm -f "$DISPLAY_CMD_FILE"

echo "✅ Layout saved to: $LAYOUT_FILE"
echo "✅ Display arrangement saved."
echo ""
echo "Windows captured:"
python3 -c "
import json, sys

with open('$LAYOUT_FILE') as f:
    wins = json.load(f)

for w in wins:
    fs = ' [FULLSCREEN]' if w.get('is-native-fullscreen') else ''
    print(f\"  {w['app']:30s}  space={w['space']}  pos=({int(w['frame']['x'])},{int(w['frame']['y'])})  size=({int(w['frame']['w'])}x{int(w['frame']['h'])}){fs}\")
print(f'\nTotal: {len(wins)} windows')
"
