using System;
using System.Drawing;
using System.Diagnostics;

namespace TaskMon {

public interface IMetricsSource : IDisposable {
    int CoreCount { get; }
    MetricsSnapshot Sample();
}

public interface IProcessLauncher {
    void Launch(string command);
}

public sealed class ProcessLauncher : IProcessLauncher {
    public void Launch(string command) {
        try { Process.Start(command); } catch { }
    }
}

public sealed class OverlayFormOptions {
    public bool AttachToTaskbar      = true;
    public bool InstallMouseHook     = true;
    public bool StartTimer           = true;
    public bool TransparentBackground = true;
    public bool CreateNotifyIcon     = true;
    public Rectangle? FixedBounds;
}

} // namespace TaskMon
