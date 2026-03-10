using System;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace TaskMon {

// =============================================================================
// SettingsForm -- tabbed dialog: Display | Colours | Behaviour
// =============================================================================
public class SettingsForm : Form {
    Settings    _d;    // working draft -- only pushed to live settings on Apply
    OverlayForm _host;

    // Display tab controls
    CheckBox    _cbUp, _cbDn, _cbCpu, _cbGU, _cbGT, _cbMem;
    RadioButton _rbAgg, _rbPC;
    ComboBox    _cboNet;
    // Colours tab controls (swatch buttons)
    Button _bUp, _bDn, _bCpu, _bGpu, _bGpuTemp, _bMem;
    // Behaviour tab controls
    RadioButton _rb500, _rb1k, _rb2k;
    TrackBar    _tbOp;
    Label       _lblOp;
    CheckBox    _cbStartup;

    // Light-mode palette -- avoids fighting WinForms dark-theme rendering in
    // title bars, tab strips, and ComboBox dropdowns.
    static readonly Color BG      = Color.FromArgb(0xF3, 0xF3, 0xF3); // page bg
    static readonly Color BG2     = Color.White;                        // footer / alternate
    static readonly Color ACCENT  = Color.FromArgb(0x00, 0x5B, 0xB5); // section headers
    static readonly Color SEP     = Color.FromArgb(0xCC, 0xCC, 0xCC);
    static readonly Color FG      = Color.FromArgb(0x1A, 0x1A, 0x1A);
    static readonly Color FG_DIM  = Color.FromArgb(0x66, 0x66, 0x66);

    public SettingsForm(Settings s, OverlayForm host) {
        _d    = s.Clone();
        _host = host;

        Text            = "task-stats \u2014 Settings";
        Size            = new Size(460, 460);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox     = MinimizeBox = false;
        StartPosition   = FormStartPosition.CenterScreen;
        Font            = new Font("Segoe UI", 9f);
        Icon            = OverlayForm.MakeAppIcon();

        var tabs = new TabControl { Dock = DockStyle.Fill };
        var imgList = new ImageList { ImageSize = new Size(16, 16), ColorDepth = ColorDepth.Depth32Bit };
        imgList.Images.Add(OverlayForm.LoadIcon("monitor") ?? new Bitmap(16, 16));
        imgList.Images.Add(OverlayForm.LoadIcon("palette") ?? new Bitmap(16, 16));
        imgList.Images.Add(OverlayForm.LoadIcon("cog")     ?? new Bitmap(16, 16));
        tabs.ImageList = imgList;
        var pgDisplay  = TabDisplay();  pgDisplay.ImageIndex  = 0;
        var pgColours  = TabColours();  pgColours.ImageIndex  = 1;
        var pgBehaviour = TabBehaviour(); pgBehaviour.ImageIndex = 2;
        tabs.TabPages.Add(pgDisplay);
        tabs.TabPages.Add(pgColours);
        tabs.TabPages.Add(pgBehaviour);

        var foot = new Panel {
            Dock = DockStyle.Bottom, Height = 50,
            BackColor = Color.FromArgb(0xE8, 0xE8, 0xE8)
        };
        foot.Paint += (o, e) =>
            e.Graphics.DrawLine(new Pen(SEP), 0, 0, foot.Width, 0);
        // Primary action: Windows accent blue
        var bOk = new Button {
            Text = "Apply \u0026 Close", Location = new Point(222, 10), Size = new Size(116, 30),
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(0x00, 0x78, 0xD4), ForeColor = Color.White,
            Font = new Font("Segoe UI", 9f, FontStyle.Bold)
        };
        bOk.FlatAppearance.BorderColor = Color.FromArgb(0x00, 0x5A, 0xA8);
        var bCan = new Button {
            Text = "Cancel", Location = new Point(348, 10), Size = new Size(90, 30),
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(0xE0, 0xE0, 0xE0), ForeColor = FG
        };
        bCan.FlatAppearance.BorderColor = SEP;
        bOk.Click  += (o, e) => { Apply(); Close(); };
        bCan.Click += (o, e) => Close();
        foot.Controls.Add(bOk); foot.Controls.Add(bCan);

        Controls.Add(tabs);
        Controls.Add(foot);
    }

    // -- Tab helpers -----------------------------------------------------------
    TabPage TP(string t) {
        return new TabPage(t) { BackColor = BG };
    }

    // Section header: 16x16 silk icon + blue bold label + thin separator line.
    void SecHead(Control p, string iconName, string text, ref int y) {
        var img = OverlayForm.LoadIcon(iconName);
        if (img != null) {
            p.Controls.Add(new PictureBox {
                Image = img, SizeMode = PictureBoxSizeMode.Normal,
                Location = new Point(8, y + 1), Size = new Size(16, 16),
                BackColor = Color.Transparent
            });
        }
        p.Controls.Add(new Label {
            Text      = text,
            Location  = new Point(img != null ? 28 : 8, y),
            Size      = new Size(img != null ? 400 : 420, 18),
            ForeColor = ACCENT,
            Font      = new Font("Segoe UI", 8.5f, FontStyle.Bold)
        });
        p.Controls.Add(new Panel {
            Location = new Point(8, y + 19), Size = new Size(420, 1), BackColor = SEP
        });
        y += 26;
    }

    // Checkbox row with a 10x10 colored indicator dot on the left.
    void MetricRow(TabPage p, ref CheckBox cb, string text, Color dot, bool chk, ref int y) {
        p.Controls.Add(new Panel { Location = new Point(10, y + 5), Size = new Size(10, 10), BackColor = dot });
        cb = new CheckBox {
            Text = text, Location = new Point(26, y), Size = new Size(400, 20),
            Checked = chk
        };
        p.Controls.Add(cb);
        y += 22;
    }

    RadioButton RB(string t, int x, int y, bool v) {
        return new RadioButton {
            Text = t, Location = new Point(x, y), Size = new Size(400, 19), Checked = v
        };
    }

    // -- Display tab ----------------------------------------------------------
    TabPage TabDisplay() {
        var p = TP("Display"); int y = 10;

        SecHead(p, "chart_bar", "Metrics to show", ref y);
        MetricRow(p, ref _cbUp,  "Upload speed  (NET \u2191)",                    OverlayFormatting.SafeColor(_d.ColorNetUp),   _d.ShowNetUp,   ref y);
        MetricRow(p, ref _cbDn,  "Download speed  (NET \u2193)",                  OverlayFormatting.SafeColor(_d.ColorNetDown), _d.ShowNetDown, ref y);
        MetricRow(p, ref _cbCpu, "CPU utilisation",                               OverlayFormatting.SafeColor(_d.ColorCpu),     _d.ShowCpu,     ref y);
        MetricRow(p, ref _cbGU,  "GPU utilisation %  (NVIDIA RTX 5070 Ti)",      OverlayFormatting.SafeColor(_d.ColorGpu),     _d.ShowGpuUtil, ref y);
        MetricRow(p, ref _cbGT,  "GPU temperature \u00B0C  (NVIDIA RTX 5070 Ti)", OverlayFormatting.SafeColor(_d.ColorGpuTemp), _d.ShowGpuTemp, ref y);
        MetricRow(p, ref _cbMem, "Memory usage %",                               OverlayFormatting.SafeColor(_d.ColorMemory),  _d.ShowMemory,  ref y);
        y += 6;

        SecHead(p, "computer", "CPU display mode", ref y);
        _rbAgg = RB("Aggregate \u2014 single sparkline for overall CPU%",             18, y, _d.CpuMode != "PerCore"); y += 21;
        _rbPC  = RB("Per-core bars \u2014 XMeters-style grid  (24 bars, 3\u00D78)",  18, y, _d.CpuMode == "PerCore"); y += 10;
        p.Controls.Add(_rbAgg); p.Controls.Add(_rbPC);
        y += 16;

        SecHead(p, "connect", "Network adapter", ref y);
        _cboNet = new ComboBox {
            Location = new Point(18, y), Size = new Size(410, 22),
            DropDownStyle = ComboBoxStyle.DropDownList
        };
        try {
            _cboNet.Items.Add("auto");
            foreach (var n in new PerformanceCounterCategory("Network Interface")
                .GetInstanceNames()
                .Where(n2 => !n2.Contains("Loopback") && !n2.Contains("ISATAP"))
                .OrderBy(n2 => n2))
                _cboNet.Items.Add(n);
        } catch { _cboNet.Items.Add("auto"); }
        _cboNet.SelectedItem = _d.NetworkAdapter;
        if (_cboNet.SelectedItem == null) _cboNet.SelectedIndex = 0;
        p.Controls.Add(_cboNet);
        return p;
    }

    // -- Colours tab ----------------------------------------------------------
    TabPage TabColours() {
        var p = TP("Colours"); int y = 10;
        int dummy = y; SecHead(p, "palette", "Sparkline colours  \u2014  click swatch to change", ref dummy); y = dummy;
        ColRow(p, "Upload  (NET \u2191)",    _d.ColorNetUp,   ref _bUp,      ref y);
        ColRow(p, "Download  (NET \u2193)",  _d.ColorNetDown, ref _bDn,      ref y);
        ColRow(p, "CPU",                     _d.ColorCpu,     ref _bCpu,     ref y);
        ColRow(p, "GPU utilisation",         _d.ColorGpu,     ref _bGpu,     ref y);
        ColRow(p, "GPU temperature",         _d.ColorGpuTemp, ref _bGpuTemp, ref y);
        ColRow(p, "Memory",                  _d.ColorMemory,  ref _bMem,     ref y);
        p.Controls.Add(new Label {
            Text      = "Changes take effect on Apply \u0026 Close.",
            Location  = new Point(14, y + 4), Size = new Size(390, 18),
            ForeColor = FG_DIM, Font = new Font("Segoe UI", 8f)
        });
        return p;
    }

    void ColRow(TabPage p, string lbl, string hex, ref Button btn, ref int y) {
        var dot = new Panel { Location = new Point(12, y + 9), Size = new Size(10, 10), BackColor = OverlayFormatting.SafeColor(hex) };
        p.Controls.Add(dot);
        p.Controls.Add(new Label { Text = lbl, Location = new Point(28, y + 6), Size = new Size(130, 20) });
        var b = new Button {
            Location = new Point(164, y + 2), Size = new Size(56, 26),
            FlatStyle = FlatStyle.Flat, Text = "", BackColor = OverlayFormatting.SafeColor(hex)
        };
        b.FlatAppearance.BorderColor = Color.FromArgb(0xAA, 0xAA, 0xAA);
        b.Click += (o, e) => {
            using (var dlg = new ColorDialog { Color = b.BackColor, FullOpen = true })
                if (dlg.ShowDialog() == DialogResult.OK) b.BackColor = dlg.Color;
        };
        var hexLbl = new Label {
            Location  = new Point(228, y + 8), Size = new Size(90, 16),
            ForeColor = FG_DIM, Font = new Font("Consolas", 8.5f)
        };
        b.BackColorChanged += (o, e) => {
            dot.BackColor = b.BackColor;
            hexLbl.Text   = ColorTranslator.ToHtml(b.BackColor).ToUpper();
        };
        hexLbl.Text = hex.ToUpper();
        p.Controls.Add(b); p.Controls.Add(hexLbl);
        btn = b; y += 32;
    }

    // -- Behaviour tab --------------------------------------------------------
    TabPage TabBehaviour() {
        var p = TP("Behaviour"); int y = 10;
        SecHead(p, "clock", "Update interval", ref y);
        _rb500 = RB("500 ms \u2014 snappier, slightly more CPU",  18, y, _d.UpdateIntervalMs == 500);  y += 22;
        _rb1k  = RB("1 second \u2014 recommended",                18, y, _d.UpdateIntervalMs == 1000); y += 22;
        _rb2k  = RB("2 seconds \u2014 very quiet",                18, y, _d.UpdateIntervalMs == 2000); y += 10;
        if (!_rb500.Checked && !_rb1k.Checked && !_rb2k.Checked) _rb1k.Checked = true;
        p.Controls.Add(_rb500); p.Controls.Add(_rb1k); p.Controls.Add(_rb2k);
        y += 16;

        SecHead(p, "contrast", "Window opacity", ref y);
        _tbOp = new TrackBar {
            Location = new Point(18, y), Size = new Size(400, 30),
            Minimum = 30, Maximum = 100, TickFrequency = 10,
            Value = (int)(_d.Opacity * 100)
        };
        y += 32;
        _lblOp = new Label {
            Location = new Point(18, y), Size = new Size(400, 18), ForeColor = Color.Silver
        };
        UpdateOpLbl();
        _tbOp.ValueChanged += (o, e) => UpdateOpLbl();
        p.Controls.Add(_tbOp); p.Controls.Add(_lblOp);
        y += 28;

        y += 6;
        SecHead(p, "bullet_go", "Startup", ref y);
        _cbStartup = new CheckBox {
            Text     = "Launch task-stats automatically when Windows starts",
            Location = new Point(18, y), Size = new Size(400, 20),
            Checked  = _d.RunOnStartup
        };
        p.Controls.Add(_cbStartup);
        y += 26;

        p.Controls.Add(new Label {
            Text      = "Note: changing the network adapter takes effect on next restart.",
            Location  = new Point(18, y), Size = new Size(400, 18),
            ForeColor = FG_DIM, Font = new Font("Segoe UI", 8f)
        });
        return p;
    }

    void UpdateOpLbl() {
        string note = _tbOp.Value == 100 ? " (fully opaque)"
                    : _tbOp.Value <= 50  ? " (very transparent)" : "";
        _lblOp.Text = string.Format("Opacity: {0}%{1}", _tbOp.Value, note);
    }

    // -- Apply -----------------------------------------------------------------
    // Reads all controls into _draft, copies to live settings, saves JSON,
    // then updates the overlay immediately.
    void Apply() {
        _d.ShowNetUp        = _cbUp.Checked;
        _d.ShowNetDown      = _cbDn.Checked;
        _d.ShowCpu          = _cbCpu.Checked;
        _d.CpuMode          = _rbPC.Checked ? "PerCore" : "Aggregate";
        _d.ShowGpuUtil      = _cbGU.Checked;
        _d.ShowGpuTemp      = _cbGT.Checked;
        _d.ShowMemory       = _cbMem.Checked;
        _d.NetworkAdapter   = (_cboNet.SelectedItem ?? "auto").ToString();
        _d.ColorNetUp       = ColorTranslator.ToHtml(_bUp.BackColor);
        _d.ColorNetDown     = ColorTranslator.ToHtml(_bDn.BackColor);
        _d.ColorCpu         = ColorTranslator.ToHtml(_bCpu.BackColor);
        _d.ColorGpu         = ColorTranslator.ToHtml(_bGpu.BackColor);
        _d.ColorGpuTemp     = ColorTranslator.ToHtml(_bGpuTemp.BackColor);
        _d.ColorMemory      = ColorTranslator.ToHtml(_bMem.BackColor);
        _d.UpdateIntervalMs = _rb500.Checked ? 500 : _rb2k.Checked ? 2000 : 1000;
        _d.Opacity          = _tbOp.Value / 100.0;
        _d.RunOnStartup     = _cbStartup.Checked;

        _d.CopyTo(_host.S);
        _d.Save();
        // Apply startup registry entry immediately
        if (_host._scriptDir != null)
            App.ApplyStartup(_d.RunOnStartup, _host._scriptDir);

        // Live-update the overlay without a restart
        _host.RefreshColors();
        _host._timer.Interval = Math.Max(250, _d.UpdateIntervalMs);
        _host.DoLayout(); // repositions and calls UpdateLayer()
    }

}

} // namespace TaskMon
