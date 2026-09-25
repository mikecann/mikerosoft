import XCTest
@testable import TandemAssets

// Providers against recorded responses. The Noto, Iconify, SVGL and
// Fontsource fixtures are trimmed real responses from September 2026. Pexels,
// Pixabay and Freesound have no key on this Mac, so their fixtures follow
// the response shapes in each API's documentation.

final class NotoProviderTests: XCTestCase {
    func testIndexBecomesStickerAssets() async throws {
        let transport = FixtureTransport()
        try transport.on("noto-emoji-animation/data/api.json", fixture: "noto_api.json")
        let provider = NotoEmojiProvider(environment: makeEnvironment(transport))

        let all = try await provider.index()
        XCTAssertEqual(all.count, 12)
        let rocket = try XCTUnwrap(all.first { $0.providerID == "1f680" })
        XCTAssertEqual(rocket.id, "noto:1f680")
        XCTAssertEqual(rocket.name, "Rocket")
        XCTAssertEqual(rocket.kind, .sticker)
        XCTAssertTrue(rocket.hasAlpha)
        XCTAssertTrue(rocket.tags.contains("🚀"))
        XCTAssertEqual(rocket.licenceClass, .creditNeeded)
        XCTAssertEqual(rocket.creditLine, NotoEmojiProvider.creditLine)
        XCTAssertEqual(rocket.previewURL?.absoluteString, "https://fonts.gstatic.com/s/e/notoemoji/latest/1f680/512.webp")
        XCTAssertEqual(rocket.remote["lottie"], "https://fonts.gstatic.com/s/e/notoemoji/latest/1f680/lottie.json")
        // Most popular first.
        XCTAssertEqual(all.map(\.popularity), all.map(\.popularity).sorted { ($0 ?? 0) > ($1 ?? 0) })

        let warning = try XCTUnwrap(all.first { $0.providerID == "26a0_fe0f" })
        XCTAssertTrue(warning.tags.contains("⚠️"))
    }

    func testSearchMatchesTagsAndCachesTheIndex() async throws {
        let transport = FixtureTransport()
        try transport.on("api.json", fixture: "noto_api.json")
        let provider = NotoEmojiProvider(environment: makeEnvironment(transport))

        let fire = try await provider.search(ProviderQuery(text: "lit"))
        XCTAssertEqual(fire.map(\.providerID), ["1f525"])
        let thumbs = try await provider.search(ProviderQuery(text: "thumbs"))
        XCTAssertEqual(thumbs.map(\.providerID), ["1f44d"])
        let nothing = try await provider.search(ProviderQuery(text: "fire", kinds: [.sfx]))
        XCTAssertTrue(nothing.isEmpty)
        let page = try await provider.search(ProviderQuery(text: "", page: 2, perPage: 5))
        XCTAssertEqual(page.count, 5)
        // One index download serves every search for a week.
        XCTAssertEqual(transport.requests(matching: "api.json").count, 1)
    }
}

final class IconifyProviderTests: XCTestCase {
    func testSearchLeavesOutGPLShareAlikeAndNonCommercialSets() async throws {
        let transport = FixtureTransport()
        try transport.on("api.iconify.design/search", fixture: "iconify_search_home.json")
        let provider = IconifyProvider(environment: makeEnvironment(transport))

        let results = try await provider.search(ProviderQuery(text: "home"))

        // typcn and wordpress are GPL, entypo is CC BY-SA.
        XCTAssertEqual(results.map(\.providerID), ["mdi:home", "tabler:home"])
        let home = results[0]
        XCTAssertEqual(home.id, "iconify:mdi:home")
        XCTAssertEqual(home.kind, .icon)
        XCTAssertEqual(home.licenceClass, .noCredit)
        XCTAssertNil(home.creditLine)
        XCTAssertEqual(home.remote["spdx"], "Apache-2.0")
        XCTAssertEqual(home.previewURL?.absoluteString, "https://api.iconify.design/mdi/home.svg?color=%23FFFFFF")
        let request = try XCTUnwrap(transport.requests.first?.url?.absoluteString)
        XCTAssertTrue(request.contains("query=home"))
    }

    func testCreativeCommonsSetsGetACreditLine() async throws {
        let transport = FixtureTransport()
        try transport.on("api.iconify.design/search", fixture: "iconify_search_rocket.json")
        let provider = IconifyProvider(environment: makeEnvironment(transport), colour: "#000000")

        let results = try await provider.search(ProviderQuery(text: "rocket"))
        let twemoji = try XCTUnwrap(results.first { $0.providerID == "twemoji:rocket" })
        XCTAssertEqual(twemoji.licenceClass, .creditNeeded)
        XCTAssertEqual(twemoji.creditLine, "Twitter Emoji icons by Twitter, CC BY 4.0")
        let licence = try await provider.licence(for: twemoji)
        XCTAssertEqual(licence.spdx, "CC-BY-4.0")
        XCTAssertEqual(licence.creditLine, twemoji.creditLine)
        XCTAssertTrue(results[0].remote["svg"]?.contains("color=%23000000") == true)
    }

    func testFetchDownloadsTheColouredSVG() async throws {
        let transport = FixtureTransport()
        try transport.on("api.iconify.design/search", fixture: "iconify_search_rocket.json")
        transport.on("api.iconify.design/mdi/rocket.svg", data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M0 0h24v24H0z\"/></svg>".utf8))
        let provider = IconifyProvider(environment: makeEnvironment(transport))
        let rocket = try await provider.search(ProviderQuery(text: "rocket")).first { $0.providerID == "mdi:rocket" }!
        let folder = tempFolder("iconify")

        let fetched = try await provider.fetchOriginal(rocket, into: folder)

        XCTAssertEqual(fetched.file.lastPathComponent, "original.svg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fetched.file.path))
        XCTAssertTrue(transport.requests.last?.url?.absoluteString.contains("color=%23FFFFFF") == true)
    }
}

final class SVGLProviderTests: XCTestCase {
    func testLogosExpandIntoVariants() async throws {
        let transport = FixtureTransport()
        try transport.on("api.svgl.app", fixture: "svgl.json")
        let provider = SVGLProvider(environment: makeEnvironment(transport))

        let convex = try await provider.search(ProviderQuery(text: "convex"))
        XCTAssertEqual(convex.map(\.providerID), ["convex", "convex_wordmark_light", "convex_wordmark_dark"])
        XCTAssertEqual(convex[0].name, "Convex")
        XCTAssertEqual(convex[1].name, "Convex wordmark (for light backgrounds)")
        XCTAssertEqual(convex[0].kind, .logo)
        XCTAssertEqual(convex[0].licenceClass, .noCredit)
        XCTAssertEqual(convex[0].remote["svg"], "https://svgl.app/library/convex.svg")

        let react = try await provider.search(ProviderQuery(text: "react"))
        XCTAssertTrue(react.map(\.providerID).contains("react_dark"))
        let licence = try await provider.licence(for: convex[0])
        XCTAssertEqual(licence.licenceClass, .noCredit)
        XCTAssertTrue(licence.notes?.contains("refer to Convex") == true)
    }
}

final class FontsourceProviderTests: XCTestCase {
    func testSearchAndFetchEveryWeight() async throws {
        let transport = FixtureTransport()
        // Later routes win, so the more specific one goes second.
        try transport.on("api.fontsource.org/v1/fonts", fixture: "fontsource_fonts.json")
        try transport.on("api.fontsource.org/v1/fonts/inter", fixture: "fontsource_inter.json")
        transport.on("cdn.jsdelivr.net/fontsource", data: Data("font".utf8))
        let provider = FontsourceProvider(environment: makeEnvironment(transport))

        let results = try await provider.search(ProviderQuery(text: "inter"))
        let inter = try XCTUnwrap(results.first)
        XCTAssertEqual(inter.id, "fontsource:inter")
        XCTAssertEqual(inter.kind, .font)
        XCTAssertEqual(inter.licenceClass, .noCredit)
        // A name match ranks above the "monospace" category.
        let mono = try await provider.search(ProviderQuery(text: "mono"))
        XCTAssertEqual(mono.first?.providerID, "jetbrains-mono")
        XCTAssertEqual(Set(mono.map(\.providerID)), ["jetbrains-mono", "fira-code", "source-code-pro"])

        let folder = tempFolder("font")
        let fetched = try await provider.fetchOriginal(inter, into: folder)
        XCTAssertEqual(fetched.file.lastPathComponent, "inter-400-normal.ttf")
        XCTAssertEqual(fetched.extras.map(\.lastPathComponent), ["inter-700-normal.ttf"])
        XCTAssertEqual(transport.requests(matching: "latin-400-normal.ttf").count, 1)
    }
}

final class PexelsProviderTests: XCTestCase {
    func testNeedsAKey() async throws {
        let provider = PexelsProvider(environment: makeEnvironment(FixtureTransport()))
        let status = await provider.status()
        XCTAssertEqual(status.state, .needsKey)
        do {
            _ = try await provider.search(ProviderQuery(text: "server"))
            XCTFail("expected an error")
        } catch let error as AssetError {
            guard case .providerUnavailable = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testVideosAndPhotosWithTheKeyInAHeader() async throws {
        let transport = FixtureTransport()
        try transport.on("api.pexels.com/videos/search", fixture: "pexels_videos.json")
        try transport.on("api.pexels.com/v1/search", fixture: "pexels_photos.json")
        let environment = makeEnvironment(transport, secrets: ["pexels": "PEXELS-SECRET"])
        let provider = PexelsProvider(environment: environment)
        let status = await provider.status()
        XCTAssertEqual(status, .ready)

        let results = try await provider.search(ProviderQuery(text: "server room"))

        XCTAssertEqual(results.map(\.providerID), ["video-5028622", "video-3129671", "photo-1181675"])
        let video = results[0]
        XCTAssertEqual(video.name, "Blinking lights in a server room")
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.duration, 18)
        // The biggest file up to 4K UHD, not the 4096 wide one.
        XCTAssertEqual(video.width, 3840)
        XCTAssertEqual(video.remote["download"], "https://videos.pexels.com/video-files/5028622/5028622-uhd_3840_2160_25fps.mp4")
        XCTAssertEqual(video.previewURL?.absoluteString, "https://videos.pexels.com/video-files/5028622/5028622-sd_640_360_25fps.mp4")
        XCTAssertEqual(video.licenceClass, .noCredit)
        XCTAssertEqual(video.creditLine, "Video by Brett Sayles on Pexels")
        XCTAssertEqual(results[1].name, "Pexels video 3129671")
        let photo = results[2]
        XCTAssertEqual(photo.name, "Woman programming on a notebook")
        XCTAssertEqual(photo.remote["download"], "https://images.pexels.com/photos/1181675/pexels-photo-1181675.jpeg")

        for request in transport.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "PEXELS-SECRET")
            XCTAssertFalse(request.url!.absoluteString.contains("PEXELS-SECRET"))
        }
        XCTAssertFalse(try Self.cacheContains("PEXELS-SECRET", in: environment.cacheFolder))
    }

    /// True when any cache file's name or body contains `text`.
    static func cacheContains(_ text: String, in folder: URL) throws -> Bool {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        for case let file as URL in files {
            if file.lastPathComponent.contains(text) { return true }
            if let data = try? Data(contentsOf: file), String(decoding: data, as: UTF8.self).contains(text) { return true }
        }
        return false
    }
}

final class PixabayProviderTests: XCTestCase {
    func testSearchParsesVideosAndImages() async throws {
        let transport = FixtureTransport()
        try transport.on("pixabay.com/api/videos/", fixture: "pixabay_videos.json")
        try transport.on("image_type=photo", fixture: "pixabay_images.json")
        let provider = PixabayProvider(environment: makeEnvironment(transport, secrets: ["pixabay": "PIXABAY-SECRET"]))

        let results = try await provider.search(ProviderQuery(text: "yellow flowers"))

        XCTAssertEqual(results.map(\.providerID), ["video-125", "image-195893"])
        let video = results[0]
        XCTAssertEqual(video.name, "Flowers, yellow, blossom")
        XCTAssertEqual(video.tags, ["flowers", "yellow", "blossom"])
        // "large" is empty for this clip, so the original is "medium".
        XCTAssertEqual(video.remote["download"], "https://cdn.pixabay.com/video/2015/08/08/125-135736646_medium.mp4")
        XCTAssertEqual(video.width, 1920)
        XCTAssertEqual(video.previewURL?.absoluteString, "https://cdn.pixabay.com/video/2015/08/08/125-135736646_tiny.mp4")
        let image = results[1]
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.remote["download"], "https://pixabay.com/get/ed6a99fd0a76647_1280.jpg")
        XCTAssertEqual(image.creditLine, "Image by Josch13 from Pixabay")
    }

    func testResponsesAreCachedForTwentyFourHoursWithoutTheKey() async throws {
        let transport = FixtureTransport()
        try transport.on("pixabay.com/api/videos/", fixture: "pixabay_videos.json")
        let clock = TestClock()
        let environment = makeEnvironment(transport, secrets: ["pixabay": "PIXABAY-SECRET"], now: { clock.now })
        let provider = PixabayProvider(environment: environment)
        let query = ProviderQuery(text: "flowers", kinds: [.video])

        _ = try await provider.search(query)
        clock.advance(23 * 3600)
        _ = try await provider.search(query)
        XCTAssertEqual(transport.requests.count, 1, "Pixabay requires caching for 24 hours")
        clock.advance(2 * 3600)
        _ = try await provider.search(query)
        XCTAssertEqual(transport.requests.count, 2)

        XCTAssertTrue(transport.requests[0].url!.absoluteString.contains("key=PIXABAY-SECRET"))
        XCTAssertFalse(try PexelsProviderTests.cacheContains("PIXABAY-SECRET", in: environment.cacheFolder))
    }
}

final class FreesoundProviderTests: XCTestCase {
    func testOffByDefault() async throws {
        let provider = FreesoundProvider(environment: makeEnvironment(FixtureTransport(), secrets: ["freesound": "TOKEN"]))
        let status = await provider.status()
        XCTAssertEqual(status.state, .disabled)
        XCTAssertTrue(status.message?.contains("UPF") == true)
        do {
            _ = try await provider.search(ProviderQuery(text: "whoosh"))
            XCTFail("expected an error")
        } catch let error as AssetError {
            guard case .providerUnavailable = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testOnlyCC0AndCCBYWithCredits() async throws {
        let transport = FixtureTransport()
        try transport.on("freesound.org/apiv2/search/", fixture: "freesound_search.json")
        try transport.on("freesound.org/apiv2/sounds/60013/similar/", fixture: "freesound_search.json")
        let provider = FreesoundProvider(environment: makeEnvironment(transport, secrets: ["freesound": "FREESOUND-TOKEN"]), enabled: true)
        let status = await provider.status()
        XCTAssertEqual(status, .ready)

        let results = try await provider.search(ProviderQuery(text: "whoosh", maxDuration: 2))

        XCTAssertEqual(results.map(\.providerID), ["60013", "346373"])
        XCTAssertEqual(results[0].licenceClass, .noCredit)
        XCTAssertEqual(results[1].licenceClass, .creditNeeded)
        XCTAssertEqual(results[1].creditLine, "\"Whoosh Heavy Spear\" by denao270 (https://freesound.org/s/346373/), CC BY 4.0")
        XCTAssertEqual(results[0].summary, "A fast  whoosh  recorded with a stick.")
        XCTAssertEqual(results[0].popularity, 51234)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token FREESOUND-TOKEN")
        let url = request.url!.absoluteString.removingPercentEncoding ?? ""
        XCTAssertTrue(url.contains("license:(\"Creative Commons 0\" OR \"Attribution\") duration:[* TO 2.0]"), url)

        let similar = try await provider.similar(to: results[0], limit: 5)
        XCTAssertEqual(similar.map(\.providerID), ["346373"])
    }
}

final class ElevenLabsProviderTests: XCTestCase {
    func testNeedsAKeyAndDoesntSearch() async throws {
        let provider = ElevenLabsProvider(environment: makeEnvironment(FixtureTransport()))
        let status = await provider.status()
        XCTAssertEqual(status.state, .needsKey)
        let results = try await provider.search(ProviderQuery(text: "whoosh"))
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(provider.capabilities.generate)
    }

    func testSoundEffectIsWrappedIntoWAV() async throws {
        let transport = FixtureTransport()
        // One second of mono silence as bare 16-bit PCM.
        transport.on("api.elevenlabs.io/v1/sound-generation", headers: ["character-cost": "40"], data: Data(count: 96_000))
        let provider = ElevenLabsProvider(environment: makeEnvironment(transport, secrets: ["elevenlabs": "XI-SECRET"]))
        let folder = tempFolder("generate")

        let takes = try await provider.generate(GenerationRequest(kind: .sfx, prompt: "Soft whoosh, left to right", duration: 1, promptInfluence: 0.5), into: folder)

        XCTAssertEqual(takes.count, 1)
        let take = takes[0]
        XCTAssertEqual(take.file.lastPathComponent, "original.wav")
        XCTAssertEqual(FormatSniffer.format(of: take.file), .wav)
        XCTAssertEqual(take.asset.provider, "elevenlabs")
        XCTAssertTrue(take.asset.providerID.hasPrefix("sfx_"))
        XCTAssertEqual(take.asset.kind, .sfx)
        XCTAssertEqual(take.asset.licenceClass, .aiGenerated)
        XCTAssertEqual(take.asset.summary, "Soft whoosh, left to right")
        XCTAssertEqual(take.asset.remote["prompt"], "Soft whoosh, left to right")
        XCTAssertEqual(take.asset.remote["channels"], "1")
        XCTAssertEqual(take.asset.remote["characterCost"], "40")
        XCTAssertEqual(try XCTUnwrap(take.asset.duration), 1, accuracy: 0.001)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "XI-SECRET")
        XCTAssertTrue(request.url!.absoluteString.contains("output_format=pcm_48000"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model_id"] as? String, "eleven_text_to_sound_v2")
        XCTAssertEqual(body["duration_seconds"] as? Double, 1)
        XCTAssertEqual(body["prompt_influence"] as? Double, 0.5)
        XCTAssertEqual(body["loop"] as? Bool, false)
    }

    func testMissingPermissionIsRememberedAndReported() async throws {
        let transport = FixtureTransport()
        try transport.on("api.elevenlabs.io/v1/sound-generation", fixture: "elevenlabs_missing_permission.json", status: 401)
        let environment = makeEnvironment(transport, secrets: ["elevenlabs": "XI-SECRET"])
        let provider = ElevenLabsProvider(environment: environment)

        do {
            _ = try await provider.generate(GenerationRequest(kind: .sfx, prompt: "click"), into: tempFolder("denied"))
            XCTFail("expected an error")
        } catch let error as AssetError {
            guard case .permission(_, let message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue(message.contains("missing_permissions"))
            XCTAssertTrue(message.contains("sound_generation"))
            XCTAssertFalse(message.contains("XI-SECRET"))
        }

        // A new provider (a later run) still knows.
        let again = ElevenLabsProvider(environment: environment)
        let status = await again.status()
        XCTAssertEqual(status.state, .limited)
        XCTAssertTrue(status.message?.contains("Sound effects are off") == true)
        XCTAssertTrue(status.message?.contains("Music still works") == true)

        // A successful call clears it.
        transport.on("api.elevenlabs.io/v1/sound-generation", data: Data(count: 9_600))
        _ = try await again.generate(GenerationRequest(kind: .sfx, prompt: "click", duration: 0.5), into: tempFolder("allowed"))
        let cleared = await again.status()
        XCTAssertEqual(cleared, .ready)
    }

    func testMusicUsesMikesSettings() async throws {
        let transport = FixtureTransport()
        transport.on("api.elevenlabs.io/v1/music", headers: ["song-id": "song-123"], data: Data("ID3".utf8) + Data(count: 100))
        let provider = ElevenLabsProvider(environment: makeEnvironment(transport, secrets: ["elevenlabs": "XI-SECRET"]))

        let takes = try await provider.generate(GenerationRequest(kind: .music, prompt: "Chilled lounge downtempo, Rhodes, 85 BPM", duration: 30, variations: 2), into: tempFolder("music"))

        XCTAssertEqual(takes.count, 2)
        XCTAssertEqual(takes[0].file.pathExtension, "mp3")
        XCTAssertEqual(takes[0].asset.kind, .music)
        XCTAssertEqual(takes[0].asset.remote["songID"], "song-123")
        XCTAssertNotEqual(takes[0].asset.providerID, takes[1].asset.providerID)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(request.url!.absoluteString.contains("output_format=mp3_48000_192"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model_id"] as? String, "music_v2_5")
        XCTAssertEqual(body["music_length_ms"] as? Int, 30_000)
        XCTAssertEqual(body["force_instrumental"] as? Bool, true)
    }

    func testRequestsAreChecked() async throws {
        let provider = ElevenLabsProvider(environment: makeEnvironment(FixtureTransport(), secrets: ["elevenlabs": "k"]))
        for request in [
            GenerationRequest(kind: .sfx, prompt: "  "),
            GenerationRequest(kind: .sfx, prompt: "x", duration: 45),
            GenerationRequest(kind: .sfx, prompt: "x", promptInfluence: 2),
            GenerationRequest(kind: .music, prompt: "x", duration: 1),
            GenerationRequest(kind: .sticker, prompt: "x")
        ] {
            do {
                _ = try await provider.generate(request, into: tempFolder("bad"))
                XCTFail("expected \(request) to be refused")
            } catch let error as AssetError {
                guard case .invalid = error else { return XCTFail("wrong error \(error)") }
            }
        }
    }

    func testShortNames() {
        XCTAssertEqual(ElevenLabsProvider.shortName("Short one"), "Short one")
        let long = ElevenLabsProvider.shortName("A very long prompt about a whoosh that goes on and on past sixty characters easily")
        XCTAssertTrue(long.hasSuffix("..."))
        XCTAssertLessThanOrEqual(long.count, 63)
    }
}

final class StubProviderTests: XCTestCase {
    func testStubsExplainThemselves() async throws {
        for provider in [EpidemicSoundProvider(), LordiconProvider()] as [AssetProvider] {
            let status = await provider.status()
            XCTAssertEqual(status.state, .stub)
            XCTAssertNotNil(status.message)
            do {
                _ = try await provider.search(ProviderQuery(text: "x"))
                XCTFail("expected an error")
            } catch let error as AssetError {
                guard case .providerUnavailable = error else { return XCTFail("wrong error \(error)") }
            }
        }
    }
}

final class HTTPTests: XCTestCase {
    func testRateLimiterWaitsBrieflyThenRefuses() async throws {
        let limiter = RateLimiter(provider: "test", limit: 2, window: 0.2, maxWait: 1)
        let start = Date()
        try await limiter.acquire()
        try await limiter.acquire()
        try await limiter.acquire()
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.15)

        let strict = RateLimiter(provider: "test", limit: 1, window: 60, maxWait: 1)
        try await strict.acquire()
        do {
            try await strict.acquire()
            XCTFail("expected rate limiting")
        } catch let error as AssetError {
            guard case .rateLimited(_, let retry) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertGreaterThan(retry, 50)
        }
    }

    func testErrorsAreReadableAndKeyFree() {
        XCTAssertEqual(ProviderHTTP.message(from: Data(#"{"detail":{"status":"missing_permissions","message":"No."}}"#.utf8)), "missing_permissions: No.")
        XCTAssertEqual(ProviderHTTP.message(from: Data(#"{"detail":[{"msg":"bad duration"},{"msg":"bad text"}]}"#.utf8)), "bad duration; bad text")
        XCTAssertEqual(ProviderHTTP.message(from: Data("API rate limit exceeded".utf8)), "API rate limit exceeded")
        XCTAssertEqual(ProviderHTTP.redact("https://pixabay.com/api/?key=abc123&q=x"), "https://pixabay.com/api/?[redacted]&q=x")
    }

    func testRateLimitResponsesBecomeRateLimitedErrors() async throws {
        let transport = FixtureTransport()
        transport.on("api.svgl.app", status: 429, headers: ["Retry-After": "30"], data: Data("slow down".utf8))
        let provider = SVGLProvider(environment: makeEnvironment(transport))
        do {
            _ = try await provider.all()
            XCTFail("expected an error")
        } catch let error as AssetError {
            XCTAssertEqual(error, .rateLimited(provider: "svgl", retryAfter: 30))
        }
    }

    func testOfflineIsANetworkError() async throws {
        let provider = SVGLProvider(environment: makeEnvironment(FixtureTransport()))
        do {
            _ = try await provider.all()
            XCTFail("expected an error")
        } catch let error as AssetError {
            guard case .network = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testKeychainLookupOfAMissingServiceIsNil() {
        XCTAssertNil(KeychainSecretStore().secret(service: "tandem-test-no-such-service-\(UUID().uuidString)"))
    }
}
