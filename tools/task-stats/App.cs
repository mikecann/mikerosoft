using System;
using System.Drawing;
using System.Windows.Forms;

namespace TaskMon {

// =============================================================================
// DarkRenderer -- makes the right-click context menu match the dark overlay theme
// =============================================================================
class DarkRenderer : ToolStripProfessionalRenderer {
    class DarkCT : ProfessionalColorTable {
        public override Color MenuItemSelected            { get { return Color.FromArgb(0x45, 0x45, 0x55); } }
        public override Color MenuItemBorder              { get { return Color.FromArgb(0x55, 0x55, 0x66); } }
        public override Color MenuBorder                  { get { return Color.FromArgb(0x44, 0x44, 0x44); } }
        public override Color ToolStripDropDownBackground { get { return Color.FromArgb(0x2D, 0x2D, 0x2D); } }
        public override Color ImageMarginGradientBegin    { get { return Color.FromArgb(0x2D, 0x2D, 0x2D); } }
        public override Color ImageMarginGradientMiddle   { get { return Color.FromArgb(0x2D, 0x2D, 0x2D); } }
        public override Color ImageMarginGradientEnd      { get { return Color.FromArgb(0x2D, 0x2D, 0x2D); } }
        public override Color SeparatorDark               { get { return Color.FromArgb(0x44, 0x44, 0x44); } }
        public override Color SeparatorLight              { get { return Color.FromArgb(0x44, 0x44, 0x44); } }
    }
    public DarkRenderer() : base(new DarkCT()) {}
}

// =============================================================================
// App -- entry point called by task-stats.ps1
// =============================================================================
public static class App {
    // scriptDir is passed from task-stats.ps1 ($PSScriptRoot) so we can find task-stats.vbs.
    public static void Run(string scriptDir = null) {
        Run(scriptDir, new FileSettingsStore(), new RegistryStartupRegistration(), null);
    }

    internal static void Run(string scriptDir, ISettingsStore settingsStore,
                             IStartupRegistration startupRegistration,
                             IMetricsSource metricsSource) {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        var s = settingsStore != null ? settingsStore.Load() : Settings.Load();
        // Apply startup registration on every launch so it stays in sync with the setting.
        if (scriptDir != null)
            ApplyStartup(s.RunOnStartup, scriptDir, startupRegistration);
        using (var f = new OverlayForm(s, scriptDir, metricsSource)) {
            f.Show();
            Application.Run(f);
        }
    }

    // Adds or removes the HKCU Run entry.
    // cmd = wscript.exe "<path to taskmon.vbs>"
    internal static void ApplyStartup(bool enable, string scriptDir) {
        ApplyStartup(enable, scriptDir, new RegistryStartupRegistration());
    }

    internal static void ApplyStartup(bool enable, string scriptDir, IStartupRegistration startupRegistration) {
        try { if (startupRegistration != null) startupRegistration.Apply(enable, scriptDir); }
        catch { }
    }
}

} // namespace TaskMon
