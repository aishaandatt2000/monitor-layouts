# monitor-layouts

Save and restore your window layout per monitor on macOS — automatically handles multiple monitors, multiple desktops (Spaces), fullscreen apps, and Electron apps (VS Code, Teams, Outlook, Chrome).

**The problem:** Plug your MacBook into a different monitor and all your windows are scrambled. Do it every day going between home and work and it's infuriating.

**The solution:** Two commands — `capture.sh` saves your layout, `restore.sh` brings it back. Each monitor gets its own saved layout identified by its hardware ID, so switching between monitors never clobbers the other setup.

---

## Requirements

- macOS 12+
- [Homebrew](https://brew.sh)

---

## Install

```bash
git clone https://github.com/aishaandatt2000/monitor-layouts.git
cd monitor-layouts
bash install.sh
```

`install.sh` will:
- Install `displayplacer` (display arrangement)
- Install `yabai` (window management API)
- Start the yabai service
- Set up config directory at `~/.config/monitor-layouts/`

### Accessibility permission (required)

On first run, macOS will prompt you to grant Accessibility access to your terminal app. If it doesn't, go to:

**System Settings → Privacy & Security → Accessibility** → add and enable your terminal (Terminal, iTerm2, Warp, etc.)

Then restart yabai:
```bash
yabai --start-service
```

---

## Usage

### Save a layout

1. Connect your monitor
2. Arrange your windows exactly how you want them
3. Run:
```bash
./capture.sh
```

Repeat for each monitor you use. Each monitor gets its own layout file stored at `~/.config/monitor-layouts/layouts/<monitor-id>.json`.

### Restore a layout

After connecting a monitor:
```bash
./restore.sh
```

The script detects which monitor is connected and restores the right layout automatically. Run it any time your windows get scrambled — it's safe to run repeatedly.

---

## What gets saved and restored

| Feature | Supported |
|---|---|
| Window position | ✅ |
| Window size | ✅ |
| Which Space (virtual desktop) each window is on | ✅ |
| Fullscreen state | ✅ |
| Display arrangement (which screen is primary) | ✅ |
| Auto-create missing Spaces on restore | ✅ |
| Electron apps (VS Code, Teams, Outlook, Chrome) | ✅ via yabai |
| Apps that are closed at restore time | ⏭ skipped silently |

---

## How window matching works

When restoring, each saved window is matched to a currently open window using:

1. **Exact title match** — same app, same window title → highest confidence
2. **Partial title match** — a keyword from the saved title appears in the current title
3. **Index fallback** — no title match, windows matched by order

The restore output shows which strategy was used for each window so you can see what happened.

---

## Multiple monitors

Each monitor is identified by its hardware persistent ID (not its name or position), so:
- Home monitor layout and work monitor layout are stored separately
- Capturing at home never overwrites your work layout
- `restore.sh` always picks the right layout for whichever monitor is currently connected

---

## Troubleshooting

**`yabai is not running`**
```bash
yabai --start-service
```

**Windows move but to wrong positions**
Re-run `capture.sh` with your windows in the right spots. The saved layout may be stale.

**Electron app windows don't move**
Make sure Accessibility permission is granted for your terminal app. See install instructions above.

**`No external monitor detected`**
The scripts only work when an external monitor is connected. Run them after plugging in.

---

## How it works

- `displayplacer list` detects connected monitors and their hardware IDs
- `yabai -m query --windows` reads all window positions, sizes, spaces, and fullscreen state — including Electron apps that AppleScript can't reach
- Layouts are stored as JSON in `~/.config/monitor-layouts/layouts/`
- `yabai -m window --move` and `--resize` restore positions; `--space` moves windows between Spaces

---

## License

MIT
