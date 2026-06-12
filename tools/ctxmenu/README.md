![header](docs/header.png)

# ctxmenu

A GUI for managing Windows Explorer context menu entries. Shows shell verbs
and COM extension handlers from the registry, and lets you toggle them on or
off without needing admin rights.


## Screenshots

![ctxmenu screenshot](docs/ss1.png)


## Usage

```
ctxmenu
```

Or run `ctxmenu.vbs` directly. A window opens immediately - no console.

## What it shows

| Category | What's scanned |
|---|---|
| All Files | `*\shell`, `*\shellex\ContextMenuHandlers`, and `Applications\*.exe` Open With app registrations |
| Folders | `Directory\shell` and `Directory\shellex\ContextMenuHandlers` |
| Folder Background | `Directory\Background\shell` and `...\shellex\...` |
| Drives | `Drive\shell` |
| Video Files | `SystemFileAssociations\.<ext>\shell`, media ProgID verbs, and All Files entries |
| Image Files | `SystemFileAssociations\.<ext>\shell`, image ProgID verbs, and All Files entries |

Both HKCU (user) and HKLM (system/app-installed) entries are shown.

## Toggling entries

Click the checkbox next to an entry, or select rows and use **Enable Selected**
/ **Disable Selected**.

Changes take effect immediately - Explorer is notified via `SHChangeNotify`
so you don't need to restart it.

**How disabling works (no admin needed):**

- **Verb entries** (`Verb` / `Submenu` kind): adds an empty `LegacyDisable`
  value to a HKCU shadow key. Windows merges HKCU on top of HKLM when
  building HKCR, so this suppresses system-installed entries too.
- **COM handlers** (`ShellEx` kind): adds the handler CLSID to
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`.
  Explorer honors this for system-installed handlers such as Filmora.
- **Open With apps** (`OpenWith` kind): adds `NoOpenWith` under the HKCU
  `Software\Classes\Applications\<app>.exe` shadow key. This hides app-level
  suggestions like `Open with Zed` without deleting the app registration.

To re-enable: check the box again. The shadow key is cleaned up.

## What it won't show

- Some Windows 11 dynamic or packaged-app commands are injected by Explorer
  rather than exposed as simple registry verbs. Examples include parts of
  Copilot, Share, Defender, Cast to Device, and some AppX commands.

## Tests

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ctxmenu\run-tests.ps1
```

## Notes

- No external dependencies - uses built-in .NET WinForms.
- All writes go to HKCU - never modifies HKLM directly.
- Safe to run multiple times; toggling is fully reversible.
