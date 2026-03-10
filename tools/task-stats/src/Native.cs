using System;
using System.Runtime.InteropServices;

namespace TaskMon {

// ============================================================================
// Native P/Invoke -- Win32 window management + NVML (NVIDIA Management Library)
// ============================================================================
static class Native {
    public const int  WS_EX_NOACTIVATE = 0x08000000; // click won't steal focus
    public const int  WS_EX_TOOLWINDOW = 0x00000080; // hide from Alt+Tab
    public const uint SWP_NOMOVE       = 0x0002;
    public const uint SWP_NOSIZE       = 0x0001;
    public const uint SWP_NOACTIVATE   = 0x0010;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hInsert, int x, int y, int cx, int cy, uint flags);

    // NVML lives in C:\Windows\System32\nvml.dll on any system with NVIDIA drivers.
    // All functions return 0 on success.
    [DllImport("nvml.dll", EntryPoint = "nvmlInit_v2",                     ExactSpelling = true)]
    public static extern int NvmlInit();
    [DllImport("nvml.dll", EntryPoint = "nvmlShutdown",                    ExactSpelling = true)]
    public static extern int NvmlShutdown();
    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetHandleByIndex_v2",   ExactSpelling = true)]
    public static extern int NvmlGetDevice(uint idx, out IntPtr dev);
    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetTemperature",        ExactSpelling = true)]
    public static extern int NvmlGetTemp(IntPtr dev, uint sensor, out uint temp);
    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetUtilizationRates",   ExactSpelling = true)]
    public static extern int NvmlGetUtil(IntPtr dev, out NvmlUtil util);

    // GlobalMemoryStatusEx -- used once at startup to get total physical RAM.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MEMORYSTATUSEX {
        public uint  dwLength;            // must be set to 64 before calling
        public uint  dwMemoryLoad;
        public ulong ullTotalPhys;        // total installed RAM in bytes
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX stat);

    // Used by DoLayout() to locate the system tray so we sit just to its left.
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter,
        string lpszClass, string lpszWindow);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint crKey, byte bAlpha, uint dwFlags);

    public const uint LWA_COLORKEY = 0x00000001;
    public const uint LWA_ALPHA    = 0x00000002;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    public const int GWL_STYLE = -16;
    public const int WS_CHILD  = 0x40000000;
    public const int WS_POPUP  = unchecked((int)0x80000000);
    public const int WS_VISIBLE = 0x10000000;
    public const int WS_CLIPSIBLINGS = 0x04000000;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    public const uint SWP_NOZORDER    = 0x0004;
    public const int  WS_EX_LAYERED   = 0x00080000;
    public const int  ULW_ALPHA       = 2;

    public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);
    
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
    
    public const int WH_MOUSE_LL = 14;
    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int WM_LBUTTONUP   = 0x0202;
    public const int WM_RBUTTONUP   = 0x0205;
    
    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // UpdateLayeredWindow -- renders a per-pixel-alpha bitmap onto the window.
    // Background pixels use alpha=1 (visually transparent, still receive mouse input).
    // Click-through only happens at alpha=0; alpha>=1 receives mouse events.
    [StructLayout(LayoutKind.Sequential)]
    public struct PTWIN  { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct SZWIN  { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)]
    public struct BLENDFUNCTION {
        public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER {
        public int   biSize, biWidth, biHeight;
        public short biPlanes, biBitCount;
        public int   biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter;
        public int   biClrUsed, biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; public int bmiColors; }

    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int    ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")]
    public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst,
        ref PTWIN pptDst, ref SZWIN psize, IntPtr hdcSrc, ref PTWIN pptSrc,
        int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool   DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr h);
    [DllImport("gdi32.dll")] public static extern bool   DeleteObject(IntPtr ho);
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO pbmi,
        uint iUsage, out IntPtr ppvBits, IntPtr hSection, uint dwOffset);
}

[StructLayout(LayoutKind.Sequential)]
public struct NvmlUtil {
    public uint gpu;    // GPU engine utilisation %
    public uint memory; // GPU memory bandwidth utilisation %
}

} // namespace TaskMon
