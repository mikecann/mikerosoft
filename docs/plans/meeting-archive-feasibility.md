# Meeting Archive: passive capture feasibility

Date: 2026-09-17

## Result

The bounded passive diagnostic is implemented under
`tools/meeting-archive/diagnostics`. It compiles and its pure meeting-surface
rules pass. It does not prove automatic capture for Meet, Zoom, Teams, or Slack
yet because this unsigned command-line process currently has neither Camera nor
Screen Recording access, and no live call was run.

The architecture remains feasible only with a per-application state adapter.
The physical camera signal is useful corroborating evidence, but it cannot be
the owner signal or the sole stop signal. Production start should require all
of these:

1. exact application identity;
2. a positively identified joined-call surface;
3. the application's own local outgoing-camera state;
4. a captureable meeting window.

If any required signal is unknown, the state is `unknown` or a video gap. It is
never silently promoted to a meeting or camera owner.

## What the diagnostic does

The binary is built directly with `swiftc`, without changing the shared Swift
package or opening the camera. It provides:

- AVFoundation camera metadata and
  `isInUseByAnotherApplication` when macOS exposes devices to the process;
- CoreMediaIO device metadata and
  `kCMIODevicePropertyDeviceIsRunningSomewhere` when available;
- ScreenCaptureKit application/window inventory guarded by a permission
  preflight, so it does not create a Screen Recording prompt;
- exact bundle-ID matching and explicit title heuristics for Chrome Meet, Zoom,
  Teams, and Slack;
- bounded JSON Lines snapshots and polling with initial, changed, and optional
  unchanged events;
- an evidence statement in every event saying that camera activity and window
  observations are independent and do not establish ownership.

It never calls `AVCaptureDevice.requestAccess`, creates an `AVCaptureSession`,
creates an `SCStream`, captures a screenshot, or records audio.

## Live observations on this Mac

| Check | Observed result | Meaning |
| --- | --- | --- |
| Full Xcode-selected `/usr/bin/swiftc --version` | Blocked by the unaccepted Xcode licence | The diagnostic does not use or alter this installation |
| CLT Swift | Swift 6.3.3 works with `DEVELOPER_DIR=/Library/Developer/CommandLineTools` | Standalone compilation is available without accepting a licence |
| CLT default macOS 26.5 SDK | Compiler/SDK Swift interface mismatch during a real compile | The scripts use the separately present, compatible macOS 15.4 SDK and allow `SDKROOT` override |
| Pure rule tests | 7 passed | Exact app identity, preview/settings exclusion, candidate/ambiguous handling, unrelated apps, and offscreen warnings are covered |
| Camera snapshot | Camera authorization `denied`; AVFoundation returned zero devices; CoreMediaIO returned zero devices | No actual device transition or device metadata is verified in this run. Zero devices is an observed result, not proof that the Mac has no camera |
| Screen inventory | `CGPreflightScreenCaptureAccess()` returned false | The tool returned without invoking ScreenCaptureKit; no window candidates were observed and no permission prompt was created |
| Two-poll watch | Initial and unchanged JSON records were emitted 0.1 seconds apart | The bounded JSONL/watch path works under denied permissions |
| Installed supported apps | Chrome 153.0.8010.47 (`com.google.Chrome`), Zoom 7.0.5.81138 (`us.zoom.xos`), Slack 4.51.191 (`com.tinyspeck.slackmacgap`) | The exact identities in the rules match the installed apps |
| Teams | No Teams app found in `/Applications` or `~/Applications` | Teams bundle/window rules are code-level hypotheses only on this Mac |

No actual camera-on/off transition, Meet/Zoom/Teams/Slack meeting, pre-join
screen, tab switch, minimization, Space change, or pop-out was exercised. Those
rows remain unpassed.

## Why camera activity cannot identify an app

Apple describes `AVCaptureDevice.isInUseByAnotherApplication` as a Boolean that
indicates another app is using the device. CoreMediaIO describes
`kCMIODevicePropertyDeviceIsRunningSomewhere` as a UInt32 saying the device runs
in at least one process. Neither property returns a PID or bundle identifier.
The CoreMediaIO property is especially explicit about being system-wide rather
than owner-specific. See [AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice) and [CoreMediaIO device properties](https://developer.apple.com/documentation/coremediaio/cmiodevice-properties).

Temporal correlation is not attribution. Chrome, Zoom, Record It, a native
preview app, or a second camera client can overlap. A meeting app can also keep
the device running after its video control is turned off. The application
adapter must therefore own the start/stop decision. Physical-device state can
record useful evidence such as disconnected, globally idle, or still running
somewhere, but it must not override an explicit in-call camera-off signal.

## Meeting-window rules in the diagnostic

The current rules deliberately stop before production readiness.

| App | Exact application evidence | Window heuristic | Known negative/ambiguous case | Automatic trigger |
| --- | --- | --- | --- | --- |
| Meet | Chrome bundle identifier | title contains `Google Meet` or `meet.google.com` | pre-join and joined calls may look the same; arbitrary camera-test tabs share the process | unsafe |
| Zoom | `us.zoom.xos` | title contains `Zoom Meeting` or `Zoom Webinar` | `Video Preview`, `Join Meeting`, Settings and Preferences are excluded by title; generic Zoom stays ambiguous | unsafe |
| Teams | `com.microsoft.teams` or `com.microsoft.teams2` | non-generic title contains `meeting` or `call` | settings, device setup, test call, pre-join, and generic Teams shell | unsafe |
| Slack | `com.tinyspeck.slackmacgap` | title contains `huddle` or `call` | Preferences, Settings, Audio & Video, and generic Slack shell | unsafe |

Titles are localized UI text and can change between releases. They narrow the
inventory for experiments; they are not evidence of joined state or outgoing
camera state.

## Production adapter assessment

### Google Meet in Chrome

The strongest route is a small Manifest V3 state-reporting extension restricted
to `https://meet.google.com/*`, plus native window capture. It should report a
stable tab/window identifier, whether that tab is active in the window, a
joined-call predicate, and the local camera toggle state. Joined state should
require a concrete in-call control such as the Leave call control. Camera-on
should require the control whose action is Turn off camera; camera-off should
require Turn on camera. Unknown labels or missing controls produce `unknown`.

This extension does not need `tabCapture`. Chrome documents that host
permissions let an extension read matching tab URL/title information, content
scripts can inspect a permitted page, and native messaging can carry a bounded
state message to a native host. See [Chrome tab permissions](https://developer.chrome.com/docs/extensions/reference/api/tabs), [content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts), and [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).

The Meet DOM and accessible labels are not a stable public meeting-state API,
so this remains a versioned adapter requiring fixtures and live-call tests.
Pre-join must remain negative even if it opens the camera. When the user changes
to a non-Meet tab in the captured Chrome window, stop accepting video frames
within a measured bound and record a gap. Continue only when the adapter proves
the meeting tab is visible again. Never record the unrelated tab while waiting.
Chrome application audio is a separate limitation: ScreenCaptureKit's
single-window audio includes the containing application's audio, so another
audible Chrome tab may be present.

An Accessibility adapter that reads the Chrome `AXWebArea`, URL and in-call
controls is a possible fallback. It adds Accessibility permission and is still
dependent on Chrome/Meet's accessible hierarchy. It is weaker than the
origin-limited extension for exact tab identity.

### Zoom

The practical local adapter is macOS Accessibility over the exact Zoom process.
Require a meeting surface plus a Leave/End meeting control, then classify the
local camera from the Start Video versus Stop Video control. Treat Video
Preview, Join Meeting, Settings, and Preferences as negative states. The
diagnostic's title rules only locate candidate surfaces; the AX controls make
the state decision.

This is technically possible with Apple's public AX APIs, which expose UI
element roles, titles/values and change notifications, but exact Zoom controls
were not inspected in a live call. See [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement_h) and [AX notifications](https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h).

Zoom share windows and participant pop-outs need explicit source rules. A new
window must be positively identified and deliberately added or selected; it
must not replace the source because it became foreground. Preview/settings
camera activity must never start an archive.

### Microsoft Teams

Use the same AX shape only after installation and live inspection: exact Teams
bundle ID, a meeting surface with a Leave control, and a concrete camera toggle
whose action distinguishes turn-on from turn-off. Generic Teams, device
settings, test calls, and pre-join remain negative or unknown.

Teams was not installed, so neither the current bundle variants nor accessible
control labels were verified here. New Teams uses web-backed UI and can change
its accessibility tree independently of the macOS app version. This adapter is
feasible as an experiment and unsupported as a production claim today.

### Slack Huddles

Use exact Slack identity and an AX-proven active Huddle surface with a Leave
Huddle control. Determine outgoing-camera state from the concrete video toggle,
not from a Huddle title or physical camera use. A generic Slack window, Audio &
Video preferences, and an audio-only Huddle with camera off must not trigger.

Slack is installed, but no Huddle was joined and its current accessible control
labels were not inspected. Huddles can live in the main Slack shell or a
separate window, so the adapter must tie controls and the selected window to one
session rather than treating the whole Slack process as a meeting.

## Offscreen, minimization, tab changes, and pop-outs

Apple's ScreenCaptureKit session states that desktop-independent single-window
capture keeps full content when a window is occluded, off-screen, moved to
another display, or on another Space. A minimized source is different: stream
output pauses until the window is restored. A single-window filter excludes
child/pop-up windows, while its audio is app-wide. See [Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/).

The resulting state rules are:

- occlusion, another display, and another Space do not by themselves end a
  meeting;
- minimized or unavailable video creates a marked video gap while meeting and
  microphone/incoming-audio state continue independently;
- no-video callbacks must not be interpreted as camera off;
- a Chrome tab change creates a gap unless the Meet adapter confirms the active
  Meet tab;
- child windows and share pop-outs require positive identity and explicit
  filter updates or composition;
- the recorder never broadens to an entire display or another foreground
  window to hide a missing source.

## Pass criteria for the next experiment

Each adapter needs a timestamped trace showing the application signal, passive
device signal, selected window, and expected state for all of these:

1. settings/preview with camera on, then close without joining;
2. pre-join with camera on and off;
3. join with camera initially on and initially off;
4. toggle camera several times, switch camera, and exit the call;
5. quit/crash the app while joined;
6. minimize, restore, change Space/display, and cover the window;
7. open share/participant pop-outs and replace the main meeting window;
8. run an independent camera client before, during, and after the call;
9. for Meet, use multiple Chrome windows/tabs and switch to unrelated content;
10. for Zoom, distinguish Video Preview and Join Meeting from the active call;
11. for Teams and Slack, inspect actual current AX labels before freezing rules.

A pass requires zero starts from preview/pre-join/settings, prompt stop from the
application's confirmed camera-off control, no unrelated video frames during a
tab/source gap, and no false owner claim when another camera client remains
active. Detection latency and any missing transition must be measured, not
described qualitatively.

## Commands run

```sh
tools/meeting-archive/diagnostics/run-tests.sh
tools/meeting-archive/diagnostics/build.sh
tools/meeting-archive/diagnostics/.build/meeting-archive-diagnostic help
tools/meeting-archive/diagnostics/.build/meeting-archive-diagnostic camera
tools/meeting-archive/diagnostics/.build/meeting-archive-diagnostic inventory
tools/meeting-archive/diagnostics/.build/meeting-archive-diagnostic watch --samples 2 --interval 0.1 --emit-unchanged
```

The next live experiment requires user-granted permissions and deliberate fake
calls. This implementation did not request those permissions, install an
extension or Accessibility helper, register a service, open a camera, or alter
any account.
