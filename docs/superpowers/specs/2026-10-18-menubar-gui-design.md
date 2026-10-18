# Menubar GUI Design — monitor-layouts

**Date:** 2026-10-18
**Status:** Approved

---

## Overview

Add a macOS menubar app to monitor-layouts that provides a GUI for capture/restore, a manual/auto mode toggle, and automatic layout restoration when a monitor is connected. Built in Python using `rumps`. The existing `capture.sh` and `restore.sh` scripts are unchanged — the app shells out to them.

---

## File Structure

```
monitor-layouts/
  app.py                                ← rumps menubar app
  watcher.py                            ← display change detector, run by Launch Agent
  capture.sh                            ← unchanged
  restore.sh                            ← unchanged
  install.sh                            ← updated: installs rumps, registers Launch Agent
  com.monitor-layouts.watcher.plist     ← Launch Agent definition
```

Config at `~/.config/monitor-layouts/`:
- `auto_mode.flag` — exists = auto on, absent = auto off
- `last_restore.json` — result of last restore (counts + timestamp)
- `last_known_display.txt` — last seen external monitor ID (for change detection)

---

## Menubar App (`app.py`)

**Icon:** `🖥` in the menubar.

**Menu layout:**
```
🖥 Monitor Layouts
─────────────────────
📺 Home Monitor (1920x1080)     ← current monitor name + res, disabled (not clickable)
─────────────────────
📸 Capture Layout
♻️  Restore Layout
─────────────────────
⚡ Auto Mode: ON  ●             ← toggle, green dot = on, grey = off
─────────────────────
🕐 Last restore: 6 restored, 1 skipped   ← from last_restore.json, disabled
─────────────────────
Quit
```

**Behavior:**
- Capture and Restore run in background threads so the UI doesn't freeze
- macOS notification fires on completion with result summary
- If no external monitor is connected: Capture and Restore are greyed out, monitor line shows `No external monitor`
- Auto Mode toggle writes/removes `auto_mode.flag` — no launchctl calls after first install
- Monitor name refreshes whenever the connected display changes
- `last_restore` line reads `last_restore.json` on every menu open

---

## Watcher (`watcher.py`)

Runs as a background process managed by launchd. Loop:

1. Poll `displayplacer list` every 5 seconds
2. Parse current external monitor ID
3. Compare against `last_known_display.txt`
4. If **new monitor connected** and `auto_mode.flag` exists → run `restore.sh`, write result to `last_restore.json`
5. Update `last_known_display.txt`
6. If **monitor disconnected** → write `none` to `last_known_display.txt`, do nothing else

The watcher runs continuously regardless of auto mode state. Only the presence of `auto_mode.flag` determines whether it acts on a display change.

---

## Launch Agent (`com.monitor-layouts.watcher.plist`)

Installed to `~/Library/LaunchAgents/` by `install.sh`.

Key properties:
- `Label`: `com.monitor-layouts.watcher`
- `ProgramArguments`: `[python3, /path/to/watcher.py]`
- `RunAtLoad`: `true`
- `KeepAlive`: `true` — launchd auto-restarts if it crashes

The menubar app toggle only touches `auto_mode.flag` — the Launch Agent is loaded once at install and stays running permanently.

---

## Notifications

Sent via `osascript` from app and watcher:

| Event | Notification |
|---|---|
| Capture success | `📸 Layout captured` |
| Restore success | `✅ Layout restored — 6 restored, 1 skipped` |
| Restore error | `⚠️ Restore failed — no saved layout for this monitor` |
| Auto mode trigger | `🖥 Monitor connected — restoring layout...` |

---

## State File: `last_restore.json`

Written by `restore.sh` output parsing (in both manual and auto flows):

```json
{
  "timestamp": "2026-10-18T09:32:00",
  "ok": 6,
  "skipped": 1,
  "failed": 0,
  "monitor_id": "D2AAF58D-42FA-4BA6-ADFD-2D813285B3C4"
}
```

---

## Error Handling

| Condition | Behavior |
|---|---|
| `displayplacer` not installed | Monitor line shows `⚠️ displayplacer not found` |
| `yabai` not running | Notification: `Start yabai with: yabai --start-service` |
| No saved layout for monitor | Notification: `No saved layout — run Capture first` |
| `restore.sh` exits non-zero | Notification shows the error message |

---

## Install Changes

`install.sh` additions:
1. `pip3 install rumps`
2. Copy `com.monitor-layouts.watcher.plist` to `~/Library/LaunchAgents/` with correct absolute paths substituted
3. `launchctl load ~/Library/LaunchAgents/com.monitor-layouts.watcher.plist`
4. Print instructions to start the menubar app: `python3 app.py`
