using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TaskMon {

// =============================================================================
// DBPanel -- double-buffered Panel eliminates all GDI+ flicker
// =============================================================================
class DBPanel : Panel {
    public DBPanel() {
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.UserPaint            |
            ControlStyles.OptimizedDoubleBuffer, true);
        ResizeRedraw = true;
    }
}

// =============================================================================
// OverlayForm -- frameless, always-on-top window overlaid on the taskbar
// =============================================================================
public class OverlayForm : Form {
    public  Settings S;
    readonly IMetricsSource _metricsSource;
    readonly OverlayFormOptions _options;
    readonly IProcessLauncher _processLauncher;
    readonly ISectionContextProvider _sectionContextProvider;
    MetricsSnapshot _snapshot;
    internal string _scriptDir; // set by App.Run() -- needed to update startup reg entry
    internal System.Windows.Forms.Timer _timer;
    ContextMenuStrip _menu;
    ContextMenuStrip _graphMenu;
    NotifyIcon _notify;

    // Pre-allocated GDI resources -- created once in AllocGdi(), never in paint loop.
    Font       _fLbl, _fVal;
    SolidBrush _dimBrush, _coreBgBrush;
    Pen        _divPen;
    Color      _cUp, _cDn, _cCpu, _cGpu, _cGpuTemp, _cMem;

    Native.LowLevelMouseProc _mouseProc;
    IntPtr _mouseHookId = IntPtr.Zero;

    public OverlayForm(Settings s, string scriptDir = null, IMetricsSource metricsSource = null,
                       OverlayFormOptions options = null, IProcessLauncher processLauncher = null,
                       ISectionContextProvider sectionContextProvider = null) {
        S          = s;
        _scriptDir = scriptDir;
        _options = options ?? new OverlayFormOptions();
        _processLauncher = processLauncher ?? new ProcessLauncher();
        _sectionContextProvider = sectionContextProvider ?? new LiveSectionContextProvider();
        _metricsSource = metricsSource ?? new LiveMetricsSource(s.NetworkAdapter);
        _snapshot = _metricsSource.Sample();
        _sectionContextProvider.Refresh();
        AllocGdi();

        FormBorderStyle = FormBorderStyle.None;
        StartPosition   = FormStartPosition.Manual;
        ShowInTaskbar   = false;
        BackColor       = Color.FromArgb(16, 16, 16);
        if (_options.TransparentBackground)
            TransparencyKey = Color.FromArgb(16, 16, 16);
        
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer, true);
                 
        // We use a Low-Level Mouse Hook because perfectly keyed-out transparent pixels 
        // fall through the normal hit test and receive no Windows mouse messages.
        if (_options.InstallMouseHook) {
            _mouseProc = MouseHookCallback;
            _mouseHookId = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _mouseProc,
                Native.GetModuleHandle(null), 0);
        }

        BuildMenu();
        if (_options.CreateNotifyIcon) BuildNotifyIcon();

        if (_options.StartTimer) {
            _timer = new System.Windows.Forms.Timer { Interval = Math.Max(250, s.UpdateIntervalMs) };
            _timer.Tick += (o, e) => Tick();
            _timer.Start();
        }
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        // We defer SetParent to OnShown to prevent WinForms from resetting it.
    }

    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        if (_options.AttachToTaskbar) {
            IntPtr trayWnd = Native.FindWindow("Shell_TrayWnd", null);
            if (trayWnd != IntPtr.Zero) {
                int style = Native.GetWindowLong(Handle, Native.GWL_STYLE);
                style = (style & ~Native.WS_POPUP) | Native.WS_CHILD | Native.WS_VISIBLE | Native.WS_CLIPSIBLINGS;
                Native.SetWindowLong(Handle, Native.GWL_STYLE, style);
                Native.SetParent(Handle, trayWnd);
                
                byte globalAlpha = (byte)Math.Max(1, Math.Min(255, (int)(OverlayFormatting.ClampOpacity(S.Opacity) * 255)));
                if (_options.TransparentBackground) {
                    // 0x00101010 is the COLORREF (0x00bbggrr) for RGB(16, 16, 16)
                    Native.SetLayeredWindowAttributes(Handle, 0x00101010, globalAlpha, Native.LWA_COLORKEY | Native.LWA_ALPHA);
                } else {
                    Native.SetLayeredWindowAttributes(Handle, 0, globalAlpha, Native.LWA_ALPHA);
                }
                
                // Put our window at the top of the Z-order so it isn't hidden by the DesktopWindowContentBridge
                Native.SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, 
                    Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
            }
        }
        DoLayout();
    }

    // WS_EX_NOACTIVATE: clicks do not steal keyboard focus.
    // WS_EX_TOOLWINDOW: keeps the overlay out of the Alt+Tab list.
    protected override CreateParams CreateParams { get {
        var p = base.CreateParams;
        p.ExStyle |= Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_LAYERED;
        return p;
    }}

    void Tick() {
        RefreshNow();
    }

    public void RefreshNow() {
        _snapshot = _metricsSource.Sample();
        if (_sectionContextProvider != null) _sectionContextProvider.Refresh();
        DoLayout();
        Invalidate();
        Update();
    }

    // Position the overlay just to the left of the system tray / clock area.
    internal void DoLayout() {
        int w = OverlayLayout.CalculateWidth(S, _snapshot.CoreCount);
        if (!_options.AttachToTaskbar) {
            if (_options.FixedBounds.HasValue) Bounds = _options.FixedBounds.Value;
            else Bounds = new Rectangle(100, 100, w, 40);
            return;
        }

        IntPtr trayWnd = Native.FindWindow("Shell_TrayWnd", null);
        if (trayWnd == IntPtr.Zero) return;

        Native.RECT trayRect;
        if (!Native.GetWindowRect(trayWnd, out trayRect)) return;
        int tbH = trayRect.Bottom - trayRect.Top;

        int leftEdgeScreen = TrayLeftEdge(Screen.PrimaryScreen);
        int targetLeftScreen = leftEdgeScreen - w;

        var pt = new Native.POINT { X = targetLeftScreen, Y = trayRect.Top };
        Native.ScreenToClient(trayWnd, ref pt);

        Size = new Size(w, tbH);
        Location = new Point(pt.X, 0); 
    }

    // Returns the screen-coordinate left edge of the system tray notification area,
    // accounting for the "show hidden icons" overflow button so we never cover it.
    //
    // Win10 / early Win11: the chevron is a Button child of TrayNotifyWnd.
    // Win11 22H2+:         the chevron moved to a Button child of Shell_TrayWnd
    //                      that sits to the LEFT of TrayNotifyWnd.
    // We check both locations and take the minimum.
    static int TrayLeftEdge(Screen scr) {
        try {
            IntPtr trayWnd = Native.FindWindow("Shell_TrayWnd", null);
            if (trayWnd == IntPtr.Zero) return scr.Bounds.Right;

            IntPtr notifyWnd = Native.FindWindowEx(
                trayWnd, IntPtr.Zero, "TrayNotifyWnd", null);
            if (notifyWnd == IntPtr.Zero) return scr.Bounds.Right;

            Native.RECT nr;
            if (!Native.GetWindowRect(notifyWnd, out nr)) return scr.Bounds.Right;

            int left = nr.Left;

            // Check for chevron Button inside TrayNotifyWnd (Win10 / early Win11).
            IntPtr btn = Native.FindWindowEx(notifyWnd, IntPtr.Zero, "Button", null);
            if (btn != IntPtr.Zero) {
                Native.RECT br;
                if (Native.GetWindowRect(btn, out br))
                    left = Math.Min(left, br.Left);
            }

            // Check for chevron Button as a direct child of Shell_TrayWnd (Win11 22H2+).
            // Enumerate all Button children and take the leftmost one that sits to the
            // left of TrayNotifyWnd (i.e. it is the overflow/chevron, not some other btn).
            IntPtr child = Native.FindWindowEx(trayWnd, IntPtr.Zero, "Button", null);
            while (child != IntPtr.Zero) {
                Native.RECT br;
                if (Native.GetWindowRect(child, out br) && br.Left < nr.Left)
                    left = Math.Min(left, br.Left);
                child = Native.FindWindowEx(trayWnd, child, "Button", null);
            }

            return left;
        } catch { }
        return scr.Bounds.Right;
    }

    void AllocGdi() {
        _fLbl        = new Font("Segoe UI", 6.5f, FontStyle.Regular, GraphicsUnit.Point);
        _fVal        = new Font("Segoe UI", 7.5f, FontStyle.Bold,    GraphicsUnit.Point);
        _dimBrush    = new SolidBrush(Color.FromArgb(0x80, 0x80, 0x80));
        _coreBgBrush = new SolidBrush(Color.FromArgb(0x30, 0x30, 0x30));
        _divPen      = new Pen(Color.FromArgb(0x3C, 0x3C, 0x3C), 1f);
        RefreshColors();
    }

    internal void RefreshColors() {
        _cUp  = OverlayFormatting.ParseHex(S.ColorNetUp,   "#00FF88");
        _cDn  = OverlayFormatting.ParseHex(S.ColorNetDown, "#00AAFF");
        _cCpu = OverlayFormatting.ParseHex(S.ColorCpu,     "#FFB300");
        _cGpu     = OverlayFormatting.ParseHex(S.ColorGpu,     "#FF6B35");
        _cGpuTemp = OverlayFormatting.ParseHex(S.ColorGpuTemp, "#FFDD44");
        _cMem     = OverlayFormatting.ParseHex(S.ColorMemory,  "#CC44FF");
    }

    IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && (wParam == (IntPtr)Native.WM_LBUTTONDOWN || wParam == (IntPtr)Native.WM_RBUTTONDOWN || wParam == (IntPtr)Native.WM_LBUTTONUP || wParam == (IntPtr)Native.WM_RBUTTONUP)) {
            var hookStruct = (Native.MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.MSLLHOOKSTRUCT));
            var pt = new Point(hookStruct.pt.X, hookStruct.pt.Y);

            // Bounds hit test using screen coordinates
            var scrRect = RectangleToScreen(ClientRectangle);
            if (scrRect.Contains(pt)) {
                if (wParam == (IntPtr)Native.WM_RBUTTONDOWN) {
                    var clPt = PointToClient(pt);
                    var section = OverlayLayout.HitTest(S, _snapshot.CoreCount, clPt.X);
                    Native.SetForegroundWindow(Handle);
                    ShowGraphMenu(section, Cursor.Position);
                } else if (wParam == (IntPtr)Native.WM_LBUTTONDOWN) {
                    var clPt = PointToClient(pt);
                    LaunchForSection(OverlayLayout.HitTest(S, _snapshot.CoreCount, clPt.X));
                }
                return new IntPtr(1); // Swallow the event
            }
        }
        return Native.CallNextHookEx(_mouseHookId, nCode, wParam, lParam);
    }

    protected override void Dispose(bool d) {
        if (_mouseHookId != IntPtr.Zero) {
            Native.UnhookWindowsHookEx(_mouseHookId);
            _mouseHookId = IntPtr.Zero;
        }
        if (d) {
            if (_timer  != null) { _timer.Stop();  _timer.Dispose(); }
            if (_notify != null) { _notify.Visible = false; _notify.Dispose(); }
            if (_graphMenu != null) _graphMenu.Dispose();
            if (_sectionContextProvider != null) _sectionContextProvider.Dispose();
            if (_metricsSource != null) _metricsSource.Dispose();
            if (_fLbl        != null) _fLbl.Dispose();
            if (_fVal        != null) _fVal.Dispose();
            if (_dimBrush    != null) _dimBrush.Dispose();
            if (_coreBgBrush != null) _coreBgBrush.Dispose();
            if (_divPen      != null) _divPen.Dispose();
        }
        base.Dispose(d);
    }

    // Creates the 16x16 sparkline bar icon used for both the tray and the settings title bar.
    internal static Icon MakeAppIcon() {
        using (var bmp = new Bitmap(16, 16))
        using (var g = Graphics.FromImage(bmp)) {
            g.Clear(Color.Transparent);
            var bars = new[] {
                new { C = Color.FromArgb(0xFF, 0x40, 0x40), X = 1,  H = 5  },
                new { C = Color.FromArgb(0xFF, 0xB3, 0x00), X = 5,  H = 9  },
                new { C = Color.FromArgb(0xFF, 0x6B, 0x35), X = 9,  H = 6  },
                new { C = Color.FromArgb(0xCC, 0x44, 0xFF), X = 13, H = 11 },
            };
            foreach (var b in bars)
                g.FillRectangle(new SolidBrush(b.C), b.X, 15 - b.H, 2, b.H);
            return Icon.FromHandle(bmp.GetHicon());
        }
    }

    // Loads a famfamfam silk icon embedded as a manifest resource.
    // Resource names follow the MSBuild convention: TaskMon.icons.<name>.png
    internal static Image LoadIcon(string name) {
        var stream = typeof(OverlayForm).Assembly
            .GetManifestResourceStream("TaskMon.icons." + name + ".png");
        return stream != null ? Image.FromStream(stream) : null;
    }

    void BuildNotifyIcon() {
        _notify = new NotifyIcon {
            Icon             = MakeAppIcon(),
            Text             = "task-stats",
            ContextMenuStrip = _menu,
            Visible          = true
        };
        _notify.DoubleClick += (o, e) => OpenSettings();
    }

    // Left-click on any panel opens Resource Monitor.
    void LaunchForSection(Section sec) {
        if (sec != Section.None) LaunchResmon();
    }

    void LaunchResmon()  { _processLauncher.Launch("resmon.exe"); }
    void LaunchTaskMgr() { _processLauncher.Launch("taskmgr.exe"); }

    void BuildMenu() {
        _menu = CreateMenuShell();
        AddGlobalMenuItems(_menu);
    }

    void ShowGraphMenu(Section section, Point screenPos) {
        if (_graphMenu != null) {
            _graphMenu.Dispose();
            _graphMenu = null;
        }
        _graphMenu = CreateMenuShell();
        AddSectionContextItems(_graphMenu, section);
        AddGlobalMenuItems(_graphMenu);
        _graphMenu.Show(screenPos);
    }

    ContextMenuStrip CreateMenuShell() {
        return new ContextMenuStrip {
            BackColor = Color.FromArgb(0x2D, 0x2D, 0x2D),
            ForeColor = Color.White,
            Renderer  = new DarkRenderer()
        };
    }

    void AddSectionContextItems(ContextMenuStrip menu, Section section) {
        if (section == Section.None || _sectionContextProvider == null) return;

        var info = _sectionContextProvider.GetContextInfo(section);
        if (info == null) return;

        var title = new ToolStripMenuItem(info.Title) { Enabled = false };
        menu.Items.Add(title);
        if (info.Rows != null && info.Rows.Length > 0) {
            for (int i = 0; i < info.Rows.Length; i++) {
                var row = info.Rows[i];
                string text = string.Format("{0} ({1})  {2}", row.Name, row.ProcessId, row.Value);
                menu.Items.Add(new ToolStripMenuItem(text) { Enabled = false });
            }
        }

        if (info.LaunchesExternalTool) {
            var actionText = string.IsNullOrWhiteSpace(info.ActionText) ? "Open details" : info.ActionText;
            var command = info.LaunchCommand;
            var actionItem = new ToolStripMenuItem(actionText);
            actionItem.Click += (o, e) => _processLauncher.Launch(command);
            menu.Items.Add(actionItem);
        }

        menu.Items.Add(new ToolStripSeparator());
    }

    void AddGlobalMenuItems(ContextMenuStrip menu) {
        var miSet     = new ToolStripMenuItem("Settings...");
        miSet.Click  += (o, e) => OpenSettings();
        miSet.Image   = LoadIcon("cog");

        var miResmon     = new ToolStripMenuItem("Open Resource Monitor");
        miResmon.Click  += (o, e) => LaunchResmon();
        miResmon.Image   = LoadIcon("chart_bar");

        var miTaskMgr     = new ToolStripMenuItem("Open Task Manager");
        miTaskMgr.Click  += (o, e) => LaunchTaskMgr();
        miTaskMgr.Image   = LoadIcon("application_view_list");

        var miQuit     = new ToolStripMenuItem("Quit");
        miQuit.Click  += (o, e) => Application.Exit();
        miQuit.Image   = LoadIcon("door_out");

        menu.Items.AddRange(new ToolStripItem[] {
            miSet, new ToolStripSeparator(), miResmon, miTaskMgr, new ToolStripSeparator(), miQuit
        });
    }

    // Opens the settings dialog.
    void OpenSettings() {
        using (var dlg = new SettingsForm(S, this)) dlg.ShowDialog();
    }

    // -- Standard WinForms painting ---------------------------------------------
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        if (Width <= 0 || Height <= 0) return;

        var g = e.Graphics;
        g.SmoothingMode     = SmoothingMode.None;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;

        g.Clear(BackColor);
        DrawContent(g, Width, Height);
    }

    void DrawContent(Graphics g, int w, int h) {
        // No background fill -- background pixels stay at alpha=1 (set in UpdateLayer),
        // making them visually transparent while still receiving mouse events.
        int x = 0;

        if (S.ShowNetUp) {
            string upVal = OverlayFormatting.SpeedStr(_snapshot.NetUpBps);
            float upScale = Math.Max(100 * 1024f, OverlayFormatting.Max(_snapshot.HNetUp));
            DrawSection(g, ref x, h, "UP \u2191", upVal, _cUp, _snapshot.HNetUp, upScale, upVal);
        }
        if (S.ShowNetDown) {
            string dnVal = OverlayFormatting.SpeedStr(_snapshot.NetDnBps);
            float dnScale = Math.Max(500 * 1024f, OverlayFormatting.Max(_snapshot.HNetDn));
            DrawSection(g, ref x, h, "DL \u2193", dnVal, _cDn, _snapshot.HNetDn, dnScale, dnVal);
        }
        if (S.ShowCpu) {
            if (S.CpuMode == "PerCore")
                DrawCoreGrid(g, ref x, h);
            else {
                string cpuVal = string.Format("{0:F0}%", _snapshot.CpuTotal);
                DrawSection(g, ref x, h, "CPU", cpuVal, _cCpu, _snapshot.HCpu, 100f, cpuVal);
            }
        }
        if (S.ShowGpuUtil || S.ShowGpuTemp)
            DrawGpuSection(g, ref x, h);
        if (S.ShowMemory) {
            string memVal = string.Format("{0:F0}%", _snapshot.MemPct);
            DrawSection(g, ref x, h, "MEM", memVal, _cMem, _snapshot.HMem, 100f, memVal);
        }
    }

    // GPU section: sparkline driven by utilisation; value line shows util% in one
    // colour and temp in a distinct colour so they're easy to tell apart at a glance.
    void DrawGpuSection(Graphics g, ref int x, int h) {
        if (x > 0) g.DrawLine(_divPen, x, 2, x, h - 2);
        DrawSparkline(g, _snapshot.HGpu, new Rectangle(x, 0, OverlayLayout.StandardSectionWidth, h), _cGpu, 100f);
        var sfLblN = new StringFormat { Alignment = StringAlignment.Near,
                                        LineAlignment = StringAlignment.Near };
        var sfLblF = new StringFormat { Alignment = StringAlignment.Far,
                                        LineAlignment = StringAlignment.Near };
        g.DrawString("GPU", _fLbl, _dimBrush,
            new RectangleF(x + 3, 1, OverlayLayout.StandardSectionWidth - 6, h * 0.45f), sfLblN);
        // Show util% (or temp if util is hidden) right-aligned in the label row.
        string gpuHdr = S.ShowGpuUtil
            ? string.Format("{0:F0}%", _snapshot.GpuUtil)
            : string.Format("{0}\u00B0C", _snapshot.GpuTempC);
        using (var b = new SolidBrush(S.ShowGpuUtil ? _cGpu : _cGpuTemp))
            g.DrawString(gpuHdr, _fLbl, b,
                new RectangleF(x + 3, 1, OverlayLayout.StandardSectionWidth - 6, h * 0.45f), sfLblF);

        // When both util and temp are shown, keep temp in the body since the label
        // row only has room for one value (util%).
        if (S.ShowGpuUtil && S.ShowGpuTemp) {
            var sfc = new StringFormat { Alignment = StringAlignment.Center,
                                         LineAlignment = StringAlignment.Center };
            using (var b = new SolidBrush(_cGpuTemp))
                ShadowStr(g, string.Format("{0}\u00B0C", _snapshot.GpuTempC), _fVal, b,
                    new RectangleF(x + 2, h * 0.42f, OverlayLayout.StandardSectionWidth - 4, h * 0.58f), sfc);
        }
        x += OverlayLayout.StandardSectionWidth;
    }

    // Draw one metric section: sparkline fills the background, text is overlaid.
    // headerVal: if non-null, drawn right-aligned in the label row (e.g. "43%" for MEM).
    void DrawSection(Graphics g, ref int x, int h,
                     string lbl, string val, Color col,
                     float[] hist, float scale, string headerVal = null) {
        if (x > 0) g.DrawLine(_divPen, x, 2, x, h - 2);
        DrawSparkline(g, hist, new Rectangle(x, 0, OverlayLayout.StandardSectionWidth, h), col, scale);
        // Label: small dim text at the top-left.
        g.DrawString(lbl, _fLbl, _dimBrush,
            new RectangleF(x + 3, 1, OverlayLayout.StandardSectionWidth - 6, h * 0.45f));
        // Optional right-aligned value in the label row.
        if (headerVal != null) {
            var sfR = new StringFormat { Alignment = StringAlignment.Far,
                                         LineAlignment = StringAlignment.Near };
            using (var b = new SolidBrush(col))
                g.DrawString(headerVal, _fLbl, b,
                    new RectangleF(x + 3, 1, OverlayLayout.StandardSectionWidth - 6, h * 0.45f), sfR);
        }
        // Value: bold coloured text centred in the lower half.
        // Skipped when the value is already shown in the label row.
        if (headerVal == null) {
            var sf = new StringFormat {
                Alignment     = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
                Trimming      = StringTrimming.Character
            };
            using (var b = new SolidBrush(col))
                ShadowStr(g, val, _fVal, b,
                    new RectangleF(x + 2, h * 0.42f, OverlayLayout.StandardSectionWidth - 4, h * 0.58f), sf);
        }
        x += OverlayLayout.StandardSectionWidth;
    }

    // Draws text with a 1px dark drop shadow so it reads clearly over any graph colour.
    static void ShadowStr(Graphics g, string s, Font f, Brush br, RectangleF r, StringFormat sf) {
        var sr = new RectangleF(r.X + 1, r.Y + 1, r.Width, r.Height);
        using (var sh = new SolidBrush(Color.FromArgb(200, 0, 0, 0))) {
            if (sf != null) g.DrawString(s, f, sh, sr, sf);
            else            g.DrawString(s, f, sh, sr);
        }
        if (sf != null) g.DrawString(s, f, br, r, sf);
        else            g.DrawString(s, f, br, r);
    }

    // Filled-area sparkline.  Semi-transparent fill + full-opacity edge line.
    void DrawSparkline(Graphics g, float[] hist,
                       Rectangle r, Color col, float scale) {
        int n = hist != null ? hist.Length : 0;
        if (n < 2 || r.Width < 2) return;
        float sc = scale > 0f ? scale : 100f;

        var pts = new PointF[n + 2];
        pts[0]     = new PointF(r.Left,  r.Bottom);
        pts[n + 1] = new PointF(r.Right, r.Bottom);
        
        // Reserve 14px at the top so the graph never obscures the label text
        float maxH = Math.Max(1f, r.Height - 14f);
        
        for (int i = 0; i < n; i++) {
            float pct = Math.Min(hist[i] / sc, 1f);
            pts[i + 1] = new PointF(
                r.Left + (float)i / (n - 1) * r.Width,
                r.Bottom - pct * maxH);
        }
        // 45/255 ~= 18% alpha fill -- subtle hint of colour under the text
        using (var fill = new SolidBrush(Color.FromArgb(45, col)))
            g.FillPolygon(fill, pts);
        // Full-brightness edge line for crisp readability
        var line = new PointF[n];
        for (int i = 0; i < n; i++) line[i] = pts[i + 1];
        using (var pen = new Pen(col, 1.2f)) g.DrawLines(pen, line);
    }

    // XMeters-style per-core CPU grid.
    // 24 cores -> 3 rows x 8 cols of vertical bars with a green->yellow->red heat map.
    void DrawCoreGrid(Graphics g, ref int x, int h) {
        int cols  = (_snapshot.CoreCount + OverlayLayout.CpuRows - 1) / OverlayLayout.CpuRows;
        int gridW = cols * (OverlayLayout.CpuBarWidth + OverlayLayout.CpuBarGap) - OverlayLayout.CpuBarGap;
        int secW  = 4 + gridW + 4;

        if (x > 0) g.DrawLine(_divPen, x, 2, x, h - 2);
        int gx = x + 4;

        // "CPU" label left-aligned, total % right-aligned -- matches other sections
        var sfLbl = new StringFormat { Alignment = StringAlignment.Near,
                                       LineAlignment = StringAlignment.Near };
        var sfPct = new StringFormat { Alignment = StringAlignment.Far,
                                       LineAlignment = StringAlignment.Near };
        g.DrawString("CPU", _fLbl, _dimBrush,
            new RectangleF(gx, 1, gridW, 9), sfLbl);
        using (var b = new SolidBrush(_cCpu))
            g.DrawString(string.Format("{0:F0}%", _snapshot.CpuTotal), _fLbl, b,
                new RectangleF(gx, 1, gridW, 9), sfPct);

        int rowsH = h - 10;
        int rowH  = (rowsH - (OverlayLayout.CpuRows - 1) * 2) / OverlayLayout.CpuRows;

        for (int row = 0; row < OverlayLayout.CpuRows; row++) {
            int yt = 10 + row * (rowH + 2);
            for (int col = 0; col < cols; col++) {
                int idx = row * cols + col;
                if (idx >= _snapshot.CoreCount) break;

                float pct = Math.Min(_snapshot.CpuCores[idx] / 100f, 1f);
                int bx = gx + col * (OverlayLayout.CpuBarWidth + OverlayLayout.CpuBarGap);
                int bh = Math.Max(1, (int)(pct * rowH));
                int by = yt + (rowH - bh); // bars grow upward from bottom of row

                g.FillRectangle(_coreBgBrush, bx, yt, OverlayLayout.CpuBarWidth, rowH);
                using (var br = new SolidBrush(OverlayFormatting.HeatColor(pct)))
                    g.FillRectangle(br, bx, by, OverlayLayout.CpuBarWidth, bh);
            }
        }
        x += secW;
    }
}

} // namespace TaskMon
