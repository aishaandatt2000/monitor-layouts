#!/usr/bin/env python3
"""
app.py — macOS menubar app for monitor-layouts.
Usage: .venv/bin/python app.py
"""

import json
import logging
import os
import subprocess
import threading
import rumps

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR  = os.path.expanduser("~/.config/monitor-layouts")
LAST_JSON   = os.path.join(CONFIG_DIR, "last_restore.json")
CAPTURE_SH  = os.path.join(SCRIPT_DIR, "capture.sh")
RESTORE_SH  = os.path.join(SCRIPT_DIR, "restore.sh")
LOG_FILE    = os.path.join(SCRIPT_DIR, "app.log")

os.makedirs(CONFIG_DIR, exist_ok=True)
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger(__name__)


def get_external_monitor():
    """Return (id, label) of connected external monitor, or (None, label)."""
    log.debug("Querying displayplacer for external monitor")
    try:
        result = subprocess.run(
            ["displayplacer", "list"],
            capture_output=True, text=True, timeout=10
        )
    except FileNotFoundError:
        log.error("displayplacer not found")
        return None, "⚠️ displayplacer not found"
    except subprocess.TimeoutExpired:
        log.error("displayplacer timed out")
        return None, "⚠️ displayplacer timed out"

    current_id = None
    current_res = None
    for line in result.stdout.splitlines():
        if "Persistent screen id:" in line:
            current_id = line.split()[-1]
            current_res = None
        if "Resolution:" in line:
            current_res = line.split(":", 1)[-1].strip()
        if "Type:" in line and current_id:
            current_type = line.split(":", 1)[-1].strip()
            if "external" in current_type.lower():
                name = current_type.title()
                label = f"📺 {name} ({current_res})" if current_res else f"📺 {name}"
                log.debug("External monitor detected: id=%s label=%s", current_id, label)
                return current_id, label

    log.debug("No external monitor detected")
    return None, "No Monitor Connected"


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
        log.warning("osascript notification timed out")


def run_script(script_path):
    """Run a shell script, return (returncode, stdout, stderr)."""
    log.info("Running script: %s", script_path)
    try:
        result = subprocess.run(
            ["bash", script_path],
            capture_output=True, text=True, timeout=120
        )
        log.debug("Script exited %d\nstdout: %s\nstderr: %s",
                  result.returncode, result.stdout.strip(), result.stderr.strip())
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        log.error("Script timed out: %s", script_path)
        return 1, "", f"{os.path.basename(script_path)} timed out after 120s"


class MonitorLayoutsApp(rumps.App):
    def __init__(self):
        super().__init__("🖥", quit_button=None)
        log.info("MonitorLayoutsApp starting")

        self.monitor_item = rumps.MenuItem("Checking...", callback=None)
        self.capture_item = rumps.MenuItem("📸 Capture Layout", callback=self.capture)
        self.restore_item = rumps.MenuItem("♻️  Restore Layout", callback=self.restore)
        self.last_item    = rumps.MenuItem("", callback=None)
        self.quit_item    = rumps.MenuItem("Quit", callback=rumps.quit_application)

        self.menu = [
            self.monitor_item,
            None,
            self.capture_item,
            self.restore_item,
            None,
            self.last_item,
            None,
            self.quit_item,
        ]

        self.refresh_state()

    def refresh_state(self):
        monitor_id, label = get_external_monitor()
        self.monitor_item.title = label

        has_monitor = monitor_id is not None
        self.capture_item.set_callback(self.capture if has_monitor else None)
        self.restore_item.set_callback(self.restore if has_monitor else None)

        self.last_item.title = read_last_restore()
        self.last_item.set_callback(None)

    @rumps.clicked("🖥")
    def menu_opened(self, _):
        log.debug("Menu opened")
        self.refresh_state()

    def capture(self, _):
        log.info("Capture triggered")
        self.capture_item.title = "📸 Capturing..."
        def run():
            try:
                code, out, err = run_script(CAPTURE_SH)
            except Exception as e:
                log.exception("Unexpected error during capture")
                code, out, err = 1, "", str(e)
            if code == 0:
                log.info("Capture succeeded")
                notify("📸 Monitor Layouts", "Layout captured successfully")
            else:
                msg = err.strip() or out.strip()
                log.error("Capture failed: %s", msg)
                notify("⚠️ Monitor Layouts", f"Capture failed: {msg[:80]}")
            self.capture_item.title = "📸 Capture Layout"
            self.refresh_state()
        threading.Thread(target=run, daemon=True).start()

    def restore(self, _):
        log.info("Restore triggered")
        self.restore_item.title = "♻️  Restoring..."
        def run():
            try:
                code, out, err = run_script(RESTORE_SH)
            except Exception as e:
                log.exception("Unexpected error during restore")
                code, out, err = 1, "", str(e)
            if code == 0:
                for line in reversed(out.splitlines()):
                    if "Done —" in line:
                        msg = line.strip().lstrip("✅ ").strip()
                        log.info("Restore succeeded: %s", msg)
                        notify("✅ Monitor Layouts", msg)
                        break
                else:
                    log.info("Restore succeeded")
                    notify("✅ Monitor Layouts", "Layout restored")
            else:
                msg = err.strip() or out.strip()
                log.error("Restore failed: %s", msg)
                notify("⚠️ Monitor Layouts", f"Restore failed: {msg[:80]}")
            self.restore_item.title = "♻️  Restore Layout"
            self.refresh_state()
        threading.Thread(target=run, daemon=True).start()


if __name__ == "__main__":
    log.info("app.py started")
    MonitorLayoutsApp().run()
