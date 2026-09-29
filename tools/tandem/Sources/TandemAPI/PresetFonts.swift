import Foundation
import TandemAssets
import TandemCore
import TandemMedia
import TandemRender

/// Gets a font from the asset library into a project's `assets/font/`.
public protocol FontInstalling: Sendable {
    /// Downloads `assetID` (`fontsource:tilt-warp`) if the library doesn't
    /// have it yet, copies it into the project and registers it for this
    /// process. Returns the copies, relative to the project folder.
    func install(_ assetID: String, in folder: ProjectFolder, projectID: String, projectFile: URL) async throws -> [String]
}

/// The per-user asset library, the one `tandem assets` uses, opened the
/// first time a font is needed. `$TANDEM_ASSETS_ROOT` and
/// `$TANDEM_ASSETS_OFFLINE` move it and keep it offline, as they do for
/// `tandem assets`.
public final class LibraryFontInstaller: FontInstalling, @unchecked Sendable {
    public static let shared = LibraryFontInstaller()

    private let environment: [String: String]
    private let lock = NSLock()
    private var opened: AssetService?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    private func assets() throws -> AssetService {
        try lock.withLock {
            if let opened { return opened }
            let service = try AssetService.standard(environment: environment)
            opened = service
            return service
        }
    }

    public func install(_ assetID: String, in folder: ProjectFolder, projectID: String, projectFile: URL) async throws -> [String] {
        let assets = try assets()
        _ = try await assets.fetched(assetID)
        do {
            return try await assets.library.use(assetID, in: folder, projectID: projectID, projectFile: projectFile).files
        } catch {
            throw ServiceError.wrap(error)
        }
    }
}

/// A font a built-in preset needed, now in the project.
public struct InstalledFont: Codable, Equatable, Sendable {
    public var name: String
    public var presetID: String
    public var assetID: String
    /// The copies in the project, relative to its folder.
    public var files: [String]
}

/// Fonts the built-in title presets need that don't come with macOS (the
/// caption preset's Tilt Warp), installed from the asset library's
/// Fontsource provider the first time a project uses them, so captions
/// don't quietly fall back to SF Pro.
public enum PresetFonts {
    public struct Outcome: Sendable {
        public var installed: [InstalledFont] = []
        /// Why a font couldn't be installed, one line each.
        public var failures: [String] = []
    }

    static let downloads = Downloads()

    /// Installs the preset fonts that the project's titles use and this
    /// process can't draw. Fonts already in the project's `assets/font/`
    /// are registered first, so they're never fetched again.
    public static func install(missingFrom project: Project, folder: ProjectFolder, projectFile: URL, installer: FontInstalling?) async -> Outcome {
        ProjectFonts.registerNew(in: folder)
        let wanted = ProjectFonts.missing(in: project).filter { $0.presetID != nil }
        return await install(wanted, projectID: project.id, folder: folder, projectFile: projectFile, installer: installer)
    }

    /// Installs a preset's font if this process can't draw it, whether or
    /// not a title uses the preset yet (captions about to be added).
    public static func install(presetID: String, projectID: String, folder: ProjectFolder, projectFile: URL, installer: FontInstalling?) async -> Outcome {
        ProjectFonts.registerNew(in: folder)
        guard let font = missingFont(ofPreset: presetID) else { return Outcome() }
        return await install([font], projectID: projectID, folder: folder, projectFile: projectFile, installer: installer)
    }

    /// The preset's font as a missing font, when this process can't draw
    /// it. Nil when it can, or when it comes with macOS.
    public static func missingFont(ofPreset presetID: String) -> MissingFont? {
        guard let preset = TitlePresets.preset(presetID), let name = preset.style.font, let asset = preset.fontAsset,
              !ProjectFonts.isAvailable(name) else { return nil }
        return MissingFont(name: name, clipIDs: [], presetID: preset.id, assetID: asset)
    }

    private static func install(_ fonts: [MissingFont], projectID: String, folder: ProjectFolder, projectFile: URL, installer: FontInstalling?) async -> Outcome {
        var outcome = Outcome()
        guard let installer, !fonts.isEmpty else { return outcome }
        var seen = Set<String>()
        for font in fonts where seen.insert(font.assetID).inserted {
            let key = "\(folder.root.path)|\(font.assetID)"
            guard let result = await downloads.run(key, { try await installer.install(font.assetID, in: folder, projectID: projectID, projectFile: projectFile) }) else {
                // It failed moments ago; the missing font's warning says what to do.
                continue
            }
            switch result {
            case .success(let files):
                outcome.installed.append(InstalledFont(name: font.name, presetID: font.presetID ?? "", assetID: font.assetID, files: files))
            case .failure(let error):
                let reason = (error as? ServiceError)?.message ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
                outcome.failures.append("Couldn't install \(font.name) from the asset library: \(reason)")
            }
        }
        // The copies are the project's own now, whichever process made them.
        ProjectFonts.registerNew(in: folder)
        return outcome
    }

    /// One download per font and project at a time (the app's viewer and
    /// an agent's render can ask together), and none for a couple of
    /// minutes after one fails, so an offline Mac doesn't retry on every
    /// frame.
    final class Downloads: @unchecked Sendable {
        let retryAfter: TimeInterval = 120
        private let lock = NSLock()
        private var running: [String: Task<Result<[String], Error>, Never>] = [:]
        private var failedAt: [String: Date] = [:]

        /// The download's result, or nil when it failed too recently to try.
        func run(_ key: String, _ body: @escaping @Sendable () async throws -> [String]) async -> Result<[String], Error>? {
            let task: Task<Result<[String], Error>, Never>? = lock.withLock {
                if let started = running[key] { return started }
                if let failed = failedAt[key], Date().timeIntervalSince(failed) < retryAfter { return nil }
                let started = Task { () -> Result<[String], Error> in
                    do { return .success(try await body()) } catch { return .failure(error) }
                }
                running[key] = started
                return started
            }
            guard let task else { return nil }
            let result = await task.value
            lock.withLock {
                running[key] = nil
                if case .failure = result { failedAt[key] = Date() } else { failedAt[key] = nil }
            }
            return result
        }
    }
}

extension TandemService {
    /// Captions use the caption preset's font. Applying them installs it the
    /// first time it's missing; either way, a font that's still missing is
    /// a warning with the fix, never a quiet fall back to SF Pro.
    func captionFonts(_ result: inout CaptionsResult, applying: Bool) async {
        guard !result.captions.isEmpty else { return }
        let projectID = coordinator.project.id
        if applying {
            let outcome = await PresetFonts.install(presetID: "caption", projectID: projectID, folder: folder, projectFile: session.fileURL, installer: fontInstaller)
            if !outcome.installed.isEmpty { result.installedFonts = outcome.installed }
            result.warnings += outcome.failures
        } else {
            ProjectFonts.registerNew(in: folder)
        }
        guard let font = PresetFonts.missingFont(ofPreset: "caption") else { return }
        var warning = font.warning(count: result.captions.count)
        if !applying && fontInstaller != nil { warning += " (applying the captions tries that for you)" }
        result.warnings.append(warning)
    }
}

extension TandemService {
    /// A frame grab that first installs a built-in preset's font the titles
    /// need (the first render that uses it), and says why when it can't.
    func withPresetFonts(_ render: @escaping @Sendable () async throws -> ImageResult) -> @Sendable () async throws -> ImageResult {
        let install = presetFontsStep()
        return {
            let failures = await install()
            var result = try await render()
            result.warnings = failures + result.warnings
            return result
        }
    }

    /// The same for a review clip or an export.
    func withPresetFonts(_ render: @escaping @Sendable () async throws -> ExportOutcome) -> @Sendable () async throws -> ExportOutcome {
        let install = presetFontsStep()
        return {
            let failures = await install()
            var result = try await render()
            result.warnings = failures + result.warnings
            return result
        }
    }

    /// Worked out while the project is open, and run with the render,
    /// which for a CLI command is after the project is closed again.
    private func presetFontsStep() -> @Sendable () async -> [String] {
        let project = coordinator.project
        let installer = fontInstaller
        let folder = self.folder
        let file = session.fileURL
        return {
            await PresetFonts.install(missingFrom: project, folder: folder, projectFile: file, installer: installer).failures
        }
    }
}
