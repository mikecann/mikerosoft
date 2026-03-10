using System;
using System.Drawing;

namespace TaskMon {

public static class OverlayFormatting {
    public static Color HeatColor(float p) {
        p = Math.Max(0f, Math.Min(1f, p));
        if (p <= 0.5f) {
            int r = (int)(p * 2f * 255f);
            return Color.FromArgb(r, 200, 0);
        }

        int g = (int)((1f - (p - 0.5f) * 2f) * 200f);
        return Color.FromArgb(255, g, 0);
    }

    public static string SpeedStr(float bps) {
        if (bps >= 1073741824f) return string.Format("{0:F1}GB/s", bps / 1073741824f);
        if (bps >= 1048576f)    return string.Format("{0:F1}MB/s", bps / 1048576f);
        if (bps >= 1024f)       return string.Format("{0:F0}KB/s", bps / 1024f);
        return string.Format("{0:F0}B/s", bps);
    }

    public static double ClampOpacity(double v) {
        return Math.Max(0.1, Math.Min(1.0, v));
    }

    public static Color ParseHex(string hex, string fallback) {
        try { return ColorTranslator.FromHtml(hex); }
        catch { return ColorTranslator.FromHtml(fallback); }
    }

    public static Color SafeColor(string hex) {
        try { return ColorTranslator.FromHtml(hex); }
        catch { return Color.DimGray; }
    }

    public static float Max(float[] values) {
        float max = 0f;
        if (values == null) return max;
        for (int i = 0; i < values.Length; i++) if (values[i] > max) max = values[i];
        return max;
    }
}

} // namespace TaskMon
