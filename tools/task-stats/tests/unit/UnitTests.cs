using System;
using System.Collections.Generic;
using System.Drawing;
using TaskMon;

namespace TaskMon.Tests {

static class UnitTests {
    [STAThread]
    static int Main() {
        return TestRunner.Run("TaskStats.UnitTests", new List<NamedTest> {
            new NamedTest("CircularBuffer keeps oldest-first order after wrap", CircularBufferKeepsOldestFirstOrderAfterWrap),
            new NamedTest("CircularBuffer max reports highest sample", CircularBufferMaxReportsHighestSample),
            new NamedTest("Settings serialize and parse round-trip", SettingsSerializeAndParseRoundTrip),
            new NamedTest("OverlayLayout calculates aggregate width", OverlayLayoutCalculatesAggregateWidth),
            new NamedTest("OverlayLayout calculates per-core CPU width", OverlayLayoutCalculatesPerCoreCpuWidth),
            new NamedTest("OverlayLayout hit-testing follows enabled sections", OverlayLayoutHitTestingFollowsEnabledSections),
            new NamedTest("OverlayFormatting speed strings are readable", OverlayFormattingSpeedStringsAreReadable),
            new NamedTest("OverlayFormatting heat colors match endpoints", OverlayFormattingHeatColorsMatchEndpoints)
        });
    }

    static void CircularBufferKeepsOldestFirstOrderAfterWrap() {
        var buffer = new CircularBuffer(4);
        buffer.Push(1f);
        buffer.Push(2f);
        buffer.Push(3f);
        buffer.Push(4f);
        buffer.Push(5f);

        var actual = new float[4];
        buffer.CopyTo(actual);

        AssertEx.SequenceEqual(new[] { 2f, 3f, 4f, 5f }, actual, "Wrapped buffer should expose oldest-to-newest order");
    }

    static void CircularBufferMaxReportsHighestSample() {
        var buffer = new CircularBuffer(5);
        buffer.Push(4f);
        buffer.Push(12f);
        buffer.Push(3f);

        AssertEx.Equal(12f, buffer.Max(), "Max should return the highest pushed sample");
    }

    static void SettingsSerializeAndParseRoundTrip() {
        var expected = new Settings();
        expected.ShowNetUp = false;
        expected.ShowNetDown = true;
        expected.ShowCpu = true;
        expected.CpuMode = "PerCore";
        expected.ShowGpuUtil = false;
        expected.ShowGpuTemp = true;
        expected.ShowMemory = false;
        expected.NetworkAdapter = "Ethernet 9";
        expected.UpdateIntervalMs = 500;
        expected.Opacity = 0.45;
        expected.RunOnStartup = false;
        expected.ColorNetUp = "#112233";
        expected.ColorNetDown = "#223344";
        expected.ColorCpu = "#334455";
        expected.ColorGpu = "#445566";
        expected.ColorGpuTemp = "#556677";
        expected.ColorMemory = "#667788";

        var actual = Settings.Parse(expected.Serialize());

        AssertEx.Equal(expected.ShowNetUp, actual.ShowNetUp, "ShowNetUp should round-trip");
        AssertEx.Equal(expected.ShowNetDown, actual.ShowNetDown, "ShowNetDown should round-trip");
        AssertEx.Equal(expected.ShowCpu, actual.ShowCpu, "ShowCpu should round-trip");
        AssertEx.Equal(expected.CpuMode, actual.CpuMode, "CpuMode should round-trip");
        AssertEx.Equal(expected.ShowGpuUtil, actual.ShowGpuUtil, "ShowGpuUtil should round-trip");
        AssertEx.Equal(expected.ShowGpuTemp, actual.ShowGpuTemp, "ShowGpuTemp should round-trip");
        AssertEx.Equal(expected.ShowMemory, actual.ShowMemory, "ShowMemory should round-trip");
        AssertEx.Equal(expected.NetworkAdapter, actual.NetworkAdapter, "NetworkAdapter should round-trip");
        AssertEx.Equal(expected.UpdateIntervalMs, actual.UpdateIntervalMs, "UpdateIntervalMs should round-trip");
        AssertEx.NearlyEqual(expected.Opacity, actual.Opacity, 0.001, "Opacity should round-trip");
        AssertEx.Equal(expected.RunOnStartup, actual.RunOnStartup, "RunOnStartup should round-trip");
        AssertEx.Equal(expected.ColorMemory, actual.ColorMemory, "ColorMemory should round-trip");
    }

    static void OverlayLayoutCalculatesAggregateWidth() {
        var settings = new Settings();
        settings.CpuMode = "Aggregate";

        var width = OverlayLayout.CalculateWidth(settings, 24);

        AssertEx.Equal(350, width, "All five visible sections should use the standard width in aggregate mode");
    }

    static void OverlayLayoutCalculatesPerCoreCpuWidth() {
        var settings = new Settings();
        settings.CpuMode = "PerCore";

        var cpuWidth = OverlayLayout.CpuSectionWidth(settings, 24);

        AssertEx.Equal(94, cpuWidth, "24 logical cores should render as 8 per-core columns");
    }

    static void OverlayLayoutHitTestingFollowsEnabledSections() {
        var settings = new Settings();
        settings.ShowNetUp = true;
        settings.ShowNetDown = false;
        settings.ShowCpu = true;
        settings.CpuMode = "PerCore";
        settings.ShowGpuUtil = true;
        settings.ShowGpuTemp = true;
        settings.ShowMemory = false;

        AssertEx.Equal(Section.NetUp, OverlayLayout.HitTest(settings, 24, 10), "The first section should be upload");
        AssertEx.Equal(Section.Cpu, OverlayLayout.HitTest(settings, 24, 80), "The per-core CPU section should start after upload");
        AssertEx.Equal(Section.Gpu, OverlayLayout.HitTest(settings, 24, 170), "GPU should follow the per-core CPU section");
        AssertEx.Equal(Section.None, OverlayLayout.HitTest(settings, 24, 260), "Coordinates beyond the visible sections should return None");
    }

    static void OverlayFormattingSpeedStringsAreReadable() {
        AssertEx.Equal("512B/s", OverlayFormatting.SpeedStr(512f), "Bytes should stay in B/s");
        AssertEx.Equal("2KB/s", OverlayFormatting.SpeedStr(2048f), "Kilobytes should round to whole KB/s");
        AssertEx.Equal("2.0MB/s", OverlayFormatting.SpeedStr(2f * 1048576f), "Megabytes should format with one decimal place");
    }

    static void OverlayFormattingHeatColorsMatchEndpoints() {
        AssertEx.ColorEqual(Color.FromArgb(0, 200, 0), OverlayFormatting.HeatColor(0f), "0% should be green");
        AssertEx.ColorEqual(Color.FromArgb(255, 200, 0), OverlayFormatting.HeatColor(0.5f), "50% should be yellow");
        AssertEx.ColorEqual(Color.FromArgb(255, 0, 0), OverlayFormatting.HeatColor(1f), "100% should be red");
    }
}

} // namespace TaskMon.Tests
