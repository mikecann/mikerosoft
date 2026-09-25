import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemAssets

/// Real APIs, real Keychain. Opt in with `TANDEM_LIVE_ASSETS=1`:
///
///     TANDEM_LIVE_ASSETS=1 swift test --package-path tools/tandem --filter LiveProviderTests
///
/// Providers without a key in the Keychain skip. Nothing here costs money;
/// the paid ElevenLabs generations are in `PaidLiveTests`.
final class LiveProviderTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TANDEM_LIVE_ASSETS"] == "1" else {
            throw XCTSkip("set TANDEM_LIVE_ASSETS=1 to test against the real APIs")
        }
    }

    func liveLibrary(settings: AssetSettings = AssetSettings()) throws -> AssetLibrary {
        let root = tempFolder("live")
        return try AssetLibrary(root: root.appendingPathComponent("Assets"), previewFolder: root.appendingPathComponent("Previews"), settings: settings)
    }

    func testNotoEmojiEndToEnd() async throws {
        let library = try liveLibrary()
        let results = await library.searchProviders(ProviderQuery(text: "rocket"), providerIDs: ["noto"])
        XCTAssertNil(results[0].error)
        XCTAssertTrue(results[0].assets.contains { $0.id == "noto:1f680" })
        let all = try await (library.provider("noto") as! NotoEmojiProvider).index()
        XCTAssertGreaterThan(all.count, 800)

        let rocket = try await library.fetch("noto:1f680")
        XCTAssertEqual(rocket.state, .normalised)
        XCTAssertTrue(rocket.hasAlpha)
        XCTAssertEqual(rocket.width, AssetNormaliser.canRenderLottie ? 1024 : 512)
        let placement = try await library.use("noto:1f680", in: ProjectFolder(root: tempFolder("live-project")), projectID: "prj_live")
        XCTAssertEqual(placement.mediaItem?.role, .sticker)
        XCTAssertEqual(try library.credits(assetIDs: ["noto:1f680"]).text(), "Credits\n\(NotoEmojiProvider.creditLine)")
    }

    func testIconifySearchAndFetch() async throws {
        let library = try liveLibrary()
        let results = await library.searchProviders(ProviderQuery(text: "database", perPage: 20), providerIDs: ["iconify"])
        let icons = results[0].assets
        XCTAssertNil(results[0].error)
        XCTAssertFalse(icons.isEmpty)
        XCTAssertTrue(icons.allSatisfy { !LicencePolicy.isExcluded(spdx: $0.remote["spdx"] ?? "GPL") })
        let icon = try await library.fetch(icons[0].id)
        XCTAssertEqual(icon.files.normalised, "normalised.png")
        XCTAssertTrue(icon.hasAlpha)
    }

    func testSVGLConvexLogo() async throws {
        let library = try liveLibrary()
        let results = await library.searchProviders(ProviderQuery(text: "convex"), providerIDs: ["svgl"])
        XCTAssertTrue(results[0].assets.contains { $0.id == "svgl:convex" })
        let logo = try await library.fetch("svgl:convex")
        XCTAssertEqual(logo.files.normalised, "normalised.png")
        XCTAssertEqual(max(logo.width ?? 0, logo.height ?? 0), 2048)
    }

    func testStarterContentFetchesLive() async throws {
        let library = try liveLibrary()
        try library.installStarterContent()
        for id in ["iconify:mdi:database", "svgl:react_dark", "noto:2705"] {
            let asset = try await library.fetch(id)
            XCTAssertEqual(asset.state, .normalised, id)
        }
    }

    func testFontsourceInter() async throws {
        let library = try liveLibrary()
        let results = await library.searchProviders(ProviderQuery(text: "inter", perPage: 5), providerIDs: ["fontsource"])
        XCTAssertEqual(results[0].assets.first?.id, "fontsource:inter")
        let inter = try await library.fetch("fontsource:inter")
        XCTAssertTrue(inter.remote["fonts"]?.contains("Inter") == true)
        XCTAssertGreaterThan((inter.remote["extraFiles"] ?? "").split(separator: "\n").count, 3)
    }

    func testPexelsWhenThereIsAKey() async throws {
        let library = try liveLibrary()
        guard await library.provider("pexels")!.status().isUsable else { throw XCTSkip("no Pexels key in the Keychain") }
        let results = await library.searchProviders(ProviderQuery(text: "server room", kinds: [.video], perPage: 3), providerIDs: ["pexels"])
        XCTAssertNil(results[0].error)
        XCTAssertFalse(results[0].assets.isEmpty)
    }

    func testPixabayWhenThereIsAKey() async throws {
        let library = try liveLibrary()
        guard await library.provider("pixabay")!.status().isUsable else { throw XCTSkip("no Pixabay key in the Keychain") }
        let results = await library.searchProviders(ProviderQuery(text: "code", kinds: [.video], perPage: 3), providerIDs: ["pixabay"])
        XCTAssertNil(results[0].error)
        XCTAssertFalse(results[0].assets.isEmpty)
    }

    func testFreesoundWhenThereIsAToken() async throws {
        // Search only, to check the integration; commercial use still needs
        // UPF's permission before it's turned on for real.
        let library = try liveLibrary(settings: AssetSettings(freesoundEnabled: true))
        guard await library.provider("freesound")!.status().isUsable else { throw XCTSkip("no Freesound token in the Keychain") }
        let results = await library.searchProviders(ProviderQuery(text: "whoosh", perPage: 5), providerIDs: ["freesound"])
        XCTAssertNil(results[0].error)
        XCTAssertTrue(results[0].assets.allSatisfy { $0.licenceClass == .noCredit || $0.licenceClass == .creditNeeded })
    }

    func testElevenLabsKeyIsFound() async throws {
        let library = try liveLibrary()
        let status = await library.provider("elevenlabs")!.status()
        XCTAssertNotEqual(status.state, .needsKey, "expected a key in the Keychain under service elevenlabs")
    }
}

/// ElevenLabs generations cost credits. Opt in separately with
/// `TANDEM_LIVE_ELEVENLABS=1`; each test makes exactly one request.
final class PaidLiveTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TANDEM_LIVE_ELEVENLABS"] == "1" else {
            throw XCTSkip("set TANDEM_LIVE_ELEVENLABS=1 to make paid ElevenLabs generations")
        }
    }

    func liveLibrary() throws -> AssetLibrary {
        let root = tempFolder("paid")
        return try AssetLibrary(root: root.appendingPathComponent("Assets"), previewFolder: root.appendingPathComponent("Previews"))
    }

    func testOneSoundEffect() async throws {
        let library = try liveLibrary()
        do {
            let made = try await library.generate(GenerationRequest(kind: .sfx, prompt: "A short soft UI click", duration: 1))
            let asset = try XCTUnwrap(made.first)
            print("ELEVENLABS SFX OK: \(asset.id) \(asset.duration ?? 0) s, channels \(asset.remote["channels"] ?? "?"), loudness \(asset.loudness?.integratedLUFS ?? 0) LUFS")
            XCTAssertEqual(asset.state, .normalised)
            XCTAssertEqual(try XCTUnwrap(asset.duration), 1, accuracy: 0.1)
        } catch AssetError.permission(let provider, let message) {
            print("ELEVENLABS SFX REFUSED: \(provider): \(message)")
            let status = await library.provider("elevenlabs")!.status()
            print("ELEVENLABS STATUS AFTER: \(status.state.rawValue): \(status.message ?? "")")
            XCTAssertEqual(status.state, .limited)
            throw XCTSkip("the key lacks the sound_generation permission: \(message)")
        }
    }

    func testOneMusicCue() async throws {
        let library = try liveLibrary()
        let made = try await library.generate(GenerationRequest(kind: .music, prompt: "Chilled lounge downtempo bed, Rhodes, round bass, brushed drums, 85 BPM, instrumental", duration: 10))
        let asset = try XCTUnwrap(made.first)
        print("ELEVENLABS MUSIC OK: \(asset.id) \(asset.duration ?? 0) s, loudness \(asset.loudness?.integratedLUFS ?? 0) LUFS, song \(asset.remote["songID"] ?? "?")")
        XCTAssertEqual(asset.state, .normalised)
        XCTAssertEqual(asset.kind, .music)
        XCTAssertEqual(try XCTUnwrap(asset.duration), 10, accuracy: 1)
        let file = try AVAudioFile(forReading: try XCTUnwrap(library.playableURL(for: asset)))
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
    }
}
