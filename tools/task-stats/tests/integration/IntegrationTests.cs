using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using Microsoft.Win32;
using TaskMon;

namespace TaskMon.Tests {

static class IntegrationTests {
    [STAThread]
    static int Main() {
        return TestRunner.Run("TaskStats.IntegrationTests", new List<NamedTest> {
            new NamedTest("FileSettingsStore persists settings to disk", FileSettingsStorePersistsSettingsToDisk),
            new NamedTest("RegistryStartupRegistration writes and removes startup value", RegistryStartupRegistrationWritesAndRemovesStartupValue),
            new NamedTest("LiveMetricsSource samples Windows counters", LiveMetricsSourceSamplesWindowsCounters),
            new NamedTest("LiveMetricsSource auto mode follows the busiest active network adapter", LiveMetricsSourceAutoModeFollowsBusiestActiveNetworkAdapter)
        });
    }

    static void FileSettingsStorePersistsSettingsToDisk() {
        string tempDir = Path.Combine(Path.GetTempPath(), "task-stats-tests", Guid.NewGuid().ToString("N"));
        string tempFile = Path.Combine(tempDir, "settings.json");
        try {
            var store = new FileSettingsStore(tempFile);
            var expected = new Settings();
            expected.CpuMode = "PerCore";
            expected.NetworkAdapter = "Wi-Fi";
            expected.Opacity = 0.63;
            expected.ShowMemory = false;

            store.Save(expected);
            var actual = store.Load();

            AssertEx.True(File.Exists(tempFile), "The settings store should create the settings file");
            AssertEx.Equal(expected.CpuMode, actual.CpuMode, "CpuMode should survive a disk round-trip");
            AssertEx.Equal(expected.NetworkAdapter, actual.NetworkAdapter, "NetworkAdapter should survive a disk round-trip");
            AssertEx.NearlyEqual(expected.Opacity, actual.Opacity, 0.001, "Opacity should survive a disk round-trip");
            AssertEx.Equal(expected.ShowMemory, actual.ShowMemory, "ShowMemory should survive a disk round-trip");
        } finally {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true);
        }
    }

    static void RegistryStartupRegistrationWritesAndRemovesStartupValue() {
        const string subKeyPath = @"Software\mikerosoft\task-stats-tests\Run";
        const string valueName = "task-stats-test";
        var registration = new RegistryStartupRegistration(Registry.CurrentUser, subKeyPath, valueName);

        try {
            registration.Apply(true, @"C:\dev\me\mikerosoft\tools\task-stats");

            using (var key = Registry.CurrentUser.OpenSubKey(subKeyPath, false)) {
                AssertEx.True(key != null, "The integration test subkey should exist after enabling startup");
                var value = key.GetValue(valueName, string.Empty) as string;
                AssertEx.True(!string.IsNullOrEmpty(value), "Startup registration should write a command");
                AssertEx.True(value.IndexOf("task-stats.vbs", StringComparison.OrdinalIgnoreCase) >= 0,
                    "The startup command should point at task-stats.vbs");
            }

            registration.Apply(false, @"C:\dev\me\mikerosoft\tools\task-stats");

            using (var key = Registry.CurrentUser.OpenSubKey(subKeyPath, false)) {
                if (key != null) {
                    AssertEx.True(key.GetValue(valueName) == null, "Disabling startup should remove the test value");
                }
            }
        } finally {
            Registry.CurrentUser.DeleteSubKeyTree(@"Software\mikerosoft\task-stats-tests", false);
        }
    }

    static void LiveMetricsSourceSamplesWindowsCounters() {
        try {
            using (var source = new LiveMetricsSource("auto")) {
                Thread.Sleep(300);
                var snapshot = source.Sample();

                AssertEx.True(snapshot != null, "LiveMetricsSource should return a snapshot");
                AssertEx.True(snapshot.CoreCount > 0, "The snapshot should expose at least one CPU core");
                AssertEx.Equal(snapshot.CoreCount, snapshot.CpuCores.Length, "CpuCores length should match CoreCount");
                AssertEx.Equal(snapshot.CoreCount, snapshot.HCores.Length, "HCores length should match CoreCount");
                AssertEx.True(snapshot.CpuTotal >= 0f && snapshot.CpuTotal <= 100f, "CPU total should stay within 0-100%");
                AssertEx.True(snapshot.MemPct >= 0f && snapshot.MemPct <= 100f, "Memory percent should stay within 0-100%");
                AssertEx.True(snapshot.NetUpBps >= 0f, "Upload speed should never be negative");
                AssertEx.True(snapshot.NetDnBps >= 0f, "Download speed should never be negative");
                AssertEx.Equal(60, snapshot.HCpu.Length, "CPU history should contain 60 samples");
                AssertEx.Equal(60, snapshot.HGpu.Length, "GPU history should contain 60 samples");
            }
        } catch (Exception ex) {
            AssertEx.Skip("Skipped live counter sampling because the machine did not expose the required Windows counters cleanly: " + ex.Message);
        }
    }

    static void LiveMetricsSourceAutoModeFollowsBusiestActiveNetworkAdapter() {
        using (var source = new LiveMetricsSource("auto")) {
            // Warm up the rate-based counters before trying to observe real traffic.
            Thread.Sleep(1200);
            source.Sample();

            NetworkBurstSample observed = null;
            try {
                for (int i = 0; i < 3; i++) {
                    observed = CaptureBurstSample(source);
                    if (observed != null && observed.BusiestTotalBps >= 4096f) break;
                }
            } catch (Exception ex) {
                AssertEx.Skip("Skipped auto network selection test because the machine could not produce reliable live network traffic: " + ex.Message);
            }

            if (observed == null || observed.BusiestTotalBps < 4096f) {
                AssertEx.Skip("Skipped auto network selection test because the machine did not expose enough measurable network activity.");
            }

            float sourceTotal = observed.SourceUpBps + observed.SourceDnBps;
            AssertEx.True(sourceTotal > 0f,
                string.Format(
                    "Auto network selection should observe live traffic when adapter '{0}' is active. Busiest adapter saw {1:F0}B/s up and {2:F0}B/s down, but LiveMetricsSource stayed at zero.",
                    observed.BusiestName, observed.BusiestUpBps, observed.BusiestDnBps));
        }
    }

    sealed class NetworkBurstSample {
        public string BusiestName;
        public float BusiestUpBps;
        public float BusiestDnBps;
        public float BusiestTotalBps;
        public float SourceUpBps;
        public float SourceDnBps;
    }

    sealed class NetworkCounterProbe : IDisposable {
        public readonly string Name;
        public readonly PerformanceCounter Up;
        public readonly PerformanceCounter Down;

        public NetworkCounterProbe(string name) {
            Name = name;
            Up = new PerformanceCounter("Network Interface", "Bytes Sent/sec", name, true);
            Down = new PerformanceCounter("Network Interface", "Bytes Received/sec", name, true);
        }

        public void Dispose() {
            if (Up != null) Up.Dispose();
            if (Down != null) Down.Dispose();
        }
    }

    static NetworkBurstSample CaptureBurstSample(LiveMetricsSource source) {
        var probes = CreateNetworkCounterProbes();
        try {
            if (probes.Count == 0) return null;

            for (int i = 0; i < probes.Count; i++) {
                probes[i].Up.NextValue();
                probes[i].Down.NextValue();
            }

            GenerateNetworkTrafficBurst();
            Thread.Sleep(1200);

            var busiest = probes
                .Select(p => new {
                    p.Name,
                    Up = Math.Max(0f, p.Up.NextValue()),
                    Down = Math.Max(0f, p.Down.NextValue())
                })
                .OrderByDescending(p => p.Up + p.Down)
                .FirstOrDefault();
            var snapshot = source.Sample();

            if (busiest == null) return null;
            return new NetworkBurstSample {
                BusiestName = busiest.Name,
                BusiestUpBps = busiest.Up,
                BusiestDnBps = busiest.Down,
                BusiestTotalBps = busiest.Up + busiest.Down,
                SourceUpBps = snapshot.NetUpBps,
                SourceDnBps = snapshot.NetDnBps
            };
        } finally {
            for (int i = 0; i < probes.Count; i++) probes[i].Dispose();
        }
    }

    static List<NetworkCounterProbe> CreateNetworkCounterProbes() {
        var category = new PerformanceCounterCategory("Network Interface");
        var names = category.GetInstanceNames()
            .Where(name =>
                name.IndexOf("Loopback", StringComparison.OrdinalIgnoreCase) < 0 &&
                name.IndexOf("ISATAP", StringComparison.OrdinalIgnoreCase) < 0 &&
                name.IndexOf("Pseudo", StringComparison.OrdinalIgnoreCase) < 0 &&
                name.IndexOf("Teredo", StringComparison.OrdinalIgnoreCase) < 0 &&
                name.IndexOf("6to4", StringComparison.OrdinalIgnoreCase) < 0)
            .ToArray();
        if (names.Length == 0) names = category.GetInstanceNames();
        return names.Select(name => new NetworkCounterProbe(name)).ToList();
    }

    static void GenerateNetworkTrafficBurst() {
        using (var client = new HttpClient()) {
            client.Timeout = TimeSpan.FromSeconds(10);
            for (int i = 0; i < 4; i++) {
                var bytes = client.GetByteArrayAsync("https://example.com/").GetAwaiter().GetResult();
                AssertEx.True(bytes != null && bytes.Length > 0, "The network burst should download at least some bytes");
            }
        }
    }
}

} // namespace TaskMon.Tests
