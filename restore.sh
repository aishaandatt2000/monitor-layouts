#!/bin/bash
# restore.sh — Restore saved window positions for the connected external monitor
# Usage: ./restore.sh
# Requires: displayplacer (brew install displayplacer), yabai (brew install yabai)

LAYOUTS_DIR="$HOME/.config/monitor-layouts/layouts"
DISPLAY_CONFIG_FILE="$HOME/.config/monitor-layouts/display-configs.json"

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

if [ ! -f "$LAYOUT_FILE" ]; then
  echo "❌ No saved layout for monitor: $EXTERNAL_ID"
  echo "   Run ./capture.sh first to save a layout."
  exit 1
fi

echo "🖥  Restoring layout for monitor: $EXTERNAL_ID"

# Step 1: Restore display arrangement (primary screen, positions)
if [ -f "$DISPLAY_CONFIG_FILE" ]; then
  DISPLAY_CMD=$(python3 -c "
import json, sys
with open('$DISPLAY_CONFIG_FILE') as f:
    configs = json.load(f)
print(configs.get('$EXTERNAL_ID', ''))
" 2>/dev/null)
  if [ -n "$DISPLAY_CMD" ]; then
    echo "🔧 Applying display arrangement..."
    eval "$DISPLAY_CMD"
    sleep 1
  fi
fi

# Step 2: Restore window positions, spaces, and fullscreen state
echo "📐 Restoring windows..."
python3 - "$LAYOUT_FILE" "$EXTERNAL_ID" <<'PYEOF'
import json, os, subprocess, sys, tempfile, time, datetime
from collections import defaultdict

layout_file = sys.argv[1]
monitor_id = sys.argv[2]

with open(layout_file) as f:
    saved_windows = json.load(f)

# Get currently open windows from yabai
result = subprocess.run(['yabai', '-m', 'query', '--windows'], capture_output=True, text=True)
if result.returncode != 0:
    print("❌ yabai is not running. Start it with: yabai --start-service")
    sys.exit(1)

current_windows = json.load(__import__('io').StringIO(result.stdout))

# Build a map of current display uuid -> index
displays_result = subprocess.run(['yabai', '-m', 'query', '--displays'], capture_output=True, text=True)
current_displays = json.load(__import__('io').StringIO(displays_result.stdout))
current_uuid_to_index = {d['uuid']: d['index'] for d in current_displays}

# Build saved display index -> current display index using uuid stored in each window
# Each saved window has 'display' (index at capture time). We need the uuid for that
# display. yabai windows don't store display uuid directly, but we can infer it:
# The layout file is named after the external monitor uuid (monitor_id).
# At capture time, find which display index the external had by matching frame bounds.
# Simpler: store uuid->index at capture time. Since we don't have that, use frame position:
# external monitor windows have frames with x outside [0, builtin_width].
# Instead, use the most reliable signal: the saved display index for windows whose
# saved frame x > 0 or frame width matches the external monitor resolution.
#
# Cleanest approach: find which saved display index maps to the external monitor uuid
# by looking at current display bounds vs saved window frames.
external_display = next((d for d in current_displays if d['uuid'] == monitor_id), None)
builtin_display  = next((d for d in current_displays if d['uuid'] != monitor_id), None)

# Find what display index external had at capture time:
# windows on the external have frames within its bounds.
saved_external_idx = None
if external_display:
    ext_frame = external_display['frame']
    for w in saved_windows:
        f = w.get('frame', {})
        # If the window's saved frame overlaps the current external display bounds
        if (abs(f.get('x', 0) - ext_frame['x']) < 100 and
                abs(f.get('w', 0) - ext_frame['w']) < 100):
            saved_external_idx = w.get('display')
            break

# Build remap: saved display index -> current display index
display_remap = {}
if saved_external_idx and external_display and builtin_display:
    current_external_idx = external_display['index']
    current_builtin_idx  = builtin_display['index']
    # Figure out saved builtin index (the other one)
    all_saved_display_indices = {w.get('display') for w in saved_windows if w.get('display')}
    saved_builtin_idx = next((i for i in all_saved_display_indices if i != saved_external_idx), None)
    display_remap[saved_external_idx] = current_external_idx
    if saved_builtin_idx:
        display_remap[saved_builtin_idx] = current_builtin_idx

print(f"  🖥  Display remap: {display_remap or 'none (indices unchanged)'}")
# Check how many Spaces exist and create missing ones
spaces_result = subprocess.run(['yabai', '-m', 'query', '--spaces'], capture_output=True, text=True)
current_spaces = json.load(__import__('io').StringIO(spaces_result.stdout))
current_space_count = len(current_spaces)
needed_space_count = max((w.get('space', 0) for w in saved_windows), default=0)

if needed_space_count > current_space_count:
    to_create = needed_space_count - current_space_count
    print(f"  🗂  Creating {to_create} missing Space(s) ({current_space_count} → {needed_space_count})...")
    for _ in range(to_create):
        subprocess.run(['yabai', '-m', 'space', '--create'], capture_output=True)
    time.sleep(0.5)

def match_windows(saved_wins, current_wins):
    """
    Match saved windows to current windows for one app.
    Priority:
      1. Exact title match
      2. Partial title match (any word >3 chars from saved title appears in current title)
      3. Index fallback
    """
    unmatched_current = list(current_wins)
    pairs = []

    # Pass 1: exact title match
    for saved in saved_wins:
        saved_title = saved.get('title', '')
        for cw in unmatched_current:
            if cw.get('title', '') == saved_title:
                pairs.append((saved, cw, 'exact'))
                unmatched_current.remove(cw)
                break

    already_matched_saved = {id(s) for s, _, _ in pairs}

    # Pass 2: partial title match for remaining saved windows
    remaining_saved = [s for s in saved_wins if id(s) not in already_matched_saved]
    for saved in remaining_saved:
        saved_title = saved.get('title', '')
        keywords = [w for w in saved_title.split() if len(w) > 3]
        matched = None
        best_score = 0
        for cw in unmatched_current:
            current_title = cw.get('title', '')
            score = sum(1 for kw in keywords if kw.lower() in current_title.lower())
            if score > best_score:
                best_score = score
                matched = cw
        if matched and best_score > 0:
            pairs.append((saved, matched, 'partial'))
            unmatched_current.remove(matched)
        else:
            pairs.append((saved, None, 'none'))

    # Pass 3: index fallback for unmatched saved windows
    fallback_current = list(unmatched_current)
    final_pairs = []
    fallback_idx = 0
    for saved, cw, method in pairs:
        if cw is None:
            if fallback_idx < len(fallback_current):
                final_pairs.append((saved, fallback_current[fallback_idx], 'index'))
                fallback_idx += 1
        else:
            final_pairs.append((saved, cw, method))

    return final_pairs

# Build lookup: app -> list of windows
current_by_app = defaultdict(list)
for w in current_windows:
    current_by_app[w['app']].append(w)

saved_by_app = defaultdict(list)
for w in saved_windows:
    saved_by_app[w['app']].append(w)

ok = 0
skipped = 0
failed = 0

for app, saved_wins in saved_by_app.items():
    current_wins = current_by_app.get(app, [])
    if not current_wins:
        print(f"  ⏭  {app}: not running, skipping")
        skipped += 1
        continue

    pairs = match_windows(saved_wins, current_wins)

    for saved, win, match_method in pairs:
        if win is None:
            continue
        win_id = win['id']
        frame = saved['frame']
        target_space = saved.get('space')
        is_fullscreen = saved.get('is-native-fullscreen', False)

        # Move to correct space first (non-fullscreen windows only)
        if not is_fullscreen and target_space and win.get('space') != target_space:
            subprocess.run(
                ['yabai', '-m', 'window', str(win_id), '--space', str(target_space)],
                capture_output=True
            )
            time.sleep(0.2)

        # Handle fullscreen
        if is_fullscreen:
            # Remap saved display index to current display index
            target_display = saved.get('display')
            if target_display and display_remap:
                target_display = display_remap.get(target_display, target_display)

            # If currently fullscreen, exit first and wait for animation to finish
            if win.get('is-native-fullscreen'):
                subprocess.run(
                    ['yabai', '-m', 'window', str(win_id), '--toggle', 'native-fullscreen'],
                    capture_output=True
                )
                time.sleep(1.5)

            # Move to correct display. Do NOT move by space — space indices shift
            # when monitors reconnect, so space 2 may now belong to the external
            # monitor even if it was on the MacBook at capture time.
            # For fullscreen windows, display placement is what matters.
            if target_display:
                # Re-query to get current display after potential fullscreen exit
                cur = subprocess.run(['yabai', '-m', 'query', '--windows', '--window', str(win_id)],
                                     capture_output=True, text=True)
                if cur.returncode == 0:
                    import io as _io
                    cur_win = json.load(_io.StringIO(cur.stdout))
                    if cur_win.get('display') != target_display:
                        subprocess.run(
                            ['yabai', '-m', 'window', str(win_id), '--display', str(target_display)],
                            capture_output=True
                        )
                        time.sleep(0.5)

            # Focus, then enter fullscreen via keyboard shortcut on the correct display
            subprocess.run(
                ['yabai', '-m', 'window', str(win_id), '--focus'],
                capture_output=True
            )
            time.sleep(0.3)
            subprocess.run(
                ['osascript', '-e',
                 'tell application "System Events" to keystroke "f" using {command down, control down}'],
                capture_output=True
            )
            print(f"  ✅ {app}: → fullscreen on display {target_display} [{match_method} match]")
            ok += 1
            continue
        elif win.get('is-native-fullscreen'):
            # Was fullscreen at capture but shouldn't be — exit fullscreen
            subprocess.run(
                ['yabai', '-m', 'window', str(win_id), '--toggle', 'native-fullscreen'],
                capture_output=True
            )
            time.sleep(1.5)

        # Set position and size via yabai
        x, y = int(frame['x']), int(frame['y'])
        w_val, h_val = int(frame['w']), int(frame['h'])

        move_result = subprocess.run(
            ['yabai', '-m', 'window', str(win_id), '--move', f'abs:{x}:{y}'],
            capture_output=True, text=True
        )
        resize_result = subprocess.run(
            ['yabai', '-m', 'window', str(win_id), '--resize', f'abs:{w_val}:{h_val}'],
            capture_output=True, text=True
        )

        if move_result.returncode == 0 and resize_result.returncode == 0:
            space_info = f" on space {target_space}" if target_space else ""
            print(f"  ✅ {app}: → ({x},{y}) {w_val}x{h_val}{space_info} [{match_method} match]")
            ok += 1
        else:
            err = (move_result.stderr + resize_result.stderr).strip()
            print(f"  ⚠️  {app}: {err or 'could not reposition'}")
            failed += 1

summary = {
    "timestamp": datetime.datetime.now().isoformat(timespec='seconds'),
    "ok": ok,
    "skipped": skipped,
    "failed": failed,
    "monitor_id": monitor_id
}
config_dir = os.path.expanduser("~/.config/monitor-layouts")
os.makedirs(config_dir, exist_ok=True)
final_path = os.path.join(config_dir, "last_restore.json")
tmp_fd, tmp_path = tempfile.mkstemp(dir=config_dir)
try:
    with os.fdopen(tmp_fd, "w") as f:
        json.dump(summary, f, indent=2)
    os.replace(tmp_path, final_path)
except Exception:
    os.unlink(tmp_path)
    raise

print(f"\n✅ Done — {ok} restored, {skipped} skipped (not running), {failed} failed")
PYEOF
