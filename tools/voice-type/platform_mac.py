"""macOS platform implementations for voice-type."""

from __future__ import annotations

import os
import subprocess
import threading
from typing import Callable

_LAUNCH_AGENT_LABEL = "com.mikerosoft.voice-type"

_hotkey_down      = False
_hotkey_lock      = threading.Lock()
_listener_started = False

# The app that was frontmost when the push-to-talk key went down.
# Saved before our overlay can steal focus; re-activated before pasting.
_target_app: object = None

# Right Option key identifiers
_VK_RIGHT_OPTION  = 61          # macOS virtual keycode for Right Option
_NX_DEVALT_RIGHT  = 0x000040    # NX_DEVICERALTKEYMASK — set in CGEvent flags only when
                                 # right option (not left) is physically held


def setup_dll_paths() -> None:
    pass


# ---------------------------------------------------------------------------
# Hotkey — CGEventTap intercepts Right Option at the system level.
#
# Using CGEventTapOptionDefault (not ListenOnly) means we can suppress the
# event by returning None from the callback.  This prevents Right Option from
# reaching other apps entirely, so Option+letter special characters are never
# accidentally triggered while push-to-talk is in use.
#
# Falls back to a plain pynput listener (no suppression) if the tap cannot
# be created — most likely because Accessibility permission hasn't been
# granted yet.
# ---------------------------------------------------------------------------

def _run_cg_event_tap() -> None:
    """Block the calling thread running a CGEventTap for Right Option."""
    import Quartz

    def _callback(proxy, event_type, event, refcon):
        global _hotkey_down, _target_app
        keycode = int(Quartz.CGEventGetIntegerValueField(
            event, Quartz.kCGKeyboardEventKeycode
        ))
        if keycode != _VK_RIGHT_OPTION:
            return event  # pass all other keys through untouched

        flags   = int(Quartz.CGEventGetFlags(event))
        is_down = bool(flags & _NX_DEVALT_RIGHT)
        with _hotkey_lock:
            if is_down and not _hotkey_down:
                # Key just went down — snapshot the frontmost app NOW, before
                # the overlay has any chance to steal focus from it.
                try:
                    from AppKit import NSWorkspace
                    _target_app = NSWorkspace.sharedWorkspace().frontmostApplication()
                except Exception:
                    _target_app = None
            _hotkey_down = is_down
        return None  # suppress: Right Option never reaches any other app

    mask = 1 << Quartz.kCGEventFlagsChanged
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
    Quartz.CFRunLoopRun()   # blocks until CFRunLoopStop is called


def _run_pynput_fallback() -> None:
    """Fallback: pynput listener — tracks key state but does not suppress events."""
    from pynput import keyboard

    def on_press(key):
        global _hotkey_down, _target_app
        if key == keyboard.Key.alt_r:
            with _hotkey_lock:
                if not _hotkey_down:
                    try:
                        from AppKit import NSWorkspace
                        _target_app = NSWorkspace.sharedWorkspace().frontmostApplication()
                    except Exception:
                        _target_app = None
                _hotkey_down = True

    def on_release(key):
        global _hotkey_down
        if key == keyboard.Key.alt_r:
            with _hotkey_lock:
                _hotkey_down = False

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


def _start_hotkey_listener() -> None:
    def _thread_fn():
        try:
            _run_cg_event_tap()
        except Exception as exc:
            print(
                f"[voice-type] CGEventTap failed ({exc}); "
                "using pynput fallback (Right Option events will not be suppressed).",
                flush=True,
            )
            _run_pynput_fallback()

    t = threading.Thread(target=_thread_fn, daemon=True, name="voice-type-hotkey")
    t.start()


def _ensure_listener() -> None:
    global _listener_started
    if not _listener_started:
        _start_hotkey_listener()
        _listener_started = True


def is_hotkey_down() -> bool:
    """Return True if Right Option is currently held."""
    _ensure_listener()
    with _hotkey_lock:
        return _hotkey_down


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
# Text injection — pbcopy + Cmd+V via direct CGEventPost
#
# pynput's Controller.type() internally calls TSM (Text Services Manager)
# APIs that are main-thread-only.  paste_text() runs on a background thread,
# which causes a SIGTRAP dispatch_assert_queue crash.
#
# Fix: copy text to clipboard with pbcopy, then simulate Cmd+V using
# CGEventPost directly.  CGEventPost is explicitly thread-safe.
# The clipboard is saved and restored around each injection.
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


def inject_text(text: str, log: Callable[[str], None] | None = None) -> None:
    import subprocess
    import time

    # Re-activate the app that had focus when recording started.
    # The Option key or the overlay appearing may have moved focus away.
    if _target_app is not None:
        try:
            _NSApplicationActivateIgnoringOtherApps = 1 << 1
            _target_app.activateWithOptions_(_NSApplicationActivateIgnoringOtherApps)
            time.sleep(0.15)  # wait for the app to actually come to front
        except Exception:
            pass

    # Save current clipboard so we can restore it after pasting
    prev = subprocess.run(["pbpaste"], capture_output=True).stdout

    # Put the transcription in the clipboard
    proc = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
    proc.communicate(text.encode("utf-8"))
    time.sleep(0.05)  # give pbcopy time to commit

    # Simulate Cmd+V: Command down → V down → V up → Command up
    import Quartz
    cmd_flag = Quartz.kCGEventFlagMaskCommand
    _post_events([
        (_VK_CMD, True,  cmd_flag),
        (_VK_V,   True,  cmd_flag),
        (_VK_V,   False, cmd_flag),
        (_VK_CMD, False, 0),
    ])
    time.sleep(0.1)  # let paste complete before restoring clipboard

    # Restore previous clipboard contents
    if prev:
        rp = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
        rp.communicate(prev)

    if log:
        log(f"pbcopy+Cmd+V: {len(text)} chars injected")


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


# ---------------------------------------------------------------------------
# Login item / startup — LaunchAgent plist
# ---------------------------------------------------------------------------

def _launch_agent_path() -> str:
    agents_dir = os.path.expanduser("~/Library/LaunchAgents")
    return os.path.join(agents_dir, f"{_LAUNCH_AGENT_LABEL}.plist")


def _script_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def startup_enabled(vbs_path: str = "") -> bool:
    return os.path.exists(_launch_agent_path())


def set_startup(enable: bool, vbs_path: str = "",
                log: Callable[[str], None] | None = None) -> None:
    plist_path = _launch_agent_path()
    if enable:
        script_dir = _script_dir()
        launcher = os.path.join(script_dir, "voice-type-mac.sh")
        plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{_LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>{launcher}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>{script_dir}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
"""
        os.makedirs(os.path.dirname(plist_path), exist_ok=True)
        with open(plist_path, "w", encoding="utf-8") as f:
            f.write(plist)
        if log:
            log(f"Run on Startup enabled for next login ({plist_path}).")
    else:
        if os.path.exists(plist_path):
            subprocess.run(["launchctl", "unload", plist_path], check=False)
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


def get_foreground_window_title() -> str:
    try:
        from AppKit import NSWorkspace  # type: ignore[import]
        app = NSWorkspace.sharedWorkspace().activeApplication()
        return app.get("NSApplicationName", "unknown") if app else "unknown"
    except Exception:
        return "unknown"
