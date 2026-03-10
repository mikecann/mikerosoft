using System;
using System.IO;

namespace TaskMon {

public interface ISettingsStore {
    string Path { get; }
    Settings Load();
    void Save(Settings settings);
}

public sealed class FileSettingsStore : ISettingsStore {
    public static readonly string DefaultPath = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "task-stats", "settings.json");

    readonly string _path;

    public FileSettingsStore(string path = null) {
        _path = string.IsNullOrEmpty(path) ? DefaultPath : path;
    }

    public string Path { get { return _path; } }

    public Settings Load() {
        try {
            if (File.Exists(_path)) return Settings.Parse(File.ReadAllText(_path));
        } catch { }
        return new Settings();
    }

    public void Save(Settings settings) {
        try {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(_path));
            File.WriteAllText(_path, settings.Serialize());
        } catch { }
    }
}

} // namespace TaskMon
