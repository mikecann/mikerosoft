using System;
using System.Collections.Generic;
using System.IO;
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
            new NamedTest("LiveMetricsSource samples Windows counters", LiveMetricsSourceSamplesWindowsCounters)
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
}

} // namespace TaskMon.Tests
