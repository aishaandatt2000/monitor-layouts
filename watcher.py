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
            if "Type:" in line and "external" in line.lower():
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
    try:
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=5)
    except subprocess.TimeoutExpired:
        pass


def auto_mode_enabled():
    return os.path.exists(FLAG_FILE)


def run_restore():
    """Run restore.sh and return (success, message)."""
    try:
        result = subprocess.run(
            ["bash", RESTORE_SH],
            capture_output=True, text=True,
            timeout=120
        )
    except subprocess.TimeoutExpired:
        return False, "restore.sh timed out after 120s"
    if result.returncode == 0:
        for line in reversed(result.stdout.splitlines()):
            if "Done —" in line:
                return True, line.strip().lstrip("✅ ").strip()
        return True, "Layout restored"
    else:
        err = result.stderr.strip() or result.stdout.strip()
        return False, err[:100]


def main():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    print("monitor-layouts watcher started", flush=True)

    while True:
        current = get_external_monitor_id()
        last    = read_last_display()

        if current and current != last:
            # New monitor connected (or auto mode was off and last wasn't updated)
            if auto_mode_enabled():
                notify("🖥 Monitor Layouts", "Monitor connected — restoring layout...")
                success, msg = run_restore()
                if success:
                    notify("✅ Monitor Layouts", msg)
                else:
                    notify("⚠️ Monitor Layouts", f"Restore failed: {msg}")
            # Only update last_known when auto mode is on (so enabling auto mode
            # while monitor is connected still triggers a restore on next poll)
            if auto_mode_enabled():
                write_last_display(current)
        elif not current and last is not None:
            # Monitor disconnected
            write_last_display(None)

        time.sleep(5)


if __name__ == "__main__":
    main()
