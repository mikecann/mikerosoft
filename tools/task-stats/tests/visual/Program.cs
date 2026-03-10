using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using TaskMon;

namespace TaskMon.VisualHarness {

sealed class FixedMetricsSource : IMetricsSource {
    readonly MetricsSnapshot _snapshot;

    public FixedMetricsSource(MetricsSnapshot snapshot) {
        _snapshot = snapshot;
    }

    public int CoreCount { get { return _snapshot.CoreCount; } }

    public MetricsSnapshot Sample() {
        return Clone(_snapshot);
    }

    public void Dispose() {}

    static MetricsSnapshot Clone(MetricsSnapshot src) {
        return new MetricsSnapshot {
            CpuTotal = src.CpuTotal,
            CpuCores = Copy(src.CpuCores),
            MemPct = src.MemPct,
            NetUpBps = src.NetUpBps,
            NetDnBps = src.NetDnBps,
            GpuUtil = src.GpuUtil,
            GpuTempC = src.GpuTempC,
            NvmlOk = src.NvmlOk,
            HCpu = Copy(src.HCpu),
            HMem = Copy(src.HMem),
            HNetUp = Copy(src.HNetUp),
            HNetDn = Copy(src.HNetDn),
            HGpu = Copy(src.HGpu),
            HCores = Copy(src.HCores)
        };
    }

    static float[] Copy(float[] src) {
        var dst = new float[src.Length];
        Array.Copy(src, dst, src.Length);
        return dst;
    }

    static float[][] Copy(float[][] src) {
        var dst = new float[src.Length][];
        for (int i = 0; i < src.Length; i++) dst[i] = Copy(src[i]);
        return dst;
    }
}

sealed class NullProcessLauncher : IProcessLauncher {
    public void Launch(string command) {}
}

static class Program {
    [STAThread]
    static int Main(string[] args) {
        string outDir = args.Length > 0
            ? args[0]
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                           "task-stats-tests", "artifacts");

        Directory.CreateDirectory(outDir);

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        CaptureScenario(
            "aggregate",
            BuildAggregateSettings(),
            BuildAggregateSnapshot(),
            outDir,
            "Shows UP, DL, CPU, GPU, and MEM sections. CPU must be a single aggregate CPU panel with one numeric percentage like 42%, not a per-core grid.");

        CaptureScenario(
            "percore",
            BuildPerCoreSettings(),
            BuildPerCoreSnapshot(),
            outDir,
            "Shows upload, download, GPU, memory, and a per-core CPU bar grid.");

        return 0;
    }

    static void CaptureScenario(string scenarioName, Settings settings, MetricsSnapshot snapshot,
                                string outDir, string expectation) {
        string screenshotPath = Path.Combine(outDir, scenarioName + ".png");
        string manifestPath = Path.Combine(outDir, scenarioName + ".json");
        int width = OverlayLayout.CalculateWidth(settings, snapshot.CoreCount);
        var options = new OverlayFormOptions {
            AttachToTaskbar = false,
            InstallMouseHook = false,
            StartTimer = false,
            TransparentBackground = false,
            CreateNotifyIcon = false,
            FixedBounds = new Rectangle(80, 80, width, 42)
        };

        using (var form = new OverlayForm(settings, null, new FixedMetricsSource(snapshot), options, new NullProcessLauncher())) {
            form.Show();
            form.BringToFront();
            form.RefreshNow();
            Application.DoEvents();
            Thread.Sleep(250);
            SaveScreenshot(form, screenshotPath);
            form.Close();
        }

        File.WriteAllText(manifestPath, BuildManifestJson(scenarioName, screenshotPath, expectation));
    }

    static void SaveScreenshot(Form form, string path) {
        using (var rendered = new Bitmap(form.Width, form.Height)) {
            form.DrawToBitmap(rendered, new Rectangle(0, 0, form.Width, form.Height));
            rendered.Save(path, ImageFormat.Png);
        }

        string screenPath = Path.Combine(
            Path.GetDirectoryName(path),
            Path.GetFileNameWithoutExtension(path) + "-screen.png");

        try {
            using (var bmp = new Bitmap(form.Width, form.Height))
            using (var g = Graphics.FromImage(bmp)) {
                g.CopyFromScreen(form.Left, form.Top, 0, 0, form.Size);
                bmp.Save(screenPath, ImageFormat.Png);
            }
        } catch { }
    }

    static string BuildManifestJson(string scenarioName, string screenshotPath, string expectation) {
        var b = new StringBuilder();
        b.AppendLine("{");
        b.AppendLine("  \"scenario\": \"" + Escape(scenarioName) + "\",");
        b.AppendLine("  \"image\": \"" + Escape(screenshotPath) + "\",");
        b.AppendLine("  \"expectation\": \"" + Escape(expectation) + "\"");
        b.AppendLine("}");
        return b.ToString();
    }

    static string Escape(string value) {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    static Settings BuildAggregateSettings() {
        return new Settings {
            ShowNetUp = true,
            ShowNetDown = true,
            ShowCpu = true,
            CpuMode = "Aggregate",
            ShowGpuUtil = true,
            ShowGpuTemp = true,
            ShowMemory = true,
            Opacity = 1.0,
            ColorNetUp = "#FF4040",
            ColorNetDown = "#00FF88",
            ColorCpu = "#FFB300",
            ColorGpu = "#FF6B35",
            ColorGpuTemp = "#FFDD44",
            ColorMemory = "#CC44FF"
        };
    }

    static Settings BuildPerCoreSettings() {
        return new Settings {
            ShowNetUp = true,
            ShowNetDown = true,
            ShowCpu = true,
            CpuMode = "PerCore",
            ShowGpuUtil = true,
            ShowGpuTemp = false,
            ShowMemory = true,
            Opacity = 1.0,
            ColorNetUp = "#FF4040",
            ColorNetDown = "#00FF88",
            ColorCpu = "#FFB300",
            ColorGpu = "#FF6B35",
            ColorGpuTemp = "#FFDD44",
            ColorMemory = "#CC44FF"
        };
    }

    static MetricsSnapshot BuildAggregateSnapshot() {
        var history = BuildHistory(60, 0.15f, 0.95f);
        return new MetricsSnapshot {
            CpuTotal = 42f,
            CpuCores = BuildCpuCores(24, 0.25f),
            MemPct = 68f,
            NetUpBps = 3.5f * 1048576f,
            NetDnBps = 18.2f * 1048576f,
            GpuUtil = 61f,
            GpuTempC = 57,
            NvmlOk = true,
            HCpu = BuildHistory(60, 18f, 55f),
            HMem = BuildHistory(60, 55f, 72f),
            HNetUp = history,
            HNetDn = BuildHistory(60, 2.5f * 1048576f, 20f * 1048576f),
            HGpu = BuildHistory(60, 25f, 79f),
            HCores = BuildCoreHistory(24)
        };
    }

    static MetricsSnapshot BuildPerCoreSnapshot() {
        return new MetricsSnapshot {
            CpuTotal = 71f,
            CpuCores = BuildCpuCores(24, 0.55f),
            MemPct = 64f,
            NetUpBps = 640f * 1024f,
            NetDnBps = 9.2f * 1048576f,
            GpuUtil = 83f,
            GpuTempC = 63,
            NvmlOk = true,
            HCpu = BuildHistory(60, 20f, 88f),
            HMem = BuildHistory(60, 58f, 70f),
            HNetUp = BuildHistory(60, 200f * 1024f, 900f * 1024f),
            HNetDn = BuildHistory(60, 1.5f * 1048576f, 11f * 1048576f),
            HGpu = BuildHistory(60, 35f, 91f),
            HCores = BuildCoreHistory(24)
        };
    }

    static float[] BuildHistory(int length, float min, float max) {
        var values = new float[length];
        for (int i = 0; i < length; i++) {
            float t = (float)i / (length - 1);
            values[i] = min + (max - min) * (0.5f + 0.5f * (float)Math.Sin(t * Math.PI * 2.0));
        }
        return values;
    }

    static float[] BuildCpuCores(int count, float phase) {
        var values = new float[count];
        for (int i = 0; i < count; i++) {
            double angle = phase + i * 0.38;
            values[i] = (float)(20.0 + ((Math.Sin(angle) + 1.0) * 35.0));
        }
        return values;
    }

    static float[][] BuildCoreHistory(int count) {
        var rows = new float[count][];
        for (int i = 0; i < count; i++) {
            rows[i] = BuildHistory(60, 10f + i, 70f + i % 10);
        }
        return rows;
    }
}

} // namespace TaskMon.VisualHarness
