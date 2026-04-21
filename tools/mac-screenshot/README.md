![header](docs/header.png)

# mac-screenshot

Global screenshot hotkey for macOS.

Press `F11` to enter selection capture mode, save the shot to `~/Desktop/Screenshots`,
copy it to the clipboard, and open it in Preview so you can annotate it straight away.

---

## Quick start

```bash
bash tools/mac-screenshot/setup_mac.sh
bash tools/mac-screenshot/install-launchagent.sh
```

Then grant permissions in macOS:

1. `System Settings` -> `Privacy & Security` -> `Accessibility`
2. Add `Python.app` and turn it on
3. If macOS asks, also allow Screen Recording

After that, press `F11`.

---

## What it does

- Starts a global hotkey listener on login via LaunchAgent
- Opens the native macOS region capture flow
- Saves screenshots into `~/Desktop/Screenshots`
- Uses timestamp-based filenames
- Copies the saved PNG to the clipboard
- Opens the image in Preview for markup

---

## Commands

```bash
# one-time setup
bash tools/mac-screenshot/setup_mac.sh

# install auto-start on login
bash tools/mac-screenshot/install-launchagent.sh

# restart after code changes
bash tools/mac-screenshot/restart.sh

# stop the daemon
bash tools/mac-screenshot/kill.sh

# remove auto-start
bash tools/mac-screenshot/uninstall-launchagent.sh
```

---

## Art

`docs/header.png` is a generated banner for the public site. `icons/mac-screenshot.png` is **`monitor.png`** from the [FamFamFam Silk](https://www.famfamfam.com/lab/icons/silk/) set (Mark James, [CC BY 2.5](https://creativecommons.org/licenses/by/2.5/)).

## Notes

- The default hotkey is `F11`
- Change `HOTKEY` or `SAVE_DIR` at the top of `mac-screenshot.py`
- Logs are written to `~/Library/Logs/mac-screenshot.log`
