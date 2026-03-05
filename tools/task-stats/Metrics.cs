using System;
using System.Diagnostics;
using System.Linq;

namespace TaskMon {

// =============================================================================
// CircularBuffer -- fixed-size ring buffer for sparkline history
// =============================================================================
class CircularBuffer {
    readonly float[] _d;
    int _head;
    public readonly int Capacity;
    public CircularBuffer(int n) { _d = new float[n]; Capacity = n; }
    // Append a new sample, overwriting the oldest.
    public void Push(float v) { _d[_head] = v; _head = (_head + 1) % Capacity; }
    // Fill dst[] with samples in oldest-first order (left = oldest, right = newest).
    public void CopyTo(float[] dst) {
        for (int i = 0; i < Capacity; i++) dst[i] = _d[(_head + i) % Capacity];
    }
    public float Max() {
        float m = 0f;
        for (int i = 0; i < Capacity; i++) if (_d[i] > m) m = _d[i];
        return m;
    }
}

// =============================================================================
// Metrics -- all PerformanceCounter + NVML handles; call Sample() each tick
// =============================================================================
class Metrics : IDisposable {
    // -- Current values (written by timer tick, read by paint -- same UI thread)
    public float   CpuTotal;
    public float[] CpuCores;   // one entry per logical core
    public float   MemPct;
    public float   NetUpBps;
    public float   NetDnBps;
    public float   GpuUtil;
    public uint    GpuTempC;
    public bool    NvmlOk;

    // -- Sparkline history buffers ---------------------------------------------
    public readonly CircularBuffer  HCpu, HMem, HNetUp, HNetDn, HGpu;
    public readonly CircularBuffer[] HCores; // one per logical core
    public readonly int CoreCount;

    PerformanceCounter    _pcCpuTotal;
    PerformanceCounter[]  _pcCores;
    PerformanceCounter    _pcMem;
    PerformanceCounter    _pcNetUp, _pcNetDn;
    ulong  _memTotalMb;
    IntPtr _nvDev;
    bool   _disposed;

    public Metrics(string netAdapter) {
        CoreCount = Environment.ProcessorCount;
        CpuCores  = new float[CoreCount];
        HCpu   = new CircularBuffer(60);
        HMem   = new CircularBuffer(60);
        HNetUp = new CircularBuffer(60);
        HNetDn = new CircularBuffer(60);
        HGpu   = new CircularBuffer(60);
        HCores = new CircularBuffer[CoreCount];
        for (int i = 0; i < CoreCount; i++) HCores[i] = new CircularBuffer(60);

        // -- CPU --------------------------------------------------------------
        // _Total gives the aggregate across all cores; individual instances give
        // per-core values used in the XMeters-style grid.
        _pcCpuTotal = new PerformanceCounter("Processor", "% Processor Time", "_Total", true);
        _pcCores    = new PerformanceCounter[CoreCount];
        for (int i = 0; i < CoreCount; i++)
            _pcCores[i] = new PerformanceCounter("Processor", "% Processor Time", i.ToString(), true);

        // -- Memory -----------------------------------------------------------
        // Available MBytes is polled each tick; total is read once via Win32.
        _pcMem = new PerformanceCounter("Memory", "Available MBytes", true);
        var ms = new Native.MEMORYSTATUSEX { dwLength = 64 };
        Native.GlobalMemoryStatusEx(ref ms);
        _memTotalMb = ms.ullTotalPhys / (1024 * 1024);

        // -- Network ----------------------------------------------------------
        InitNet(netAdapter);

        // -- GPU via NVML -----------------------------------------------------
        // NVML gives us GPU util% and temp directly -- no subprocess needed.
        // Falls back gracefully if nvml.dll is missing or GPU index 0 isn't NVIDIA.
        try {
            if (Native.NvmlInit() == 0 && Native.NvmlGetDevice(0, out _nvDev) == 0)
                NvmlOk = true;
        } catch { NvmlOk = false; }

        // Rate-based PerformanceCounters always return 0 on the very first call.
        // Call NextValue() once now so the first real Sample() shows correct values.
        _pcCpuTotal.NextValue();
        if (_pcCores != null) foreach (var p in _pcCores) p.NextValue();
        _pcMem.NextValue();
        if (_pcNetUp != null) { _pcNetUp.NextValue(); _pcNetDn.NextValue(); }
    }

    void InitNet(string adapter) {
        try {
            var cat  = new PerformanceCounterCategory("Network Interface");
            var all  = cat.GetInstanceNames();
            // Filter out virtual/tunnel adapters for auto-selection.
            var pool = (adapter == "auto")
                ? all.Where(n =>
                    !n.Contains("Loopback") && !n.Contains("ISATAP") &&
                    !n.Contains("Pseudo")   && !n.Contains("Teredo") &&
                    !n.Contains("6to4")).ToArray()
                : all.Where(n =>
                    n.IndexOf(adapter, StringComparison.OrdinalIgnoreCase) >= 0).ToArray();
            if (pool.Length == 0) pool = all;
            string pick = pool[0];
            _pcNetUp = new PerformanceCounter("Network Interface", "Bytes Sent/sec",     pick, true);
            _pcNetDn = new PerformanceCounter("Network Interface", "Bytes Received/sec", pick, true);
            _pcNetUp.NextValue(); _pcNetDn.NextValue();
        } catch { /* silently skip network if counters unavailable */ }
    }

    // Called once per timer tick on the UI thread.  All counter reads take microseconds.
    public void Sample() {
        // CPU
        CpuTotal = Clamp100(_pcCpuTotal.NextValue());
        HCpu.Push(CpuTotal);
        for (int i = 0; i < CoreCount; i++) {
            CpuCores[i] = Clamp100(_pcCores[i].NextValue());
            HCores[i].Push(CpuCores[i]);
        }

        // Memory: percent used = (total - available) / total * 100
        float avail = _pcMem.NextValue();
        MemPct = _memTotalMb > 0
            ? Clamp100((float)((_memTotalMb - avail) / _memTotalMb * 100.0))
            : 0f;
        HMem.Push(MemPct);

        if (_pcNetUp != null) {
            NetUpBps = Math.Max(0f, _pcNetUp.NextValue());
            NetDnBps = Math.Max(0f, _pcNetDn.NextValue());
        }
        HNetUp.Push(NetUpBps);
        HNetDn.Push(NetDnBps);

        // GPU -- microsecond NVML calls, safe on UI thread
        if (NvmlOk) {
            try {
                NvmlUtil u;
                if (Native.NvmlGetUtil(_nvDev, out u) == 0) GpuUtil = u.gpu;
                uint t;
                if (Native.NvmlGetTemp(_nvDev, 0, out t) == 0) GpuTempC = t;
            } catch { /* NVML calls failing at runtime -- skip silently */ }
        }
        HGpu.Push(GpuUtil);
    }

    static float Clamp100(float v) { return Math.Max(0f, Math.Min(100f, v)); }

    public void Dispose() {
        if (_disposed) return; _disposed = true;
        if (_pcCpuTotal != null) _pcCpuTotal.Dispose();
        if (_pcCores != null) foreach (var p in _pcCores) if (p != null) p.Dispose();
        if (_pcMem   != null) _pcMem.Dispose();
        if (_pcNetUp != null) _pcNetUp.Dispose();
        if (_pcNetDn != null) _pcNetDn.Dispose();
        if (NvmlOk) { try { Native.NvmlShutdown(); } catch { } }
    }
}

} // namespace TaskMon
