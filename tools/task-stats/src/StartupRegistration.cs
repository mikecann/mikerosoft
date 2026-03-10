using System;
using System.IO;
using Microsoft.Win32;

namespace TaskMon {

public interface IStartupRegistration {
    void Apply(bool enable, string scriptDir);
}

public sealed class RegistryStartupRegistration : IStartupRegistration {
    public const string DefaultRegistryKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string DefaultValueName = "task-stats";

    readonly RegistryKey _root;
    readonly string _registryKeyPath;
    readonly string _valueName;

    public RegistryStartupRegistration()
        : this(Registry.CurrentUser, DefaultRegistryKey, DefaultValueName) {
    }

    public RegistryStartupRegistration(RegistryKey root, string registryKeyPath, string valueName) {
        _root = root;
        _registryKeyPath = registryKeyPath;
        _valueName = valueName;
    }

    public void Apply(bool enable, string scriptDir) {
        try {
            using (var key = _root.CreateSubKey(_registryKeyPath)) {
                if (key == null) return;
                if (enable) key.SetValue(_valueName, BuildCommand(scriptDir));
                else key.DeleteValue(_valueName, false);
            }
        } catch { }
    }

    public string BuildCommand(string scriptDir) {
        var vbs = Path.Combine(scriptDir ?? string.Empty, "task-stats.vbs");
        return string.Format("wscript.exe \"{0}\"", vbs);
    }
}

} // namespace TaskMon
