# Display Workspace

Menu-bar utility for macOS that remembers a complete laptop or docked workspace and restores it when the active display set changes.

It saves:

- BetterDisplay display identity, placement, resolution, refresh rate, rotation, HiDPI state, and main-display state
- app window position, size, minimised state, display, and macOS Desktop (Space) index
- separate named profiles for exact display combinations, such as `Laptop` and `Docked`

It restores automatically four seconds after a display reconfiguration settles. A manual restore remains available from the menu bar.

## Requirements

- macOS 14 or newer
- Xcode / Swift for builds
- BetterDisplay installed in `/Applications`
- BetterDisplay Pro for the display features that require it
- Accessibility permission for `Display Workspace.app`
- Stage Manager off
- **Automatically rearrange Spaces based on most recent use** off

Display Workspace does not disable SIP and does not install yabai. Desktop assignment uses the WindowServer interfaces already present in macOS. These are not public App Store APIs, so a major macOS update can require an adapter update.

## First-time setup

```bash
bash tools/display-workspace/setup_mac.sh
bash tools/display-workspace/install-launchagent.sh
```

Grant Accessibility permission when macOS asks. If the app is not listed automatically:

1. Open **System Settings > Privacy & Security > Accessibility**.
2. Add `~/Applications/Display Workspace.app`.
3. Enable it.
4. Run `bash tools/display-workspace/restart.sh`.

## Save the two setups

1. Disconnect the dock and arrange the laptop windows and Desktops.
2. Open the menu-bar icon, choose **Save Current Setup…**, and save `Laptop`.
3. Connect the dock and wait for every real and BetterDisplay virtual screen to appear.
4. Arrange the displays, Desktops, and windows.
5. Choose **Save Current Setup…** and save `Docked`.

Saving an existing name updates that profile.

The active display set must match exactly. Configured but disconnected BetterDisplay virtual screens do not count, which prevents an offline virtual screen from selecting the wrong profile.

## Current scope

- Ordinary windows across multiple monitors and user-created Desktops are supported.
- Multiple windows from the same app are matched by document URL first, then title, then enumeration order.
- Native fullscreen Spaces are ignored.
- Stage Manager is not supported.
- Display Workspace restores existing Desktops by index. It does not create missing Desktops yet.
- Apps must still be running when restoration occurs. Launching closed apps is a later feature.

## Data and logs

| Path | Purpose |
|---|---|
| `~/Applications/Display Workspace.app` | Stable signed app bundle |
| `~/Library/Application Support/Display Workspace/profiles.json` | Saved profiles |
| `~/Library/LaunchAgents/com.mikerosoft.display-workspace.plist` | Optional login item |
| `~/Library/Logs/display-workspace.log` | LaunchAgent stdout/stderr |

## Development

```bash
cd tools/display-workspace
./run-tests.sh          # unit tests, release build, live read-only diagnostic
./build-and-run.sh      # release build, replace app bundle, restart
./restart.sh            # restart the existing app bundle without rebuilding
```

The read-only diagnostic can be run directly:

```bash
.build/release/display-workspace --diagnose
```

It verifies BetterDisplay integration, active stable display IDs, Accessibility access, user Desktop discovery, and per-window Desktop identity without moving anything.

Setup can also save or restore through the signed executable without using the menu:

```bash
"$HOME/Applications/Display Workspace.app/Contents/MacOS/display-workspace" --save-profile Laptop
"$HOME/Applications/Display Workspace.app/Contents/MacOS/display-workspace" --restore-matching
```
