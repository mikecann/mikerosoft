using System;
using System.Diagnostics;
using System.Linq;

namespace TaskMon {

// =============================================================================
// CircularBuffer -- fixed-size ring buffer for sparkline history
// =============================================================================
public sealed class CircularBuffer {
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
// MetricsSnapshot -- immutable-enough capture of current values + graph history
// =============================================================================
public sealed class MetricsSnapshot {
    public float CpuTotal;
    public float[] CpuCores;
    public float MemPct;
    public float NetUpBps;
    public float NetDnBps;
    public float GpuUtil;
    public uint GpuTempC;
    public bool NvmlOk;
    public float[] HCpu;
    public float[] HMem;
    public float[] HNetUp;
    public float[] HNetDn;
    public float[] HGpu;
    public float[][] HCores;

    public int CoreCount { get { return CpuCores != null ? CpuCores.Length : 0; } }
}

// =============================================================================
// LiveMetricsSource -- PerformanceCounter + NVML backed source
// =============================================================================
public sealed class LiveMetricsSource : IMetricsSource {
    sealed class NetworkCounters : IDisposable {
        public readonly PerformanceCounter Up;
        public readonly PerformanceCounter Down;

        public NetworkCounters(string instanceName) {
            Up = new PerformanceCounter("Network Interface", "Bytes Sent/sec", instanceName, true);
            Down = new PerformanceCounter("Network Interface", "Bytes Received/sec", instanceName, true);
        }

        public void Dispose() {
            if (Up != null) Up.Dispose();
            if (Down != null) Down.Dispose();
        }
    }

    // -- Current values (written by timer tick, read by paint -- same UI thread)
    float   _cpuTotal;
    float[] _cpuCores;   // one entry per logical core
    float   _memPct;
    float   _netUpBps;
    float   _netDnBps;
    float   _gpuUtil;
    uint    _gpuTempC;
    bool    _nvmlOk;

    // -- Sparkline history buffers ---------------------------------------------
    readonly CircularBuffer  _hCpu, _hMem, _hNetUp, _hNetDn, _hGpu;
    readonly CircularBuffer[] _hCores; // one per logical core
    readonly int _coreCount;

    PerformanceCounter    _pcCpuTotal;
    PerformanceCounter[]  _pcCores;
    PerformanceCounter    _pcMem;
    NetworkCounters[]     _netCounters;
    ulong  _memTotalMb;
    IntPtr _nvDev;
    bool   _disposed;

    public int CoreCount { get { return _coreCount; } }

    public LiveMetricsSource(string netAdapter) {
        _coreCount = Environment.ProcessorCount;
        _cpuCores  = new float[_coreCount];
        _hCpu   = new CircularBuffer(60);
        _hMem   = new CircularBuffer(60);
        _hNetUp = new CircularBuffer(60);
        _hNetDn = new CircularBuffer(60);
        _hGpu   = new CircularBuffer(60);
        _hCores = new CircularBuffer[_coreCount];
        for (int i = 0; i < _coreCount; i++) _hCores[i] = new CircularBuffer(60);

        // -- CPU --------------------------------------------------------------
        // _Total gives the aggregate across all cores; individual instances give
        // per-core values used in the XMeters-style grid.
        _pcCpuTotal = new PerformanceCounter("Processor", "% Processor Time", "_Total", true);
        _pcCores    = new PerformanceCounter[_coreCount];
        for (int i = 0; i < _coreCount; i++)
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
                _nvmlOk = true;
        } catch { _nvmlOk = false; }

        // Rate-based PerformanceCounters always return 0 on the very first call.
        // Call NextValue() once now so the first real Sample() shows correct values.
        _pcCpuTotal.NextValue();
        if (_pcCores != null) foreach (var p in _pcCores) p.NextValue();
        _pcMem.NextValue();
        if (_netCounters != null) {
            for (int i = 0; i < _netCounters.Length; i++) {
                _netCounters[i].Up.NextValue();
                _netCounters[i].Down.NextValue();
            }
        }
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
            _netCounters = pool.Select(n => new NetworkCounters(n)).ToArray();
            for (int i = 0; i < _netCounters.Length; i++) {
                _netCounters[i].Up.NextValue();
                _netCounters[i].Down.NextValue();
            }
        } catch { /* silently skip network if counters unavailable */ }
    }

    // Called once per timer tick on the UI thread.  All counter reads take microseconds.
    public MetricsSnapshot Sample() {
        // CPU
        _cpuTotal = Clamp100(_pcCpuTotal.NextValue());
        _hCpu.Push(_cpuTotal);
        for (int i = 0; i < _coreCount; i++) {
            _cpuCores[i] = Clamp100(_pcCores[i].NextValue());
            _hCores[i].Push(_cpuCores[i]);
        }

        // Memory: percent used = (total - available) / total * 100
        float avail = _pcMem.NextValue();
        _memPct = _memTotalMb > 0
            ? Clamp100((float)((_memTotalMb - avail) / _memTotalMb * 100.0))
            : 0f;
        _hMem.Push(_memPct);

        if (_netCounters != null && _netCounters.Length > 0) {
            float bestUp = 0f;
            float bestDn = 0f;
            float bestTotal = -1f;
            for (int i = 0; i < _netCounters.Length; i++) {
                float up = Math.Max(0f, _netCounters[i].Up.NextValue());
                float dn = Math.Max(0f, _netCounters[i].Down.NextValue());
                float total = up + dn;
                if (total > bestTotal) {
                    bestTotal = total;
                    bestUp = up;
                    bestDn = dn;
                }
            }
            _netUpBps = bestUp;
            _netDnBps = bestDn;
        }
        _hNetUp.Push(_netUpBps);
        _hNetDn.Push(_netDnBps);

        // GPU -- microsecond NVML calls, safe on UI thread
        if (_nvmlOk) {
            try {
                NvmlUtil u;
                if (Native.NvmlGetUtil(_nvDev, out u) == 0) _gpuUtil = u.gpu;
                uint t;
                if (Native.NvmlGetTemp(_nvDev, 0, out t) == 0) _gpuTempC = t;
            } catch { /* NVML calls failing at runtime -- skip silently */ }
        }
        _hGpu.Push(_gpuUtil);
        return CreateSnapshot();
    }

    static float Clamp100(float v) { return Math.Max(0f, Math.Min(100f, v)); }

    MetricsSnapshot CreateSnapshot() {
        return new MetricsSnapshot {
            CpuTotal = _cpuTotal,
            CpuCores = Copy(_cpuCores),
            MemPct = _memPct,
            NetUpBps = _netUpBps,
            NetDnBps = _netDnBps,
            GpuUtil = _gpuUtil,
            GpuTempC = _gpuTempC,
            NvmlOk = _nvmlOk,
            HCpu = Copy(_hCpu),
            HMem = Copy(_hMem),
            HNetUp = Copy(_hNetUp),
            HNetDn = Copy(_hNetDn),
            HGpu = Copy(_hGpu),
            HCores = Copy(_hCores)
        };
    }

    static float[] Copy(float[] values) {
        var dst = new float[values.Length];
        Array.Copy(values, dst, values.Length);
        return dst;
    }

    static float[] Copy(CircularBuffer buffer) {
        var dst = new float[buffer.Capacity];
        buffer.CopyTo(dst);
        return dst;
    }

    static float[][] Copy(CircularBuffer[] buffers) {
        var rows = new float[buffers.Length][];
        for (int i = 0; i < buffers.Length; i++) rows[i] = Copy(buffers[i]);
        return rows;
    }

    public void Dispose() {
        if (_disposed) return; _disposed = true;
        if (_pcCpuTotal != null) _pcCpuTotal.Dispose();
        if (_pcCores != null) foreach (var p in _pcCores) if (p != null) p.Dispose();
        if (_pcMem   != null) _pcMem.Dispose();
        if (_netCounters != null) foreach (var n in _netCounters) if (n != null) n.Dispose();
        if (_nvmlOk) { try { Native.NvmlShutdown(); } catch { } }
    }
}

} // namespace TaskMon
