import Foundation

/// Finds the keymap: the Premiere defaults shipped in the app's resource
/// bundle, with the user's `~/Library/Application Support/Tandem/keymap.json`
/// merged on top.
enum KeymapStore {
    static let bundleName = "Tandem_TandemApp.bundle"
    static let defaultFile = "Keymaps/premiere.json"

    static var userKeymapURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tandem/keymap.json")
    }

    /// Where the shipped keymap can be: inside the app bundle's resources,
    /// next to the executable (SwiftPM builds), or the build folder.
    static func defaultKeymapURL() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(bundleName)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(bundleName))
        }
        for candidate in candidates {
            // Debug builds make a flat bundle; release builds make a real
            // one with Contents/Resources. Bundle finds the file in either.
            if let bundle = Bundle(url: candidate),
               let url = bundle.url(forResource: "premiere", withExtension: "json", subdirectory: "Keymaps") {
                return url
            }
            let flat = candidate.appendingPathComponent(defaultFile)
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }

    /// Loads the keymap, reporting (not throwing) problems so a typo in the
    /// user file never leaves the app without keys.
    static func load(report: (String) -> Void) -> Keymap {
        var keymap = Keymap.empty
        if let url = defaultKeymapURL() {
            do {
                keymap = try Keymap.load(Data(contentsOf: url))
            } catch {
                report("the default keymap didn't load: \(error.localizedDescription)")
            }
        } else {
            report("the default keymap is missing from the app bundle")
        }
        let user = userKeymapURL
        if let data = try? Data(contentsOf: user) {
            do {
                let parsed = try Keymap.parse(data)
                keymap = keymap.merged(with: parsed.keymap, removing: parsed.removals)
            } catch {
                report("\(user.path): \(error.localizedDescription)")
            }
        }
        return keymap
    }

    /// A starter user keymap that explains itself.
    static func writeTemplate(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let names = EditorCommand.allCases.map(\.rawValue).joined(separator: ", ")
        let template = """
        {
          "name": "Mine",
          "about": "Bindings here replace Tandem's Premiere defaults. Use null to remove one. Commands: \(names)",
          "bindings": {
          }
        }

        """
        try Data(template.utf8).write(to: url)
    }
}
