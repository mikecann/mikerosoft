using System;

namespace TaskMon {

public enum Section { None, NetUp, NetDown, Cpu, Gpu, Mem }

public static class OverlayLayout {
    public const int StandardSectionWidth = 70;
    public const int CpuBarWidth = 9;
    public const int CpuBarGap = 2;
    public const int CpuRows = 3;

    public static int CalculateWidth(Settings s, int coreCount) {
        int w = 0;
        if (s.ShowNetUp)   w += StandardSectionWidth;
        if (s.ShowNetDown) w += StandardSectionWidth;
        if (s.ShowCpu)     w += CpuSectionWidth(s, coreCount);
        if (s.ShowGpuUtil || s.ShowGpuTemp) w += StandardSectionWidth;
        if (s.ShowMemory)  w += StandardSectionWidth;
        return Math.Max(60, w);
    }

    public static int CpuSectionWidth(Settings s, int coreCount) {
        if (s.CpuMode == "PerCore") {
            int cols = (Math.Max(coreCount, 1) + CpuRows - 1) / CpuRows;
            return 4 + cols * (CpuBarWidth + CpuBarGap) - CpuBarGap + 4;
        }
        return StandardSectionWidth;
    }

    public static Section HitTest(Settings s, int coreCount, int mouseX) {
        int x = 0;
        if (s.ShowNetUp) {
            if (mouseX < x + StandardSectionWidth) return Section.NetUp;
            x += StandardSectionWidth;
        }
        if (s.ShowNetDown) {
            if (mouseX < x + StandardSectionWidth) return Section.NetDown;
            x += StandardSectionWidth;
        }
        if (s.ShowCpu) {
            int cpuWidth = CpuSectionWidth(s, coreCount);
            if (mouseX < x + cpuWidth) return Section.Cpu;
            x += cpuWidth;
        }
        if (s.ShowGpuUtil || s.ShowGpuTemp) {
            if (mouseX < x + StandardSectionWidth) return Section.Gpu;
            x += StandardSectionWidth;
        }
        if (s.ShowMemory && mouseX < x + StandardSectionWidth) return Section.Mem;
        return Section.None;
    }
}

} // namespace TaskMon
