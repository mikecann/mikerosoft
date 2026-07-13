import Foundation

enum TaskbarPaths {
    static var toolDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var installedExecutable: URL {
        if let override = ProcessInfo.processInfo.environment["TASKBAR_APP_EXECUTABLE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Mikerosoft Taskbar.app/Contents/MacOS/taskbar-swift")
    }
}

enum StartupManager {
    private static let label = "com.mikerosoft.taskbar.login"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try install()
            } else {
                try uninstall()
            }
        } catch {
            log("failed to update start-at-login setting: \(error)")
        }
    }

    private static func install() throws {
        let executable = TaskbarPaths.installedExecutable.path
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mikerosoft-taskbar-login.log")
            .path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let existing = try? String(contentsOf: plistURL, encoding: .utf8), existing == plist {
            return
        }
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    private static func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
