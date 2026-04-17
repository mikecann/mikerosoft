"""Windows platform implementations for voice-type."""

from __future__ import annotations

import ctypes
import ctypes.wintypes
import os
import sys
import winreg
from typing import Callable

_user32 = ctypes.windll.user32

_KEYEVENTF_KEYUP   = 0x0002
_KEYEVENTF_UNICODE = 0x0004
_VK_BACK           = 0x08
_INPUT_KEYBOARD    = 1
_HOTKEY_VK         = 0xA3   # VK_RCONTROL — Right Ctrl only

_REG_RUN  = r"Software\Microsoft\Windows\CurrentVersion\Run"
_REG_NAME = "VoiceType"


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk",         ctypes.c_ushort),
        ("wScan",       ctypes.c_ushort),
        ("dwFlags",     ctypes.c_uint32),
        ("time",        ctypes.c_uint32),
        ("dwExtraInfo", ctypes.c_uint64),
    ]


class _INPUT_UNION(ctypes.Union):
    _fields_ = [
        ("ki",   _KEYBDINPUT),
        ("_pad", ctypes.c_byte * 28),
    ]


class _INPUT(ctypes.Structure):
    _fields_ = [
        ("type",  ctypes.c_uint32),
        ("union", _INPUT_UNION),
    ]


class _MONITORINFOEX(ctypes.Structure):
    _fields_ = [
        ("cbSize",    ctypes.c_uint32),
        ("rcMonitor", ctypes.wintypes.RECT),
        ("rcWork",    ctypes.wintypes.RECT),
        ("dwFlags",   ctypes.c_uint32),
    ]


def setup_process() -> None:
    pass


def setup_dll_paths() -> None:
    """Add PyTorch DLL directory so ctranslate2 can find cublas64_12.dll."""
    try:
        import torch as _torch
        _torch_lib = os.path.join(os.path.dirname(_torch.__file__), "lib")
        if os.path.isdir(_torch_lib):
            os.add_dll_directory(_torch_lib)
    except Exception:
        pass


def is_hotkey_down() -> bool:
    """Return True if the push-to-talk key (Right Ctrl) is currently held."""
    return bool(_user32.GetAsyncKeyState(_HOTKEY_VK) & 0x8000)


def get_foreground_monitor_work_area() -> tuple[int, int, int, int]:
    """Return (left, top, right, bottom) work area of the monitor containing the focused window."""
    MONITOR_DEFAULTTONEAREST = 2
    hwnd = _user32.GetForegroundWindow()
    hmon = _user32.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)
    info = _MONITORINFOEX()
    info.cbSize = ctypes.sizeof(_MONITORINFOEX)
    ctypes.windll.user32.GetMonitorInfoW(hmon, ctypes.byref(info))
    r = info.rcWork
    return r.left, r.top, r.right, r.bottom


def inject_text(text: str, log: Callable[[str], None] | None = None) -> None:
    """Inject text via SendInput (KEYEVENTF_UNICODE) — clipboard is never touched."""
    inputs = []
    for ch in text:
        code = ord(ch)
        if code > 0xFFFF:
            code -= 0x10000
            chars = [0xD800 | (code >> 10), 0xDC00 | (code & 0x3FF)]
        else:
            chars = [code]
        for scan in chars:
            for flags in (_KEYEVENTF_UNICODE, _KEYEVENTF_UNICODE | _KEYEVENTF_KEYUP):
                inp = _INPUT()
                inp.type                 = _INPUT_KEYBOARD
                inp.union.ki.wVk         = 0
                inp.union.ki.wScan       = scan
                inp.union.ki.dwFlags     = flags
                inp.union.ki.time        = 0
                inp.union.ki.dwExtraInfo = 0
                inputs.append(inp)
    if not inputs:
        return
    arr  = (_INPUT * len(inputs))(*inputs)
    sent = ctypes.windll.user32.SendInput(len(inputs), arr, ctypes.sizeof(_INPUT))
    if log:
        log(f"SendInput: {sent}/{len(inputs) // 2} char events delivered")


def inject_backspaces(count: int, log: Callable[[str], None] | None = None) -> None:
    """Send `count` Backspace key presses via SendInput."""
    if count <= 0:
        return
    inputs = []
    for _ in range(count):
        for flags in (0, _KEYEVENTF_KEYUP):
            inp = _INPUT()
            inp.type                 = _INPUT_KEYBOARD
            inp.union.ki.wVk         = _VK_BACK
            inp.union.ki.wScan       = 0
            inp.union.ki.dwFlags     = flags
            inp.union.ki.time        = 0
            inp.union.ki.dwExtraInfo = 0
            inputs.append(inp)
    arr  = (_INPUT * len(inputs))(*inputs)
    sent = ctypes.windll.user32.SendInput(len(inputs), arr, ctypes.sizeof(_INPUT))
    if log:
        log(f"SendInput: {sent}/{len(inputs) // 2} backspace events delivered")


def startup_enabled(vbs_path: str) -> bool:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _REG_RUN) as k:
            winreg.QueryValueEx(k, _REG_NAME)
            return True
    except OSError:
        return False


def set_startup(enable: bool, vbs_path: str,
                log: Callable[[str], None] | None = None) -> None:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _REG_RUN,
                            access=winreg.KEY_SET_VALUE) as k:
            if enable:
                winreg.SetValueEx(k, _REG_NAME, 0, winreg.REG_SZ,
                                  f'wscript.exe "{vbs_path}"')
                if log:
                    log("Run on Startup enabled.")
            else:
                winreg.DeleteValue(k, _REG_NAME)
                if log:
                    log("Run on Startup disabled.")
    except Exception as e:
        if log:
            log(f"Startup toggle failed: {e}")


def cuda_available() -> bool:
    try:
        import ctranslate2
        if ctranslate2.get_cuda_device_count() == 0:
            return False
        ctypes.cdll.LoadLibrary("cublas64_12.dll")
        return True
    except Exception:
        return False


def apply_overlay_no_activate(root) -> None:
    """Apply WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW so the overlay never steals focus."""
    GWL_EXSTYLE      = -20
    WS_EX_NOACTIVATE = 0x08000000
    WS_EX_TOOLWINDOW = 0x00000080
    hwnd  = root.winfo_id()
    style = _user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
    _user32.SetWindowLongW(hwnd, GWL_EXSTYLE,
                           style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW)


def open_log(path: str) -> None:
    os.startfile(path)


def get_foreground_window_title() -> str:
    hwnd = _user32.GetForegroundWindow()
    buf  = ctypes.create_unicode_buffer(256)
    _user32.GetWindowTextW(hwnd, buf, 256)
    return buf.value
