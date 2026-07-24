# Last Window Quits

![A macOS-style window dissolving as its Dock icon powers down](docs/header.webp)

A small macOS menu-bar tool that quits a normal Dock app after its last window
closes.

macOS usually leaves an application running when you click the red close button.
This tool watches Accessibility window lists and sends the application a normal
quit request once its final window has remained closed for one second.

## Safety behaviour

- An app must first have at least one window before it is armed.
- Minimized windows still count as open.
- Finder, Dock, SystemUIServer, WindowManager, loginwindow, and this tool are
  always ignored.
- Only normal foreground applications are monitored. Menu-bar-only and
  background applications are ignored.
- Quitting uses the normal macOS termination request, so an app can show its
  regular save confirmation or reject the quit.
- If an application's window list cannot be read, the tool does nothing to it.

## Setup

```bash
bash tools/last-window-quits/setup_mac.sh
```

The setup runs the tests, builds and signs
`~/Applications/Last Window Quits.app`, starts it, and installs it as a login
service.

Grant **Last Window Quits** access in:

`System Settings > Privacy & Security > Accessibility`

Look for **LWQ** in the menu bar. `LWQ!` means Accessibility permission is
still needed. Its menu can pause the behaviour, toggle start-at-login, request
permission, or quit the tool.

## How it works

The signed Swift menu-bar app checks normal foreground applications twice per
second through macOS Accessibility. Its state machine only arms an application
after seeing at least one window. When that count falls to zero and remains
there for one second, it asks macOS to terminate the application normally.

The staged app uses a stable signing requirement so rebuilding it does not
invalidate its Accessibility permission.

## Development

```bash
swift test --package-path tools/last-window-quits
bash tools/last-window-quits/restart.sh
tail -f ~/Library/Logs/last-window-quits.log
```

Always use `restart.sh` after a Swift change so the staged, consistently signed
app is tested. Running the raw SwiftPM executable gives macOS a different
Accessibility identity.

To stop and remove it from login:

```bash
bash tools/last-window-quits/uninstall.sh
```

The app icon is `door_out.png` from Mark James's famfamfam Silk icon set,
licensed under CC BY 2.5.
