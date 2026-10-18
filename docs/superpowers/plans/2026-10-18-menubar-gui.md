# Menubar GUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS menubar app that provides a GUI for capture/restore, an auto-mode toggle, and automatic layout restoration via a Launch Agent watcher.

**Architecture:** A `rumps`-based menubar app (`app.py`) shells out to existing `capture.sh` and `restore.sh` scripts. A separate `watcher.py` polls for display changes every 5 seconds and is managed by a launchd Launch Agent. Auto mode is controlled by the presence of `~/.config/monitor-layouts/auto_mode.flag`.

**Tech Stack:** Python 3, `rumps` 0.4.0, `osascript` for notifications, `displayplacer` for display detection, launchd for Launch Agent management.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `app.py` | Create | rumps menubar app |
| `watcher.py` | Create | Display change poller, runs restore when monitor connects |
| `com.monitor-layouts.watcher.plist` | Create | Launch Agent definition |
| `restore.sh` | Modify | Write `last_restore.json` after restore completes |
| `install.sh` | Modify | Install rumps, register Launch Agent |

---

### Task 1: Make `restore.sh` write `last_restore.json`

**Files:**
- Modify: `restore.sh`

The menubar app and watcher both need to read restore results. `restore.sh` must write `~/.config/monitor-layouts/last_restore.json` after each run.

- [ ] **Step 1: Add JSON output at end of restore.sh Python block**

In `restore.sh`, find the final `print(f"\n✅ Done...")` line inside the `PYEOF` block and replace it with:

```python
import datetime
summary = {
    "timestamp": datetime.datetime.now().isoformat(timespec='seconds'),
    "ok": ok,
    "skipped": skipped,
    "failed": failed,
    "monitor_id": ""  # filled in below
}

# Write last_restore.json
config_dir = os.path.expanduser("~/.config/monitor-layouts")
with open(os.path.join(config_dir, "last_restore.json"), "w") as f:
    json.dump(summary, f, indent=2)

print(f"\n✅ Done — {ok} restored, {skipped} skipped (not running), {failed} failed")
```

Also add `import os` and `import datetime` to the imports at the top of the Python block (which currently has `import json, subprocess, sys, time`):

```python
import json, os, subprocess, sys, time, datetime
```

- [ ] **Step 2: Pass monitor ID into the Python block**

The `python3 - "$LAYOUT_FILE"` invocation needs the monitor ID too. Change the invocation line from:

```bash
python3 - "$LAYOUT_FILE" <<'PYEOF'
```

to:

```bash
python3 - "$LAYOUT_FILE" "$EXTERNAL_ID" <<'PYEOF'
```

And at the top of the Python block, add:

```python
layout_file = sys.argv[1]
monitor_id  = sys.argv[2]
```

Then update the summary dict:

```python
summary = {
    "timestamp": datetime.datetime.now().isoformat(timespec='seconds'),
    "ok": ok,
    "skipped": skipped,
    "failed": failed,
    "monitor_id": monitor_id
}
```

- [ ] **Step 3: Test manually**

```bash
cd ~/Documents/personal/monitor-layouts
./restore.sh
cat ~/.config/monitor-layouts/last_restore.json
```

Expected output — a valid JSON file like:
```json
{
  "timestamp": "2026-10-18T10:00:00",
  "ok": 6,
  "skipped": 1,
  "failed": 0,
  "monitor_id": "D2AAF58D-42FA-4BA6-ADFD-2D813285B3C4"
}
```

- [ ] **Step 4: Commit**

```bash
git add restore.sh
git commit -m "feat: write last_restore.json after each restore"
```

---

### Task 2: Create the Launch Agent plist template

**Files:**
- Create: `com.monitor-layouts.watcher.plist`

- [ ] **Step 1: Create the plist file**

Create `com.monitor-layouts.watcher.plist` in the project root with this content (use `INSTALL_DIR` as a placeholder — `install.sh` will substitute it):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.monitor-layouts.watcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>INSTALL_DIR/watcher.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>INSTALL_DIR/watcher.log</string>
    <key>StandardErrorPath</key>
    <string>INSTALL_DIR/watcher.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Commit**

```bash
git add com.monitor-layouts.watcher.plist
git commit -m "feat: add Launch Agent plist template"
```

---

### Task 3: Create `watcher.py`

**Files:**
- Create: `watcher.py`

- [ ] **Step 1: Create watcher.py**

```python
#!/usr/bin/env python3
"""
watcher.py — Poll for display changes and auto-restore layouts.
Run by launchd Launch Agent. Polls every 5 seconds.
"""

import os
import subprocess
import sys
import time

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR   = os.path.expanduser("~/.config/monitor-layouts")
FLAG_FILE    = os.path.join(CONFIG_DIR, "auto_mode.flag")
LAST_DISPLAY = os.path.join(CONFIG_DIR, "last_known_display.txt")
RESTORE_SH   = os.path.join(SCRIPT_DIR, "restore.sh")


def get_external_monitor_id():
    """Return persistent ID of connected external monitor, or None."""
    try:
        result = subprocess.run(
            ["displayplacer", "list"],
            capture_output=True, text=True, timeout=10
        )
        current_id = None
        for line in result.stdout.splitlines():
            if "Persistent screen id:" in line:
                current_id = line.split()[-1]
            if "external screen" in line.lower() or ("Type:" in line and "external" in line.lower()):
                return current_id
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def read_last_display():
    """Return last known external monitor ID, or None."""
    try:
        with open(LAST_DISPLAY) as f:
            val = f.read().strip()
            return None if val == "none" else val
    except FileNotFoundError:
        return None


def write_last_display(monitor_id):
    """Persist current external monitor ID (or 'none')."""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(LAST_DISPLAY, "w") as f:
        f.write(monitor_id if monitor_id else "none")


def notify(title, message):
    """Send a macOS notification via osascript."""
    script = f'display notification "{message}" with title "{title}"'
    subprocess.run(["osascript", "-e", script], capture_output=True)


def auto_mode_enabled():
    return os.path.exists(FLAG_FILE)


def run_restore():
    """Run restore.sh and return (success, message)."""
    result = subprocess.run(
        ["bash", RESTORE_SH],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        # Parse summary line from output
        for line in reversed(result.stdout.splitlines()):
            if "Done —" in line:
                return True, line.strip().lstrip("✅ ").strip()
        return True, "Layout restored"
    else:
        err = result.stderr.strip() or result.stdout.strip()
        return False, err[:100]  # cap length for notification


def main():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    print("monitor-layouts watcher started", flush=True)

    while True:
        current = get_external_monitor_id()
        last    = read_last_display()

        if current and current != last:
            # New monitor connected
            write_last_display(current)
            if auto_mode_enabled():
                notify("🖥 Monitor Layouts", "Monitor connected — restoring layout...")
                success, msg = run_restore()
                if success:
                    notify("✅ Monitor Layouts", msg)
                else:
                    notify("⚠️ Monitor Layouts", f"Restore failed: {msg}")
        elif not current and last is not None:
            # Monitor disconnected
            write_last_display(None)

        time.sleep(5)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Make executable**

```bash
chmod +x watcher.py
```

- [ ] **Step 3: Test watcher detection manually**

```bash
cd ~/Documents/personal/monitor-layouts
python3 watcher.py &
WATCHER_PID=$!
sleep 6
kill $WATCHER_PID
cat ~/.config/monitor-layouts/last_known_display.txt
```

Expected: file contains the current external monitor ID (or `none` if none connected).

- [ ] **Step 4: Commit**

```bash
git add watcher.py
git commit -m "feat: add display change watcher"
```

---

### Task 4: Create `app.py` — menubar app

**Files:**
- Create: `app.py`

- [ ] **Step 1: Create app.py**

```python
#!/usr/bin/env python3
"""
app.py — macOS menubar app for monitor-layouts.
Usage: python3 app.py
Requires: pip3 install rumps
"""

import json
import os
import subprocess
import threading
import rumps

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR  = os.path.expanduser("~/.config/monitor-layouts")
FLAG_FILE   = os.path.join(CONFIG_DIR, "auto_mode.flag")
LAST_JSON   = os.path.join(CONFIG_DIR, "last_restore.json")
CAPTURE_SH  = os.path.join(SCRIPT_DIR, "capture.sh")
RESTORE_SH  = os.path.join(SCRIPT_DIR, "restore.sh")


def get_external_monitor():
    """Return (id, label) of connected external monitor, or (None, None)."""
    try:
        result = subprocess.run(
            ["displayplacer", "list"],
            capture_output=True, text=True, timeout=10
        )
    except FileNotFoundError:
        return None, "⚠️ displayplacer not found"
    except subprocess.TimeoutExpired:
        return None, "⚠️ displayplacer timed out"

    current_id = None
    current_res = None
    for line in result.stdout.splitlines():
        if "Persistent screen id:" in line:
            current_id = line.split()[-1]
            current_res = None
        if "Resolution:" in line:
            current_res = line.split(":", 1)[-1].strip()
        if "Type:" in line and "external" in line.lower() and current_id:
            label = f"📺 {current_res}" if current_res else "📺 External Monitor"
            return current_id, label

    return None, "No external monitor"


def auto_mode_enabled():
    return os.path.exists(FLAG_FILE)


def set_auto_mode(enabled):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    if enabled:
        open(FLAG_FILE, "w").close()
    else:
        try:
            os.remove(FLAG_FILE)
        except FileNotFoundError:
            pass


def read_last_restore():
    """Return display string for last restore, or empty string."""
    try:
        with open(LAST_JSON) as f:
            data = json.load(f)
        ok      = data.get("ok", 0)
        skipped = data.get("skipped", 0)
        failed  = data.get("failed", 0)
        ts      = data.get("timestamp", "")[:16].replace("T", " ")
        return f"🕐 Last: {ok} ok, {skipped} skipped, {failed} failed  ({ts})"
    except (FileNotFoundError, json.JSONDecodeError):
        return "🕐 Last restore: none yet"


def notify(title, message):
    script = f'display notification "{message}" with title "{title}"'
    subprocess.run(["osascript", "-e", script], capture_output=True)


def run_script(script_path):
    """Run a shell script, return (returncode, stdout, stderr)."""
    result = subprocess.run(
        ["bash", script_path],
        capture_output=True, text=True
    )
    return result.returncode, result.stdout, result.stderr


class MonitorLayoutsApp(rumps.App):
    def __init__(self):
        super().__init__("🖥", quit_button=None)

        self.monitor_item   = rumps.MenuItem("Checking...", callback=None)
        self.capture_item   = rumps.MenuItem("📸 Capture Layout", callback=self.capture)
        self.restore_item   = rumps.MenuItem("♻️  Restore Layout", callback=self.restore)
        self.auto_item      = rumps.MenuItem("", callback=self.toggle_auto)
        self.last_item      = rumps.MenuItem("", callback=None)
        self.quit_item      = rumps.MenuItem("Quit", callback=rumps.quit_application)

        self.menu = [
            self.monitor_item,
            None,
            self.capture_item,
            self.restore_item,
            None,
            self.auto_item,
            None,
            self.last_item,
            None,
            self.quit_item,
        ]

        self.refresh_state()

    def refresh_state(self):
        """Update monitor name, auto mode label, last restore label."""
        monitor_id, label = get_external_monitor()
        self.monitor_item.title = label

        has_monitor = monitor_id is not None
        self.capture_item.set_callback(self.capture if has_monitor else None)
        self.restore_item.set_callback(self.restore if has_monitor else None)

        enabled = auto_mode_enabled()
        dot = "🟢" if enabled else "⚪"
        self.auto_item.title = f"⚡ Auto Mode: {'ON' if enabled else 'OFF'}  {dot}"

        self.last_item.title = read_last_restore()
        self.last_item.set_callback(None)

    @rumps.clicked("🖥")
    def menu_opened(self, _):
        self.refresh_state()

    def capture(self, _):
        self.capture_item.title = "📸 Capturing..."
        def run():
            code, out, err = run_script(CAPTURE_SH)
            if code == 0:
                notify("📸 Monitor Layouts", "Layout captured successfully")
            else:
                msg = err.strip() or out.strip()
                notify("⚠️ Monitor Layouts", f"Capture failed: {msg[:80]}")
            self.capture_item.title = "📸 Capture Layout"
            self.refresh_state()
        threading.Thread(target=run, daemon=True).start()

    def restore(self, _):
        self.restore_item.title = "♻️  Restoring..."
        def run():
            code, out, err = run_script(RESTORE_SH)
            if code == 0:
                for line in reversed(out.splitlines()):
                    if "Done —" in line:
                        notify("✅ Monitor Layouts", line.strip().lstrip("✅ ").strip())
                        break
                else:
                    notify("✅ Monitor Layouts", "Layout restored")
            else:
                msg = err.strip() or out.strip()
                notify("⚠️ Monitor Layouts", f"Restore failed: {msg[:80]}")
            self.restore_item.title = "♻️  Restore Layout"
            self.refresh_state()
        threading.Thread(target=run, daemon=True).start()

    def toggle_auto(self, _):
        enabled = not auto_mode_enabled()
        set_auto_mode(enabled)
        self.refresh_state()
        state = "enabled" if enabled else "disabled"
        notify("⚡ Monitor Layouts", f"Auto mode {state}")


if __name__ == "__main__":
    MonitorLayoutsApp().run()
```

- [ ] **Step 2: Make executable**

```bash
chmod +x app.py
```

- [ ] **Step 3: Run and verify menubar app appears**

```bash
python3 app.py &
```

Expected: `🖥` icon appears in the menubar. Click it — you should see the monitor name, Capture, Restore, Auto Mode toggle, and last restore status.

- [ ] **Step 4: Kill the test run**

```bash
kill %1
```

- [ ] **Step 5: Commit**

```bash
git add app.py
git commit -m "feat: add rumps menubar app"
```

---

### Task 5: Update `install.sh`

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Add rumps install + Launch Agent registration to install.sh**

At the end of `install.sh`, before the final success message, add:

```bash
# Install rumps
echo "📦 Installing rumps..."
pip3 install rumps --break-system-packages --quiet 2>/dev/null || \
  pip3 install rumps --quiet 2>/dev/null || \
  echo "⚠️  Could not install rumps automatically. Run: pip3 install rumps"

# Install Launch Agent
PLIST_SRC="$(dirname "$0")/com.monitor-layouts.watcher.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.monitor-layouts.watcher.plist"
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

# Substitute INSTALL_DIR placeholder with actual path
sed "s|INSTALL_DIR|$INSTALL_DIR|g" "$PLIST_SRC" > "$PLIST_DEST"

# Unload first if already loaded (avoid duplicate)
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"
echo "✅ Launch Agent registered (watcher starts at login)"

echo ""
echo "✅ All done! Start the menubar app with:"
echo "   python3 $INSTALL_DIR/app.py &"
echo ""
echo "   Add that line to your shell profile to auto-start at login."
```

- [ ] **Step 2: Test install.sh runs without errors**

```bash
bash install.sh
```

Expected: no errors, ends with instructions to start `app.py`.

- [ ] **Step 3: Verify Launch Agent is loaded**

```bash
launchctl list | grep monitor-layouts
```

Expected: a line containing `com.monitor-layouts.watcher`.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat: update install.sh for rumps and Launch Agent"
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add menubar app section to README**

After the existing `## Usage` section, add:

```markdown
## Menubar App

Start the menubar app for a GUI with one-click capture/restore and auto mode:

```bash
python3 app.py &
```

A `🖥` icon appears in your menubar. Click it to:
- See which monitor is connected
- Capture or restore the current layout
- Toggle **Auto Mode** — automatically restores your layout whenever a monitor is connected

To start the app automatically at login, add this to your `~/.zprofile`:
```bash
python3 /path/to/monitor-layouts/app.py &
```

### Auto Mode

When Auto Mode is ON, a background watcher polls for display changes every 5 seconds. When a new monitor is detected, it automatically runs `restore.sh` and sends a macOS notification with the result.

The watcher runs as a Launch Agent (`com.monitor-layouts.watcher`) — it starts at login and restarts automatically if it crashes. Auto Mode ON/OFF just controls whether it acts on display changes.
```

- [ ] **Step 2: Commit and push everything**

```bash
git add README.md
git commit -m "docs: add menubar app usage to README"
git push
```

---

## Self-Review

**Spec coverage check:**
- ✅ `app.py` with all menu items (monitor name, capture, restore, auto toggle, last restore, quit)
- ✅ Background threads for capture/restore so UI doesn't freeze
- ✅ Greyed out items when no monitor connected (via `set_callback(None)`)
- ✅ `watcher.py` polls every 5 seconds, detects connect/disconnect
- ✅ `auto_mode.flag` controls watcher behavior
- ✅ Launch Agent with `KeepAlive: true`
- ✅ `last_restore.json` written by `restore.sh`
- ✅ All 4 notification types covered
- ✅ Error handling for missing `displayplacer`, failed scripts
- ✅ `install.sh` updated with rumps install + Launch Agent registration

**Placeholder scan:** No TBDs, all code blocks complete.

**Type consistency:**
- `get_external_monitor()` returns `(id, label)` — used consistently in `app.py` and `watcher.py` uses its own copy (intentional — watcher is independent)
- `run_script()` returns `(returncode, stdout, stderr)` — used correctly in capture/restore callbacks
- `FLAG_FILE`, `CONFIG_DIR` path constants defined once per file and used consistently
