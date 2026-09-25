import XCTest
import TandemMedia
@testable import TandemAssets

final class CatalogTests: XCTestCase {
    func testUpsertAndReadBack() throws {
        let catalog = try makeCatalog()
        var asset = sampleAsset(id: "whoosh-01.wav", name: "Whoosh 01", tags: ["whoosh", "air, fast"], summary: "A fast whoosh", duration: 0.8, bpm: 120)
        asset.musicalKey = "F minor"
        asset.width = 10
        asset.height = 20
        asset.size = 1234
        asset.sha256 = "abc"
        asset.previewURL = URL(string: "https://example.com/p.mp3")
        asset.thumbnailURL = URL(string: "https://example.com/t.jpg")
        asset.pageURL = URL(string: "https://example.com/page")
        asset.remote = ["download": "https://example.com/d.wav"]
        asset.files = AssetFiles(folder: "import/abc", original: "/x/whoosh-01.wav", normalised: "normalised.wav", thumbnail: "thumbnail.jpg", peaks: "peaks.bin")
        asset.loudness = Loudness(integratedLUFS: -20.5, truePeakDBTP: -1.25, loudnessRange: 3)
        asset.popularity = 7
        try catalog.upsert(asset)

        let read = try XCTUnwrap(catalog.asset(id: "import:whoosh-01.wav"))
        XCTAssertEqual(read.name, "Whoosh 01")
        XCTAssertEqual(read.tags, ["whoosh", "air, fast"])
        XCTAssertEqual(read.summary, "A fast whoosh")
        XCTAssertEqual(read.duration, 0.8)
        XCTAssertEqual(read.bpm, 120)
        XCTAssertEqual(read.musicalKey, "F minor")
        XCTAssertEqual(read.width, 10)
        XCTAssertEqual(read.height, 20)
        XCTAssertEqual(read.size, 1234)
        XCTAssertEqual(read.sha256, "abc")
        XCTAssertEqual(read.previewURL, asset.previewURL)
        XCTAssertEqual(read.thumbnailURL, asset.thumbnailURL)
        XCTAssertEqual(read.pageURL, asset.pageURL)
        XCTAssertEqual(read.remote, asset.remote)
        XCTAssertEqual(read.files, asset.files)
        XCTAssertEqual(read.loudness, asset.loudness)
        XCTAssertEqual(read.popularity, 7)
        XCTAssertEqual(read.state, .original)
        XCTAssertEqual(read.licenceClass, .noCredit)
        XCTAssertEqual(read.addedAt.timeIntervalSince1970, asset.addedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(read.isFavourite)
        XCTAssertNil(read.lastUsed)
    }

    func testUpdatingAnAssetUpdatesTheSearchIndex() throws {
        let catalog = try makeCatalog()
        var asset = sampleAsset(id: "a", name: "Old name")
        try catalog.upsert(asset)
        asset.name = "Shiny new name"
        try catalog.upsert(asset)
        XCTAssertEqual(try catalog.search(AssetQuery(text: "shiny")).map(\.id), ["import:a"])
        XCTAssertEqual(try catalog.search(AssetQuery(text: "old")).map(\.id), [])
        XCTAssertEqual(try catalog.count(AssetQuery()), 1)
    }

    func testNameMatchesRankAboveTagAndDescriptionMatches() throws {
        let catalog = try makeCatalog()
        try catalog.upsert([
            sampleAsset(id: "desc", name: "Air burst", summary: "sounds a bit like a whoosh"),
            sampleAsset(id: "tag", name: "Transition 4", tags: ["whoosh"]),
            sampleAsset(id: "name", name: "Whoosh soft")
        ])
        XCTAssertEqual(try catalog.search(AssetQuery(text: "whoosh")).map(\.providerID), ["name", "tag", "desc"])
    }

    func testWordsMatchAsPrefixesAndStems() throws {
        let catalog = try makeCatalog()
        try catalog.upsert([
            sampleAsset(id: "1", name: "Mouse click"),
            sampleAsset(id: "2", name: "Keyboard typing"),
            sampleAsset(id: "3", name: "Whooshes, fast")
        ])
        XCTAssertEqual(try catalog.search(AssetQuery(text: "whoo")).map(\.providerID), ["3"])
        XCTAssertEqual(try catalog.search(AssetQuery(text: "clicks")).map(\.providerID), ["1"])
        XCTAssertEqual(try catalog.search(AssetQuery(text: "type")).map(\.providerID), ["2"])
        // Every word has to match.
        XCTAssertEqual(try catalog.search(AssetQuery(text: "mouse typing")).map(\.providerID), [])
    }

    func testSearchTextWithQuerySyntaxIsTreatedAsWords() throws {
        let catalog = try makeCatalog()
        try catalog.upsert(sampleAsset(id: "1", name: "Rocket launch"))
        XCTAssertEqual(try catalog.search(AssetQuery(text: "\"rocket\" OR -x:* NEAR(")).map(\.providerID), [])
        XCTAssertEqual(try catalog.search(AssetQuery(text: "rocket!")).map(\.providerID), ["1"])
        XCTAssertEqual(try catalog.search(AssetQuery(text: "  ?? ")).count, 1)
    }

    func testProviderIDsAreSearchable() throws {
        let catalog = try makeCatalog()
        try catalog.upsert(sampleAsset(provider: "iconify", id: "mdi:rocket-launch", kind: .icon, name: "Rocket launch"))
        XCTAssertEqual(try catalog.search(AssetQuery(text: "mdi")).map(\.id), ["iconify:mdi:rocket-launch"])
    }

    func testFilters() throws {
        let catalog = try makeCatalog()
        try catalog.upsert([
            sampleAsset(provider: "import", id: "short", kind: .sfx, name: "Click", duration: 0.2, licence: .noCredit),
            sampleAsset(provider: "import", id: "long", kind: .music, name: "Bed", duration: 120, bpm: 85, licence: .subscription),
            sampleAsset(provider: "noto", id: "1f680", kind: .sticker, name: "Rocket", duration: 0.7, hasAlpha: true, state: .remote, licence: .creditNeeded),
            sampleAsset(provider: "elevenlabs", id: "gen1", kind: .sfx, name: "Whoosh", duration: 1.5, licence: .aiGenerated)
        ])
        func ids(_ query: AssetQuery) throws -> Set<String> { Set(try catalog.search(query).map(\.providerID)) }

        XCTAssertEqual(try ids(AssetQuery(kinds: [.sfx])), ["short", "gen1"])
        XCTAssertEqual(try ids(AssetQuery(kinds: [.sfx, .music])), ["short", "long", "gen1"])
        XCTAssertEqual(try ids(AssetQuery(providers: ["noto"])), ["1f680"])
        XCTAssertEqual(try ids(AssetQuery(licenceClasses: [.creditNeeded, .aiGenerated])), ["1f680", "gen1"])
        XCTAssertEqual(try ids(AssetQuery(hasAlpha: true)), ["1f680"])
        XCTAssertEqual(try ids(AssetQuery(hasAlpha: false)), ["short", "long", "gen1"])
        XCTAssertEqual(try ids(AssetQuery(minDuration: 0.5, maxDuration: 2)), ["1f680", "gen1"])
        XCTAssertEqual(try ids(AssetQuery(minBPM: 80, maxBPM: 90)), ["long"])
        XCTAssertEqual(try ids(AssetQuery(minState: .original)), ["short", "long", "gen1"])
        XCTAssertEqual(try ids(AssetQuery(text: "whoosh", kinds: [.music])), [])
    }

    func testFavouritesRecentlyUsedAndInProject() throws {
        let catalog = try makeCatalog()
        try catalog.upsert([
            sampleAsset(id: "a", name: "Alpha"),
            sampleAsset(id: "b", name: "Bravo"),
            sampleAsset(id: "c", name: "Charlie")
        ])
        try catalog.setFavourite("import:b", true)
        try catalog.setFavourite("import:c", true)
        try catalog.setFavourite("import:c", false)
        XCTAssertEqual(try catalog.search(.favourites()).map(\.providerID), ["b"])
        XCTAssertEqual(try catalog.asset(id: "import:b")?.isFavourite, true)

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try catalog.recordUsage(AssetUsage(assetID: "import:a", projectID: "prj_one", usedAt: t0))
        try catalog.recordUsage(AssetUsage(assetID: "import:c", projectID: "prj_two", usedAt: t0.addingTimeInterval(60)))
        try catalog.recordUsage(AssetUsage(assetID: "import:a", projectID: "prj_two", usedAt: t0.addingTimeInterval(120)))

        XCTAssertEqual(try catalog.search(.recentlyUsed()).map(\.providerID), ["a", "c"])
        XCTAssertEqual(try catalog.search(.inProject("prj_one")).map(\.providerID), ["a"])
        XCTAssertEqual(Set(try catalog.search(.inProject("prj_two")).map(\.providerID)), ["a", "c"])
        XCTAssertEqual(try catalog.asset(id: "import:a")?.lastUsed, t0.addingTimeInterval(120))
        XCTAssertEqual(try catalog.usage(forProject: "prj_two").map(\.assetID), ["import:c", "import:a"])
        XCTAssertEqual(try catalog.usage(forAsset: "import:a").count, 2)
    }

    func testBrowsingWithoutTextSortsByPopularity() throws {
        let catalog = try makeCatalog()
        try catalog.upsert([
            sampleAsset(provider: "noto", id: "1", kind: .sticker, name: "Less", popularity: 3),
            sampleAsset(provider: "noto", id: "2", kind: .sticker, name: "Most", popularity: 800),
            sampleAsset(provider: "noto", id: "3", kind: .sticker, name: "Unknown")
        ])
        XCTAssertEqual(try catalog.search(AssetQuery(kinds: [.sticker])).map(\.providerID), ["2", "1", "3"])
        XCTAssertEqual(try catalog.search(AssetQuery(kinds: [.sticker], sort: .name)).map(\.providerID), ["1", "2", "3"])
        XCTAssertEqual(try catalog.search(AssetQuery(kinds: [.sticker], limit: 1, offset: 1)).map(\.providerID), ["1"])
    }

    func testMergingRemoteResultsKeepsLocalState() throws {
        let catalog = try makeCatalog()
        var local = sampleAsset(provider: "noto", id: "1f680", kind: .sticker, name: "Rocket", state: .normalised)
        local.files = AssetFiles(folder: "noto/1f680", original: "original.json", normalised: "normalised.mov")
        local.sha256 = "feed"
        try catalog.upsert(local)

        var fresh = sampleAsset(provider: "noto", id: "1f680", kind: .sticker, name: "Rocket ship", tags: ["space"], state: .remote, popularity: 99)
        fresh.previewURL = URL(string: "https://example.com/512.webp")
        let brandNew = sampleAsset(provider: "noto", id: "1f525", kind: .sticker, name: "Fire", state: .remote)
        let merged = try catalog.mergeRemote([fresh, brandNew])

        XCTAssertEqual(merged.map(\.id), ["noto:1f680", "noto:1f525"])
        let rocket = try XCTUnwrap(catalog.asset(id: "noto:1f680"))
        XCTAssertEqual(rocket.state, .normalised)
        XCTAssertEqual(rocket.files, local.files)
        XCTAssertEqual(rocket.sha256, "feed")
        XCTAssertEqual(rocket.name, "Rocket ship")
        XCTAssertEqual(rocket.tags, ["space"])
        XCTAssertEqual(rocket.popularity, 99)
        XCTAssertEqual(rocket.previewURL, fresh.previewURL)
        XCTAssertEqual(merged[0].state, .normalised)
        XCTAssertEqual(try catalog.asset(id: "noto:1f525")?.state, .remote)
    }

    func testDeleteRemovesFromSearch() throws {
        let catalog = try makeCatalog()
        try catalog.upsert(sampleAsset(id: "gone", name: "Temporary"))
        try catalog.delete(id: "import:gone")
        XCTAssertNil(try catalog.asset(id: "import:gone"))
        XCTAssertEqual(try catalog.search(AssetQuery(text: "temporary")).count, 0)
    }

    func testPruningRemoteRowsKeepsFavouritesUsedAndDownloaded() throws {
        let catalog = try makeCatalog()
        let old = Date(timeIntervalSince1970: 1_000)
        var assets = [
            sampleAsset(provider: "pexels", id: "stale", kind: .video, name: "Stale", state: .remote),
            sampleAsset(provider: "pexels", id: "fav", kind: .video, name: "Fav", state: .remote),
            sampleAsset(provider: "pexels", id: "used", kind: .video, name: "Used", state: .remote),
            sampleAsset(provider: "pexels", id: "local", kind: .video, name: "Local", state: .original)
        ]
        for index in assets.indices { assets[index].updatedAt = old }
        try catalog.upsert(assets)
        try catalog.setFavourite("pexels:fav", true)
        try catalog.recordUsage(AssetUsage(assetID: "pexels:used", projectID: "prj"))
        let removed = try catalog.pruneRemote(notUpdatedSince: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(Set(try catalog.search(AssetQuery()).map(\.providerID)), ["fav", "used", "local"])
    }

    func testReopeningKeepsData() throws {
        let url = tempFolder("reopen").appendingPathComponent("catalog.sqlite")
        do {
            let catalog = try AssetCatalog(url: url)
            try catalog.upsert(sampleAsset(id: "kept", name: "Kept"))
        }
        let again = try AssetCatalog(url: url)
        XCTAssertEqual(try again.search(AssetQuery(text: "kept")).map(\.providerID), ["kept"])
    }

    func testQueryDecodesLeniently() throws {
        let json = #"{"text": "whoosh", "kinds": ["sfx"], "maxDuration": 2}"#
        let query = try JSONDecoder().decode(AssetQuery.self, from: Data(json.utf8))
        XCTAssertEqual(query.text, "whoosh")
        XCTAssertEqual(query.kinds, [.sfx])
        XCTAssertEqual(query.maxDuration, 2)
        XCTAssertEqual(query.limit, 100)
    }

    func testAssetIDsSplitAtTheFirstColon() {
        XCTAssertEqual(Asset.parseID("iconify:mdi:rocket")?.provider, "iconify")
        XCTAssertEqual(Asset.parseID("iconify:mdi:rocket")?.providerID, "mdi:rocket")
        XCTAssertNil(Asset.parseID("nocolon"))
        XCTAssertNil(Asset.parseID(":x"))
    }
}

final class CodableTests: XCTestCase {
    func testAssetsQueriesAndCreditsRoundTripAsJSON() throws {
        var asset = sampleAsset(provider: "noto", id: "1f680", kind: .sticker, name: "Rocket", tags: ["rocket", "🚀"], duration: 0.7, hasAlpha: true, licence: .creditNeeded, credit: "credit")
        asset.remote = ["lottie": "https://example.com/l.json"]
        asset.loudness = nil
        asset.files = AssetFiles(folder: "noto/1f680", original: "original.json", normalised: "normalised.mov", thumbnail: "thumbnail.png")
        let encoder = JSONEncoder.sorted
        let decoder = JSONDecoder.iso
        let decoded = try decoder.decode(Asset.self, from: encoder.encode(asset))
        XCTAssertEqual(decoded.id, asset.id)
        XCTAssertEqual(decoded.tags, asset.tags)
        XCTAssertEqual(decoded.files, asset.files)
        XCTAssertEqual(decoded.remote, asset.remote)
        XCTAssertEqual(decoded.addedAt.timeIntervalSince1970, asset.addedAt.timeIntervalSince1970, accuracy: 1)

        let query = AssetQuery(text: "whoosh", kinds: [.sfx, .music], licenceClasses: [.noCredit], hasAlpha: false, maxDuration: 3, favouritesOnly: true, sort: .name)
        XCTAssertEqual(try JSONDecoder().decode(AssetQuery.self, from: JSONEncoder().encode(query)), query)

        // An agent can send just the fields it cares about.
        let minimal = try JSONDecoder().decode(Asset.self, from: Data(#"{"provider": "import", "providerID": "x.wav", "kind": "sfx"}"#.utf8))
        XCTAssertEqual(minimal.id, "import:x.wav")
        XCTAssertEqual(minimal.name, "x.wav")
        XCTAssertEqual(minimal.state, .remote)
        XCTAssertEqual(minimal.licenceClass, .unknown)

        let request = try JSONDecoder().decode(GenerationRequest.self, from: Data(#"{"prompt": "whoosh"}"#.utf8))
        XCTAssertEqual(request.kind, .sfx)
        XCTAssertEqual(request.variations, 1)
        XCTAssertTrue(request.instrumental)
    }

    func testAccentsDontMatter() throws {
        let catalog = try makeCatalog()
        try catalog.upsert(sampleAsset(id: "cafe", name: "Café ambience"))
        XCTAssertEqual(try catalog.search(AssetQuery(text: "cafe")).map(\.providerID), ["cafe"])
        XCTAssertEqual(try catalog.search(AssetQuery(text: "CAFÉ")).map(\.providerID), ["cafe"])
    }
}

final class BrowserSectionTests: XCTestCase {
    func testEveryKindHasExactlyOneSection() {
        for kind in AssetKind.allCases {
            let sections = BrowserSection.allCases.filter { $0.kinds.contains(kind) }
            XCTAssertEqual(sections.count, 1, "\(kind)")
            XCTAssertEqual(BrowserSection.section(for: kind), sections.first)
        }
        XCTAssertTrue(BrowserSection.effects.kinds.isEmpty)
        XCTAssertEqual(BrowserSection.allCases.map(\.title).first, "Music")
    }
}
