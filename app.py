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
    """Return (id, label) of connected external monitor, or (None, label)."""
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
            label = f"📺 External ({current_res})" if current_res else "📺 External Monitor"
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
    """Return display string for last restore."""
    try:
        with open(LAST_JSON) as f:
            data = json.load(f)
        ok      = data.get("ok", 0)
        skipped = data.get("skipped", 0)
        failed  = data.get("failed", 0)
        ts      = data.get("timestamp", "")[:16].replace("T", " ")
        return f"🕐 Last restore: {ok} restored, {skipped} skipped, {failed} failed  ({ts})"
    except (FileNotFoundError, json.JSONDecodeError):
        return "🕐 Last restore: none yet"


def notify(title, message):
    script = f'display notification "{message}" with title "{title}"'
    try:
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=5)
    except subprocess.TimeoutExpired:
        pass


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
