using System;
using System.Text;
using System.Text.RegularExpressions;

namespace TaskMon {

// =============================================================================
// Settings -- JSON-backed, thoroughly commented for manual editing
// =============================================================================
public class Settings {
    // -- Which panels appear in the overlay -----------------------------------
    public bool   ShowNetUp      = true;   // upload speed sparkline
    public bool   ShowNetDown    = true;   // download speed sparkline
    public bool   ShowCpu        = true;   // CPU utilisation panel
    // "Aggregate" = one sparkline for overall CPU%.
    // "PerCore"   = XMeters-style grid: one vertical bar per logical core.
    public string CpuMode        = "Aggregate";
    public bool   ShowGpuUtil    = true;   // NVIDIA GPU utilisation % (requires nvml.dll)
    public bool   ShowGpuTemp    = true;   // NVIDIA GPU temperature degC (requires nvml.dll)
    public bool   ShowMemory     = true;   // system memory usage %

    // -- Network adapter ------------------------------------------------------
    // "auto" picks the adapter with current traffic.
    // Paste an exact adapter name (from Device Manager) to pin to one adapter.
    public string NetworkAdapter = "auto";

    // -- Behaviour ------------------------------------------------------------
    // Milliseconds between metric samples + redraws. 500 / 1000 / 2000.
    public int    UpdateIntervalMs = 1000;
    // 1.0 = fully opaque; 0.5 = 50% transparent (lets you see icons beneath).
    public double Opacity          = 1.0;
    // Launch task-stats automatically when Windows starts.
    public bool   RunOnStartup     = true;

    // -- Sparkline colours (HTML hex) -----------------------------------------
    public string ColorNetUp    = "#FF4040"; // upload   -- red
    public string ColorNetDown  = "#00FF88"; // download -- green
    public string ColorCpu      = "#FFB300";
    public string ColorGpu      = "#FF6B35"; // GPU utilisation
    public string ColorGpuTemp  = "#FFDD44"; // GPU temperature (distinct from util)
    public string ColorMemory   = "#CC44FF";

    public static Settings Load() {
        return new FileSettingsStore().Load();
    }

    public void Save() {
        new FileSettingsStore().Save(this);
    }

    public Settings Clone() { return (Settings)MemberwiseClone(); }

    public void CopyTo(Settings dest) {
        dest.ShowNetUp = ShowNetUp;
        dest.ShowNetDown = ShowNetDown;
        dest.ShowCpu = ShowCpu;
        dest.CpuMode = CpuMode;
        dest.ShowGpuUtil = ShowGpuUtil;
        dest.ShowGpuTemp = ShowGpuTemp;
        dest.ShowMemory = ShowMemory;
        dest.NetworkAdapter = NetworkAdapter;
        dest.UpdateIntervalMs = UpdateIntervalMs;
        dest.Opacity = Opacity;
        dest.RunOnStartup = RunOnStartup;
        dest.ColorNetUp = ColorNetUp;
        dest.ColorNetDown = ColorNetDown;
        dest.ColorCpu = ColorCpu;
        dest.ColorGpu = ColorGpu;
        dest.ColorGpuTemp = ColorGpuTemp;
        dest.ColorMemory = ColorMemory;
    }

    // Writes a richly commented JSON file so it's easy to hand-edit.
    public string Serialize() {
        var b = new StringBuilder();
        b.AppendLine("{");
        b.AppendLine("  \"_info\": \"task-stats settings -- edit here or use right-click > Settings in the overlay\",");
        b.AppendLine();
        b.AppendLine("  \"_display\": \"which panels appear in the taskbar overlay\",");
        Jb(b, "ShowNetUp",      ShowNetUp);
        Jb(b, "ShowNetDown",    ShowNetDown);
        Jb(b, "ShowCpu",        ShowCpu);
        Js(b, "CpuMode",        CpuMode,
            "Aggregate = one sparkline for overall CPU%  |  PerCore = XMeters-style grid");
        Jb(b, "ShowGpuUtil",    ShowGpuUtil);
        Jb(b, "ShowGpuTemp",    ShowGpuTemp);
        Jb(b, "ShowMemory",     ShowMemory);
        b.AppendLine();
        b.AppendLine("  \"_network\": \"auto picks the busiest adapter; paste exact Device Manager name to pin\",");
        Js(b, "NetworkAdapter", NetworkAdapter);
        b.AppendLine();
        b.AppendLine("  \"_behaviour\": \"\",");
        Ji(b, "UpdateIntervalMs", UpdateIntervalMs,
            "milliseconds between samples: 500 (snappy) | 1000 (recommended) | 2000 (quiet)");
        Jd(b, "Opacity",          Opacity,
            "1.00 = fully opaque  |  0.50 = half transparent  (min 0.30)");
        Jb(b, "RunOnStartup",     RunOnStartup,
            "true = launch automatically when Windows starts");
        b.AppendLine();
        b.AppendLine("  \"_colours\": \"HTML hex colour for each sparkline -- e.g. #FF0000 for red\",");
        Js(b, "ColorNetUp",     ColorNetUp);
        Js(b, "ColorNetDown",   ColorNetDown);
        Js(b, "ColorCpu",       ColorCpu);
        Js(b, "ColorGpu",       ColorGpu);
        Js(b, "ColorGpuTemp",   ColorGpuTemp);
        Js(b, "ColorMemory",    ColorMemory, null, last: true);
        b.AppendLine("}");
        return b.ToString();
    }

    void Jb(StringBuilder b, string k, bool v,   string c=null, bool last=false) {
        b.Append(string.Format("  \"{0}\": {1}", k, v ? "true" : "false"));
        if (!last) b.Append(",");
        if (c != null) b.Append("  // " + c);
        b.AppendLine();
    }
    void Js(StringBuilder b, string k, string v, string c=null, bool last=false) {
        b.Append(string.Format("  \"{0}\": \"{1}\"",
            k, v.Replace("\\","\\\\").Replace("\"","\\\"")));
        if (!last) b.Append(",");
        if (c != null) b.Append("  // " + c);
        b.AppendLine();
    }
    void Ji(StringBuilder b, string k, int v,    string c=null, bool last=false) {
        b.Append(string.Format("  \"{0}\": {1}", k, v));
        if (!last) b.Append(",");
        if (c != null) b.Append("  // " + c);
        b.AppendLine();
    }
    void Jd(StringBuilder b, string k, double v, string c=null, bool last=false) {
        b.Append(string.Format(
            System.Globalization.CultureInfo.InvariantCulture,
            "  \"{0}\": {1:0.00}", k, v));
        if (!last) b.Append(",");
        if (c != null) b.Append("  // " + c);
        b.AppendLine();
    }

    // Minimal JSON parser -- handles the flat key/value structure we write above.
    // Ignores "_comment" keys and lines starting with "//".
    public static Settings Parse(string json) {
        var s = new Settings();
        foreach (Match m in Regex.Matches(json,
            "\"(\\w+)\"\\s*:\\s*(?:\"([^\"]*)\"|\\b(true|false)\\b|([\\d.]+))")) {
            string k=m.Groups[1].Value, sv=m.Groups[2].Value,
                   bv=m.Groups[3].Value, nv=m.Groups[4].Value;
            switch (k) {
                case "ShowNetUp":        s.ShowNetUp        = bv=="true"; break;
                case "ShowNetDown":      s.ShowNetDown      = bv=="true"; break;
                case "ShowCpu":          s.ShowCpu          = bv=="true"; break;
                case "CpuMode":          s.CpuMode          = sv;         break;
                case "ShowGpuUtil":      s.ShowGpuUtil      = bv=="true"; break;
                case "ShowGpuTemp":      s.ShowGpuTemp      = bv=="true"; break;
                case "ShowMemory":       s.ShowMemory       = bv=="true"; break;
                case "NetworkAdapter":   s.NetworkAdapter   = sv;         break;
                case "UpdateIntervalMs": int.TryParse(nv, out s.UpdateIntervalMs); break;
                case "Opacity":
                    double.TryParse(nv,
                        System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture,
                        out s.Opacity); break;
                case "RunOnStartup": s.RunOnStartup = bv == "true"; break;
                case "ColorNetUp":    s.ColorNetUp    = sv; break;
                case "ColorNetDown":  s.ColorNetDown  = sv; break;
                case "ColorCpu":      s.ColorCpu      = sv; break;
                case "ColorGpu":      s.ColorGpu      = sv; break;
                case "ColorGpuTemp":  s.ColorGpuTemp  = sv; break;
                case "ColorMemory":   s.ColorMemory   = sv; break;
            }
        }
        return s;
    }
}

} // namespace TaskMon
