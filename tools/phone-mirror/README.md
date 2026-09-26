# phone-mirror

Mirror and control several iPhones and iPads at once from your Mac, over USB.
Each phone gets its own window. Click to tap, drag to swipe, scroll to scroll,
and type to type.

Apple's own iPhone Mirroring only handles one phone at a time and only over
Wi-Fi. Phone Mirror doesn't have either limit, and it needs no Bluetooth pairing
or AssistiveTouch.

## What it does

- Opens a window for every iPhone or iPad plugged in with a cable, and closes it
  when the phone is unplugged. Plug in several and each gets its own window
- Shows the phone's screen at full resolution. The window keeps the phone's
  shape, follows it when it rotates, and remembers where you left it for each phone
- Sends your clicks, drags, scrolling and typing to the phone through
  WebDriverAgent, Apple's UI-testing runner, over the same cable
- Shows a ripple where each click landed, so you can see where the tap went while
  the phone catches up
- The status bar reads 9:41 with full signal and battery while a phone is
  mirrored. iOS does this for any cabled screen capture, which suits recordings

## Controls

| Input | On the phone |
|---|---|
| Click | Tap |
| Click and hold | Long press |
| Right-click | Long press |
| Drag | Swipe, replayed with your timing |
| Scroll wheel or trackpad | Scroll by exactly that much, without flinging |
| Typing | Types into whatever field is focused |
| ⌘V | Types the Mac clipboard into the phone |
| ⇧⌘H | Home |

| Mac shortcut | Action |
|---|---|
| ⌘1 to ⌘9 | Bring a phone's window forward |
| ⌘N | Show all phone windows |
| ⌘0 | Actual size (one phone pixel per screen pixel) |
| ⌥⌘T | Keep the window on top |

The window's subtitle shows the control status: starting, setting up, waiting
for you to unlock the phone, or ready.

## Setup

```bash
bash tools/phone-mirror/setup_mac.sh
```

Then launch **Phone Mirror** from Spotlight, or run `phone-mirror` after
`bash install_mac.sh`.

Control needs a few one-off steps:

1. **Sign into Xcode** with an Apple ID that's in a paid Apple Developer Program
   team (Xcode > Settings > Accounts). A free Apple ID works too, but its signing
   expires after 7 days
2. **Turn on Developer Mode** on each phone (Settings > Privacy & Security >
   Developer Mode). It appears once the phone has been plugged into a Mac with
   Xcode
3. **Plug the phone in and unlock it.** The first time, Phone Mirror builds the
   helper, signs it with your team and registers the phone. That takes about a
   minute. After that it starts in a few seconds whenever the phone is unlocked

The helper app, WebDriverAgentRunner, appears on each phone's home screen. With
a paid team its signing lasts a year. When it expires, Phone Mirror rebuilds it
automatically.

macOS asks for Camera permission the first time, because it treats a phone's
screen as a camera.

## How it works

- **Video.** Phone Mirror opts into CoreMediaIO "screen capture devices", which
  is what QuickTime does before offering an iPhone as a recording source. Each
  plugged-in phone then appears as a capture device, and an
  `AVCaptureVideoPreviewLayer` shows it
- **Control.** `agent.sh` fetches [WebDriverAgent](https://github.com/appium/WebDriverAgent)
  (pinned to a release), gives it its own bundle ID, and builds it with
  `xcodebuild build-for-testing` for your team. `agent.sh run` starts it with
  `xcodebuild test-without-building`. Phone Mirror talks to it over the USB
  tunnel Xcode keeps open to the phone, found through `xcrun devicectl`
- **Gestures.** A click becomes `/wda/tap`. A drag is replayed as W3C touch
  actions with its original timing. Scrolling is collected for 80 ms and sent as
  one drag that holds still before lifting, so the phone scrolls exactly that far

The helper's source and build output live in
`~/Library/Application Support/Phone Mirror`. Logs are in
`~/Library/Logs/Phone Mirror/`: `phone-mirror.log` for the app and
`helper-<phone>.log` for each phone's xcodebuild output.

## Development

```bash
swift test --package-path tools/phone-mirror
bash tools/phone-mirror/restart.sh
```

`open -g "phonemirror://<command>"` drives the first phone from the terminal
without clicking:

| Command | Does |
|---|---|
| `tap?x=0.5&y=0.5` | Tap at a fraction of the screen's width and height |
| `swipe?dy=-300` | Drag from the middle by that many points |
| `type?text=hello` | Type text |
| `home` | Press Home |

`agent.sh build <udid>` and `agent.sh run <udid>` build and start the helper by
hand. The team ID comes from `PHONE_MIRROR_TEAM_ID`, then `team-id` in the
support folder, then the Apple Development certificate in your keychain.

## Limitations

- Drags are replayed when you let go, not live, so the phone moves after the
  mouse does
- No multi-touch gestures like pinch
- Controlling a phone needs it unlocked. If it locks, unlock it and control
  resumes
