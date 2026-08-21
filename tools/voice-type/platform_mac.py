"""macOS platform implementations for voice-type."""

from __future__ import annotations

import os
import subprocess
import threading
from typing import Callable

_LAUNCH_AGENT_LABEL = "com.mikerosoft.voice-type"

_listener_started = False
_hotkey_listener_state = "not-started"
_hotkey_listener_state_lock = threading.Lock()
_lifecycle_lock = threading.Lock()
_wake_generation = 0
_display_generation = 0
_lifecycle_observers: list[tuple[object, object]] = []

# The app that was frontmost when the push-to-talk key went down.
# Saved before our overlay can steal focus; re-activated before pasting.
_target_app: object = None

# macOS virtual keycodes for the two push-to-talk keys.
_VK_F12 = 111
_VK_RIGHT_CONTROL = 0x3E
_DEVICE_RIGHT_CONTROL_MASK = 0x00002000


class MacPushToTalkHotkeys:
    """Track the macOS keys reserved for push-to-talk."""

    def __init__(self) -> None:
        self._down: set[int] = set()
        self._lock = threading.Lock()

    def handle_event(
        self,
        event_kind: str,
        keycode: int,
        physical_down: bool | None = None,
    ) -> bool:
        """Update key state and return whether the event was handled."""
        if keycode == _VK_F12:
            if event_kind == "key_down":
                physical_down = True
            elif event_kind == "key_up":
                physical_down = False
            else:
                return False
        elif keycode == _VK_RIGHT_CONTROL:
            if event_kind != "flags_changed" or physical_down is None:
                return False
        else:
            return False

        with self._lock:
            if physical_down:
                self._down.add(keycode)
            else:
                self._down.discard(keycode)
        return True

    def is_down(self) -> bool:
        with self._lock:
            return bool(self._down)

    def reset(self) -> None:
        with self._lock:
            self._down.clear()


_hotkeys = MacPushToTalkHotkeys()


def _set_hotkey_listener_status(state: str) -> None:
    global _hotkey_listener_state
    with _hotkey_listener_state_lock:
        _hotkey_listener_state = state


def hotkey_listener_status() -> str:
    with _hotkey_listener_state_lock:
        return _hotkey_listener_state


def _note_system_wake(_notification) -> None:
    global _wake_generation
    with _lifecycle_lock:
        _wake_generation += 1
    _hotkeys.reset()


def _note_display_change(_notification) -> None:
    global _display_generation
    with _lifecycle_lock:
        _display_generation += 1


def lifecycle_event_snapshot() -> tuple[int, int]:
    """Return wake and display generations without doing work in callbacks."""
    with _lifecycle_lock:
        return _wake_generation, _display_generation


def _install_lifecycle_observers() -> None:
    if _lifecycle_observers:
        return
    try:
        from AppKit import (
            NSApplicationDidChangeScreenParametersNotification,
            NSWorkspace,
            NSWorkspaceDidWakeNotification,
        )
        from Foundation import NSNotificationCenter

        workspace_center = NSWorkspace.sharedWorkspace().notificationCenter()
        wake_token = workspace_center.addObserverForName_object_queue_usingBlock_(
            NSWorkspaceDidWakeNotification,
            None,
            None,
            _note_system_wake,
        )
        app_center = NSNotificationCenter.defaultCenter()
        display_token = app_center.addObserverForName_object_queue_usingBlock_(
            NSApplicationDidChangeScreenParametersNotification,
            None,
            None,
            _note_display_change,
        )
        _lifecycle_observers.extend(
            [(workspace_center, wake_token), (app_center, display_token)]
        )
    except Exception:
        # The wall-clock gap remains as a fallback on older PyObjC installs.
        return


def handle_quartz_hotkey_event(
    quartz,
    event_type: int,
    event,
    hotkeys: MacPushToTalkHotkeys | None = None,
) -> bool:
    """Apply one Quartz keyboard event and report whether it was handled."""
    target = hotkeys if hotkeys is not None else _hotkeys
    keycode = int(quartz.CGEventGetIntegerValueField(
        event,
        quartz.kCGKeyboardEventKeycode,
    ))

    if event_type == quartz.kCGEventKeyDown:
        event_kind = "key_down"
        physical_down = None
    elif event_type == quartz.kCGEventKeyUp:
        event_kind = "key_up"
        physical_down = None
    elif event_type == quartz.kCGEventFlagsChanged:
        event_kind = "flags_changed"
        physical_down = None
        if keycode == _VK_RIGHT_CONTROL:
            physical_down = bool(
                quartz.CGEventGetFlags(event) & _DEVICE_RIGHT_CONTROL_MASK
            )
    else:
        return False

    return target.handle_event(event_kind, keycode, physical_down)


def setup_dll_paths() -> None:
    pass


# ---------------------------------------------------------------------------
# Hotkey — CGEventTap intercepts F12 and Right Control at the system level.
#
# Using CGEventTapOptionDefault (not ListenOnly) means we can suppress the
# event by returning None from the callback, so macOS won't also handle it.
#
# Falls back to a plain pynput listener (no suppression) if the tap cannot
# be created — most likely because Accessibility permission hasn't been
# granted yet.
# ---------------------------------------------------------------------------

def _run_cg_event_tap() -> None:
    """Block the calling thread running the push-to-talk CGEventTap."""
    import Quartz

    def _callback(proxy, event_type, event, refcon):
        # macOS auto-disables an event tap if its callback is ever judged too
        # slow, or on certain user-input conditions. When that happens we stop
        # receiving events entirely — including key-up events — which could
        # leave push-to-talk stuck on. Re-enable the tap and clear key state.
        if event_type in (
            Quartz.kCGEventTapDisabledByTimeout,
            Quartz.kCGEventTapDisabledByUserInput,
        ):
            Quartz.CGEventTapEnable(tap, True)
            _hotkeys.reset()
            return event

        # Keep this callback minimal — any slow work here (e.g. AppKit calls)
        # risks tripping the tap watchdog. The frontmost-app snapshot is taken
        # by the main worker via snapshot_target_app() instead.
        if handle_quartz_hotkey_event(Quartz, event_type, event):
            return None
        return event

    mask = (
        (1 << Quartz.kCGEventKeyDown)
        | (1 << Quartz.kCGEventKeyUp)
        | (1 << Quartz.kCGEventFlagsChanged)
    )
    tap  = Quartz.CGEventTapCreate(
        Quartz.kCGSessionEventTap,
        Quartz.kCGHeadInsertEventTap,
        Quartz.kCGEventTapOptionDefault,
        mask,
        _callback,
        None,
    )
    if tap is None:
        raise RuntimeError(
            "CGEventTapCreate returned None — grant Accessibility permission:\n"
            "  System Settings > Privacy & Security > Accessibility"
        )

    source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
    loop   = Quartz.CFRunLoopGetCurrent()
    Quartz.CFRunLoopAddSource(loop, source, Quartz.kCFRunLoopDefaultMode)
    Quartz.CGEventTapEnable(tap, True)
    _set_hotkey_listener_status("event-tap")
    Quartz.CFRunLoopRun()   # blocks until CFRunLoopStop is called


def _run_pynput_fallback() -> None:
    """Fallback: pynput listener — tracks key state but does not suppress events."""
    from pynput import keyboard

    def on_press(key):
        if key == keyboard.Key.f12:
            _hotkeys.handle_event("key_down", _VK_F12)
        elif key == keyboard.Key.ctrl_r:
            _hotkeys.handle_event("flags_changed", _VK_RIGHT_CONTROL, True)

    def on_release(key):
        if key == keyboard.Key.f12:
            _hotkeys.handle_event("key_up", _VK_F12)
        elif key == keyboard.Key.ctrl_r:
            _hotkeys.handle_event("flags_changed", _VK_RIGHT_CONTROL, False)

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


def _start_hotkey_listener() -> None:
    def _thread_fn():
        _set_hotkey_listener_status("starting")
        try:
            _run_cg_event_tap()
        except Exception as exc:
            _set_hotkey_listener_status("fallback")
            print(
                f"[voice-type] CGEventTap failed ({exc}); "
                "using pynput fallback (hotkey events will not be suppressed).",
                flush=True,
            )
            try:
                _run_pynput_fallback()
            except Exception as fallback_exc:
                _set_hotkey_listener_status("failed")
                print(
                    f"[voice-type] pynput hotkey fallback failed ({fallback_exc}).",
                    flush=True,
                )

    t = threading.Thread(target=_thread_fn, daemon=True, name="voice-type-hotkey")
    t.start()


def _ensure_listener() -> None:
    global _listener_started
    if not _listener_started:
        _start_hotkey_listener()
        _listener_started = True


def is_hotkey_down() -> bool:
    """Return True if F12 or Right Control is currently held."""
    _ensure_listener()
    return _hotkeys.is_down()


def snapshot_target_app() -> None:
    """Capture the frontmost app at push-to-talk key-down time.

    Called by the main worker on the key-down transition — deliberately off
    the CGEventTap callback thread, since AppKit calls there are slow enough
    to trip the tap watchdog and get the whole tap disabled.
    """
    global _target_app
    try:
        from AppKit import NSWorkspace
        _target_app = NSWorkspace.sharedWorkspace().frontmostApplication()
    except Exception:
        _target_app = None


# ---------------------------------------------------------------------------
# Monitor work area
# ---------------------------------------------------------------------------

def get_foreground_monitor_work_area() -> tuple[int, int, int, int]:
    """Return (left, top, right, bottom) of the main screen's visible work area.

    AppKit uses a bottom-left origin; we convert to the top-left origin that
    tkinter uses.  Raises on failure so Overlay._position() falls back to
    winfo_screenwidth/height.
    """
    from AppKit import NSScreen  # type: ignore[import]
    screen  = NSScreen.mainScreen()
    visible = screen.visibleFrame()
    total_h = screen.frame().size.height
    left   = int(visible.origin.x)
    top    = int(total_h - visible.origin.y - visible.size.height)
    right  = int(visible.origin.x + visible.size.width)
    bottom = int(total_h - visible.origin.y)
    return left, top, right, bottom


# ---------------------------------------------------------------------------
# Text injection via NSPasteboard + Cmd+V via direct CGEventPost
#
# pynput's Controller.type() internally calls TSM (Text Services Manager)
# APIs that are main-thread-only.  paste_text() runs on a background thread,
# which causes a SIGTRAP dispatch_assert_queue crash.
#
# Fix: copy text to NSPasteboard, then simulate Cmd+V using CGEventPost
# directly. CGEventPost is explicitly thread-safe. Every pasteboard item and
# type is saved and restored so images, files, rich text, and empty clipboards
# survive injection as well as plain text.
# ---------------------------------------------------------------------------

# macOS virtual keycodes
_VK_CMD       = 55   # left Command
_VK_V         = 9    # V (QWERTY)
_VK_BACKSPACE = 51   # Delete / Backspace


def _post_events(vk_sequence: list[tuple[int, bool, int]]) -> None:
    """Post a sequence of (vk, is_down, flags) keyboard events via CGEventPost."""
    import Quartz
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for vk, is_down, flags in vk_sequence:
        ev = Quartz.CGEventCreateKeyboardEvent(src, vk, is_down)
        Quartz.CGEventSetFlags(ev, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _snapshot_pasteboard(pasteboard) -> list[list[tuple[object, bytes]]]:
    """Materialize every item and type before temporarily replacing it."""
    snapshot: list[list[tuple[object, bytes]]] = []
    for item in pasteboard.pasteboardItems() or []:
        saved_types = []
        for pasteboard_type in item.types() or []:
            data = item.dataForType_(pasteboard_type)
            if data is not None:
                # Copy the bytes now. Pasteboard data providers can be lazy and
                # their objects may no longer be valid after clearContents().
                saved_types.append((pasteboard_type, bytes(data)))
        snapshot.append(saved_types)
    return snapshot


def _restore_pasteboard(pasteboard, snapshot, item_class=None) -> None:
    """Replace the pasteboard with a previously materialized snapshot."""
    if item_class is None:
        from AppKit import NSPasteboardItem
        item_class = NSPasteboardItem

    restored_items = []
    for saved_types in snapshot:
        item = item_class.alloc().init()
        for pasteboard_type, data in saved_types:
            item.setData_forType_(data, pasteboard_type)
        restored_items.append(item)

    pasteboard.clearContents()
    if restored_items:
        pasteboard.writeObjects_(restored_items)


def inject_text(text: str, log: Callable[[str], None] | None = None) -> None:
    import time
    from AppKit import NSPasteboard, NSPasteboardTypeString

    # Re-activate the app that had focus when recording started.
    # The overlay appearing may have moved focus away.
    restore_target_app_focus()
    time.sleep(0.15)  # wait for the app to actually come to front

    pasteboard = NSPasteboard.generalPasteboard()
    snapshot = _snapshot_pasteboard(pasteboard)

    try:
        pasteboard.clearContents()
        if not pasteboard.setString_forType_(text, NSPasteboardTypeString):
            raise RuntimeError("Could not put transcription on the pasteboard")
        time.sleep(0.05)  # give the target app a stable pasteboard value

        # Simulate Cmd+V: Command down, V down, V up, Command up.
        import Quartz
        cmd_flag = Quartz.kCGEventFlagMaskCommand
        _post_events([
            (_VK_CMD, True,  cmd_flag),
            (_VK_V,   True,  cmd_flag),
            (_VK_V,   False, cmd_flag),
            (_VK_CMD, False, 0),
        ])
        time.sleep(0.1)  # let paste complete before restoring the pasteboard
    finally:
        _restore_pasteboard(pasteboard, snapshot)

    if log:
        log(f"NSPasteboard+Cmd+V: {len(text)} chars injected")


def inject_backspaces(count: int, log: Callable[[str], None] | None = None) -> None:
    if count <= 0:
        return
    events = []
    for _ in range(count):
        events.append((_VK_BACKSPACE, True,  0))
        events.append((_VK_BACKSPACE, False, 0))
    _post_events(events)
    if log:
        log(f"CGEventPost: {count} backspace(s) injected")


def restore_target_app_focus() -> None:
    if _target_app is None:
        return
    try:
        _NSApplicationActivateIgnoringOtherApps = 1 << 1
        _target_app.activateWithOptions_(_NSApplicationActivateIgnoringOtherApps)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Login item / startup — LaunchAgent plist
# ---------------------------------------------------------------------------

def _launch_agent_path() -> str:
    override = os.environ.get("VOICE_TYPE_LAUNCH_AGENT_PATH")
    if override:
        return os.path.realpath(os.path.expanduser(override))
    agents_dir = os.path.expanduser("~/Library/LaunchAgents")
    return os.path.join(agents_dir, f"{_LAUNCH_AGENT_LABEL}.plist")


def _install_dir() -> str:
    configured = os.environ.get(
        "VOICE_TYPE_INSTALL_DIR",
        "~/Library/Application Support/Voice Type",
    )
    return os.path.realpath(os.path.expanduser(configured))


def _log_dir() -> str:
    configured = os.environ.get(
        "VOICE_TYPE_LOG_DIR",
        "~/Library/Logs/Voice Type",
    )
    return os.path.realpath(os.path.expanduser(configured))


def _launchd_domain() -> str:
    return f"gui/{os.getuid()}"


def _launchd_service(domain: str) -> str:
    return f"{domain}/{_LAUNCH_AGENT_LABEL}"


def startup_enabled(vbs_path: str = "") -> bool:
    return os.path.exists(_launch_agent_path())


def restart_supervisor_active() -> bool:
    # A loaded LaunchAgent does not prove that this particular process belongs
    # to it. Direct/manual launches are supported too, and launchd only sets
    # XPC_SERVICE_NAME on the process it started.
    return os.environ.get("XPC_SERVICE_NAME") == _LAUNCH_AGENT_LABEL


def set_startup(enable: bool, vbs_path: str = "",
                log: Callable[[str], None] | None = None) -> None:
    plist_path = _launch_agent_path()
    domain = _launchd_domain()
    service = _launchd_service(domain)
    if enable:
        install_dir = _install_dir()
        launcher_bin = os.path.join(install_dir, ".venv", "bin", "Voice Type")
        app_path = os.path.join(install_dir, "voice-type.py")
        launch_wrapper = os.path.join(install_dir, "launch-voice-type-mac.sh")
        log_path = os.path.join(_log_dir(), "launchd.log")
        if not os.path.exists(launcher_bin):
            setup_path = os.path.join(install_dir, "setup_mac.sh")
            message = (
                f"voice-type launcher missing at '{launcher_bin}'. "
                f"Run setup first from the repository: bash tools/voice-type/setup_mac.sh "
                f"(installed helper: {setup_path})"
            )
            if log:
                log(message)
            return
        if not os.path.isfile(app_path):
            message = (
                f"voice-type installed worker missing at '{app_path}'. "
                "Run setup again: bash tools/voice-type/setup_mac.sh"
            )
            if log:
                log(message)
            return
        if not os.access(launch_wrapper, os.X_OK):
            message = (
                f"voice-type launch wrapper missing at '{launch_wrapper}'. "
                "Run setup again: bash tools/voice-type/setup_mac.sh"
            )
            if log:
                log(message)
            return
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{_LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{launch_wrapper}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>{install_dir}</string>
  <key>StandardOutPath</key>
  <string>{log_path}</string>
  <key>StandardErrorPath</key>
  <string>{log_path}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
</dict>
</plist>
"""
        os.makedirs(os.path.dirname(plist_path), exist_ok=True)
        with open(plist_path, "w", encoding="utf-8") as f:
            f.write(plist)
        subprocess.run(["launchctl", "bootout", service], check=False)
        subprocess.run(["launchctl", "bootstrap", domain, plist_path], check=False)
        subprocess.run(["launchctl", "kickstart", "-k", service], check=False)
        if log:
            log(f"Run on Startup enabled ({plist_path}).")
    else:
        subprocess.run(["launchctl", "bootout", service], check=False)
        if os.path.exists(plist_path):
            os.remove(plist_path)
        if log:
            log("Run on Startup disabled.")


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

def cuda_available() -> bool:
    """No CUDA on macOS; faster-whisper runs on CPU."""
    return False


def _apply_accessory_policy() -> None:
    """Set NSApplicationActivationPolicyAccessory (1).

    Safe to call multiple times — tkinter and pystray can each reset the
    policy back to Regular (0) when they call sharedApplication(), so we
    re-apply it at several points during startup.
    """
    try:
        from AppKit import NSApp
        NSApp.setActivationPolicy_(1)
    except Exception:
        pass


def setup_process() -> None:
    """Called before any GUI init — first chance to set the policy."""
    _apply_accessory_policy()
    _install_lifecycle_observers()


def apply_overlay_no_activate(root) -> None:
    """Prevent the overlay from holding key-window status on macOS.

    tkinter's Tk() init can reset NSApp's activation policy back to Regular,
    so we re-apply Accessory here (synchronously, after Tk is constructed)
    and again in a deferred callback once the run loop starts.
    """
    # Re-apply after tkinter may have reset it
    _apply_accessory_policy()

    def _resign_key():
        try:
            from AppKit import NSApp
            # Re-apply policy each time as pystray/tk can flip it back
            _apply_accessory_policy()
            for ns_win in NSApp.windows():
                if ns_win.isKeyWindow():
                    ns_win.resignKeyWindow()
        except Exception:
            pass

    root.after(100, _resign_key)

    # Re-resign after every deiconify (each time the overlay is shown)
    _orig_deiconify = root.deiconify
    def _patched_deiconify(*args, **kwargs):
        _orig_deiconify(*args, **kwargs)
        root.after(30, _resign_key)
    root.deiconify = _patched_deiconify


def open_log(path: str) -> None:
    subprocess.run(["open", path], check=False)


def activate_settings_window() -> None:
    """Bring the accessory app forward when its normal settings window opens."""
    try:
        from AppKit import NSApp
        NSApp.activateIgnoringOtherApps_(True)
    except Exception:
        pass


def get_foreground_window_title() -> str:
    try:
        from AppKit import NSWorkspace  # type: ignore[import]
        app = NSWorkspace.sharedWorkspace().activeApplication()
        return app.get("NSApplicationName", "unknown") if app else "unknown"
    except Exception:
        return "unknown"
