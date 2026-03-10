using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace TaskMon {

public sealed class ProcessInsightRow {
    public readonly string Name;
    public readonly int ProcessId;
    public readonly string Value;

    public ProcessInsightRow(string name, int processId, string value) {
        Name = string.IsNullOrWhiteSpace(name) ? "unknown" : name;
        ProcessId = processId;
        Value = value ?? string.Empty;
    }
}

public sealed class SectionContextInfo {
    public readonly string Title;
    public readonly string Description;
    public readonly ProcessInsightRow[] Rows;
    public readonly string ActionText;
    public readonly string LaunchCommand;

    public bool LaunchesExternalTool { get { return !string.IsNullOrWhiteSpace(LaunchCommand); } }

    public SectionContextInfo(string title, string description, ProcessInsightRow[] rows,
                              string actionText = null, string launchCommand = null) {
        Title = title ?? string.Empty;
        Description = description ?? string.Empty;
        Rows = rows ?? new ProcessInsightRow[0];
        ActionText = actionText ?? string.Empty;
        LaunchCommand = launchCommand ?? string.Empty;
    }
}

public interface ISectionContextProvider : IDisposable {
    void Refresh();
    SectionContextInfo GetContextInfo(Section section);
}

public static class SectionContextInfoFactory {
    public static SectionContextInfo BuildProcessSummary(Section section, ProcessInsightRow[] rows) {
        return new SectionContextInfo(TitleFor(section), DescriptionFor(section), rows ?? new ProcessInsightRow[0]);
    }

    public static SectionContextInfo BuildFallback(Section section) {
        if (section == Section.NetUp) {
            return new SectionContextInfo(
                "Top uploaders",
                "Per-process network rankings need ETW tracing. Use Resource Monitor for the live network view.",
                new ProcessInsightRow[0],
                "Open Resource Monitor",
                "resmon.exe");
        }

        if (section == Section.NetDown) {
            return new SectionContextInfo(
                "Top downloaders",
                "Per-process network rankings need ETW tracing. Use Resource Monitor for the live network view.",
                new ProcessInsightRow[0],
                "Open Resource Monitor",
                "resmon.exe");
        }

        if (section == Section.Gpu) {
            return new SectionContextInfo(
                "Top GPU processes",
                "Per-process GPU rankings are not wired into task-stats yet. Use Task Manager for the live GPU view.",
                new ProcessInsightRow[0],
                "Open Task Manager",
                "taskmgr.exe");
        }

        return new SectionContextInfo(TitleFor(section), DescriptionFor(section), new ProcessInsightRow[0]);
    }

    static string TitleFor(Section section) {
        switch (section) {
            case Section.NetUp: return "Top uploaders";
            case Section.NetDown: return "Top downloaders";
            case Section.Cpu: return "Top CPU processes";
            case Section.Gpu: return "Top GPU processes";
            case Section.Mem: return "Top memory processes";
            default: return "Section details";
        }
    }

    static string DescriptionFor(Section section) {
        switch (section) {
            case Section.Cpu: return "Live CPU usage by process.";
            case Section.Mem: return "Current memory usage by process.";
            default: return string.Empty;
        }
    }
}

public sealed class LiveSectionContextProvider : ISectionContextProvider {
    sealed class RankedProcess {
        public string Name;
        public int ProcessId;
        public double SortValue;
        public string DisplayValue;
    }

    Dictionary<int, TimeSpan> _lastCpuTimes = new Dictionary<int, TimeSpan>();
    DateTime _lastCpuSampleUtc = DateTime.MinValue;
    ProcessInsightRow[] _cpuRows = new ProcessInsightRow[0];
    ProcessInsightRow[] _memRows = new ProcessInsightRow[0];

    public void Refresh() {
        var now = DateTime.UtcNow;
        var nextCpuTimes = new Dictionary<int, TimeSpan>();
        var cpu = new List<RankedProcess>();
        var mem = new List<RankedProcess>();
        double elapsedMs = _lastCpuSampleUtc == DateTime.MinValue ? 0.0 : (now - _lastCpuSampleUtc).TotalMilliseconds;
        int cpuCount = Math.Max(1, Environment.ProcessorCount);

        var processes = Process.GetProcesses();
        for (int i = 0; i < processes.Length; i++) {
            var process = processes[i];
            try {
                string name = SafeProcessName(process);
                int pid = process.Id;
                long workingSet = process.WorkingSet64;
                mem.Add(new RankedProcess {
                    Name = name,
                    ProcessId = pid,
                    SortValue = workingSet,
                    DisplayValue = FormatBytes(workingSet)
                });

                TimeSpan totalCpu = process.TotalProcessorTime;
                nextCpuTimes[pid] = totalCpu;
                if (elapsedMs > 0.0) {
                    TimeSpan previousCpu;
                    if (_lastCpuTimes.TryGetValue(pid, out previousCpu)) {
                        double cpuPct = (totalCpu - previousCpu).TotalMilliseconds / (elapsedMs * cpuCount) * 100.0;
                        if (cpuPct > 0.05) {
                            cpu.Add(new RankedProcess {
                                Name = name,
                                ProcessId = pid,
                                SortValue = cpuPct,
                                DisplayValue = string.Format("{0:F1}%", cpuPct)
                            });
                        }
                    }
                }
            } catch {
            } finally {
                process.Dispose();
            }
        }

        _cpuRows = cpu.OrderByDescending(p => p.SortValue).Take(5)
            .Select(p => new ProcessInsightRow(p.Name, p.ProcessId, p.DisplayValue)).ToArray();
        _memRows = mem.OrderByDescending(p => p.SortValue).Take(5)
            .Select(p => new ProcessInsightRow(p.Name, p.ProcessId, p.DisplayValue)).ToArray();
        _lastCpuTimes = nextCpuTimes;
        _lastCpuSampleUtc = now;
    }

    public SectionContextInfo GetContextInfo(Section section) {
        if (section == Section.Cpu) {
            if (_cpuRows.Length == 0) {
                return new SectionContextInfo(
                    "Top CPU processes",
                    "Collecting CPU samples. Right-click again in a moment.",
                    new ProcessInsightRow[0],
                    "Open Task Manager",
                    "taskmgr.exe");
            }

            return new SectionContextInfo(
                "Top CPU processes",
                "Live CPU usage by process.",
                _cpuRows,
                "Open Task Manager",
                "taskmgr.exe");
        }

        if (section == Section.Mem) {
            return new SectionContextInfo(
                "Top memory processes",
                "Current memory usage by process.",
                _memRows,
                "Open Task Manager",
                "taskmgr.exe");
        }

        return SectionContextInfoFactory.BuildFallback(section);
    }

    public void Dispose() {
    }

    static string SafeProcessName(Process process) {
        try {
            return process.ProcessName;
        } catch {
            return "unknown";
        }
    }

    static string FormatBytes(long bytes) {
        if (bytes >= 1024L * 1024L * 1024L) return string.Format("{0:F1} GB", bytes / (1024d * 1024d * 1024d));
        if (bytes >= 1024L * 1024L) return string.Format("{0:F1} MB", bytes / (1024d * 1024d));
        if (bytes >= 1024L) return string.Format("{0:F1} KB", bytes / 1024d);
        return string.Format("{0} B", bytes);
    }
}

} // namespace TaskMon
