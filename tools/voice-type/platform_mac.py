"""macOS platform implementations for voice-type."""

from __future__ import annotations

import os
import subprocess
import threading
from typing import Callable

_LAUNCH_AGENT_LABEL = "com.mikerosoft.voice-type"
_LAUNCHD_LOG_NAME = "voice-type-launchd.log"

_hotkey_down      = False
_hotkey_lock      = threading.Lock()
_listener_started = False

# The app that was frontmost when the push-to-talk key went down.
# Saved before our overlay can steal focus; re-activated before pasting.
_target_app: object = None

# F12 key identifier
_VK_F12 = 111  # macOS virtual keycode for F12


def setup_dll_paths() -> None:
    pass


# ---------------------------------------------------------------------------
# Hotkey — CGEventTap intercepts F12 at the system level.
#
# Using CGEventTapOptionDefault (not ListenOnly) means we can suppress the
# event by returning None from the callback, so macOS won't also handle F12.
#
# Falls back to a plain pynput listener (no suppression) if the tap cannot
# be created — most likely because Accessibility permission hasn't been
# granted yet.
# ---------------------------------------------------------------------------

def _run_cg_event_tap() -> None:
    """Block the calling thread running a CGEventTap for F12."""
    import Quartz

    def _callback(proxy, event_type, event, refcon):
        global _hotkey_down
        # macOS auto-disables an event tap if its callback is ever judged too
        # slow, or on certain user-input conditions. When that happens we stop
        # receiving events entirely — including the F12 KeyUp — which would
        # leave _hotkey_down stuck True forever. Re-enable the tap and assume
        # the key was released, since the KeyUp may have been dropped.
        if event_type in (
            Quartz.kCGEventTapDisabledByTimeout,
            Quartz.kCGEventTapDisabledByUserInput,
        ):
            Quartz.CGEventTapEnable(tap, True)
            with _hotkey_lock:
                _hotkey_down = False
            return event

        keycode = int(Quartz.CGEventGetIntegerValueField(
            event, Quartz.kCGKeyboardEventKeycode
        ))
        if keycode != _VK_F12:
            return event  # pass all other keys through untouched

        # Keep this callback minimal — any slow work here (e.g. AppKit calls)
        # risks tripping the tap watchdog. The frontmost-app snapshot is taken
        # by the main worker via snapshot_target_app() instead.
        with _hotkey_lock:
            if event_type == Quartz.kCGEventKeyDown:
                _hotkey_down = True
            elif event_type == Quartz.kCGEventKeyUp:
                _hotkey_down = False
        return None  # suppress: F12 never reaches any other app

    mask = (1 << Quartz.kCGEventKeyDown) | (1 << Quartz.kCGEventKeyUp)
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
        global _hotkey_down
        if key == keyboard.Key.f12:
            with _hotkey_lock:
                _hotkey_down = True

    def on_release(key):
        global _hotkey_down
        if key == keyboard.Key.f12:
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
                "using pynput fallback (F12 events will not be suppressed).",
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
    """Return True if F12 is currently held."""
    _ensure_listener()
    with _hotkey_lock:
        return _hotkey_down


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
    # The overlay appearing may have moved focus away.
    restore_target_app_focus()
    time.sleep(0.15)  # wait for the app to actually come to front

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
    agents_dir = os.path.expanduser("~/Library/LaunchAgents")
    return os.path.join(agents_dir, f"{_LAUNCH_AGENT_LABEL}.plist")


def _script_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def _launchd_domain() -> str:
    return f"gui/{os.getuid()}"


def _launchd_service(domain: str) -> str:
    return f"{domain}/{_LAUNCH_AGENT_LABEL}"


def startup_enabled(vbs_path: str = "") -> bool:
    return os.path.exists(_launch_agent_path())


def set_startup(enable: bool, vbs_path: str = "",
                log: Callable[[str], None] | None = None) -> None:
    plist_path = _launch_agent_path()
    domain = _launchd_domain()
    service = _launchd_service(domain)
    if enable:
        script_dir = _script_dir()
        python_bin = os.path.join(script_dir, ".venv", "bin", "python3")
        app_path = os.path.join(script_dir, "voice-type.py")
        log_path = os.path.join(script_dir, _LAUNCHD_LOG_NAME)
        if not os.path.exists(python_bin):
            setup_path = os.path.join(script_dir, "setup_mac.sh")
            message = (
                f"voice-type Python interpreter missing at '{python_bin}'. "
                f"Run setup first: bash {setup_path}"
            )
            if log:
                log(message)
            return
        plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{_LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{python_bin}</string>
    <string>{app_path}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>{script_dir}</string>
  <key>StandardOutPath</key>
  <string>{log_path}</string>
  <key>StandardErrorPath</key>
  <string>{log_path}</string>
  <key>RunAtLoad</key>
  <true/>
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
