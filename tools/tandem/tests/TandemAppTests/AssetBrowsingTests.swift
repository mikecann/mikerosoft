import XCTest
@testable import TandemApp
@testable import TandemAssets
@testable import TandemCore
import TandemMedia

final class AssetBrowsingTests: XCTestCase {
    func testQueriesFollowTheBrowserState() {
        let plain = AssetBrowsing.query(section: .music, scope: .all, text: " calm piano ", provider: nil, filters: AssetFilters(), projectID: "prj_1")
        XCTAssertEqual(plain.kinds, [.music])
        XCTAssertEqual(plain.text, "calm piano")
        XCTAssertFalse(plain.favouritesOnly)
        XCTAssertNil(plain.projectID)

        let favourites = AssetBrowsing.query(section: .stickers, scope: .favourites, text: "", provider: "noto", filters: AssetFilters(), projectID: "prj_1")
        XCTAssertTrue(favourites.favouritesOnly)
        XCTAssertEqual(favourites.kinds, [.sticker])
        XCTAssertEqual(favourites.providers, ["noto"])

        XCTAssertTrue(AssetBrowsing.query(section: .sfx, scope: .recent, text: "", provider: nil, filters: AssetFilters(), projectID: nil).usedOnly)
        XCTAssertEqual(AssetBrowsing.query(section: .sfx, scope: .recent, text: "", provider: nil, filters: AssetFilters(), projectID: nil).sort, .lastUsed)
        XCTAssertEqual(AssetBrowsing.query(section: .icons, scope: .downloaded, text: "", provider: nil, filters: AssetFilters(), projectID: nil).minState, .original)
        XCTAssertEqual(AssetBrowsing.query(section: .icons, scope: .downloaded, text: "", provider: nil, filters: AssetFilters(), projectID: nil).kinds, [.icon, .logo])
        XCTAssertEqual(AssetBrowsing.query(section: .broll, scope: .inProject, text: "", provider: nil, filters: AssetFilters(), projectID: "prj_1").projectID, "prj_1")
    }

    func testFiltersOnlyApplyWhereTheyMeanSomething() {
        var filters = AssetFilters()
        filters.licences = [.noCredit, .creditNeeded]
        filters.duration = .underTwo
        filters.tempo = .fast
        filters.transparentOnly = true
        XCTAssertTrue(filters.isActive)

        let music = AssetBrowsing.query(section: .music, scope: .all, text: "", provider: nil, filters: filters, projectID: nil)
        XCTAssertEqual(music.licenceClasses, [.noCredit, .creditNeeded])
        XCTAssertNil(music.minDuration)
        XCTAssertEqual(music.maxDuration, 2)
        XCTAssertEqual(music.minBPM, 120)
        XCTAssertNil(music.hasAlpha, "sound has no transparency")

        let stickers = AssetBrowsing.query(section: .stickers, scope: .all, text: "", provider: nil, filters: filters, projectID: nil)
        XCTAssertEqual(stickers.hasAlpha, true)
        XCTAssertNil(stickers.minBPM, "tempo is for music")
        XCTAssertNil(stickers.maxDuration, "stickers aren't picked by length")

        let sfx = AssetBrowsing.query(section: .sfx, scope: .all, text: "", provider: nil, filters: filters, projectID: nil)
        XCTAssertNil(sfx.minBPM)
        XCTAssertEqual(sfx.maxDuration, 2)
        XCTAssertFalse(AssetFilters().isActive)
    }

    func testOnlineSearchAsksForTheSectionsKinds() {
        var filters = AssetFilters()
        filters.duration = .tenToSixty
        let query = AssetBrowsing.providerQuery(section: .sfx, text: " whoosh ", filters: filters)
        XCTAssertEqual(query.text, "whoosh")
        XCTAssertEqual(query.kinds, [.sfx])
        XCTAssertEqual(query.minDuration, 10)
        XCTAssertEqual(query.maxDuration, 60)
    }

    func testSourcesAreTheProvidersForTheSection() {
        let providers = [
            info("import", "Import folders", ["music", "sfx", "sticker", "icon", "logo"]),
            info("elevenlabs", "ElevenLabs", ["sfx", "music"], state: .limited),
            info("noto", "Noto animated emoji", ["sticker"]),
            info("iconify", "Iconify", ["icon"]),
            info("svgl", "SVGL logos", ["logo"]),
            info("epidemic", "Epidemic Sound", ["music", "sfx"], state: .stub)
        ]
        XCTAssertEqual(AssetBrowsing.sources(for: .music, in: providers).map(\.id), ["import", "elevenlabs", "epidemic"])
        XCTAssertEqual(AssetBrowsing.sources(for: .icons, in: providers).map(\.id), ["import", "iconify", "svgl"])
        XCTAssertEqual(AssetBrowsing.sourceName("Noto animated emoji"), "Noto")
        XCTAssertEqual(AssetBrowsing.sourceName("SVGL logos"), "SVGL")
        XCTAssertEqual(AssetBrowsing.sourceName("Google Fonts (Fontsource)"), "Google Fonts")
    }

    func testOnlineResultsSkipWhatsAlreadyListed() {
        let rocket = Asset(provider: "noto", providerID: "1f680", kind: .sticker, name: "Rocket")
        let fire = Asset(provider: "noto", providerID: "1f525", kind: .sticker, name: "Fire")
        let results = [
            AssetLibrary.ProviderResults(provider: "noto", assets: [rocket, fire], error: nil),
            AssetLibrary.ProviderResults(provider: "lordicon", assets: [], error: "Needs a subscription")
        ]
        let groups = AssetBrowsing.onlineGroups(results, excluding: [rocket])
        XCTAssertEqual(groups.map(\.provider), ["noto", "lordicon"])
        XCTAssertEqual(groups[0].assets.map(\.name), ["Fire"])
        XCTAssertEqual(groups[1].error, "Needs a subscription")
        // A provider with nothing new and nothing wrong isn't worth a heading.
        XCTAssertTrue(AssetBrowsing.onlineGroups([AssetLibrary.ProviderResults(provider: "noto", assets: [rocket], error: nil)], excluding: [rocket]).isEmpty)
    }

    func testWordsOnTiles() {
        XCTAssertEqual(AssetBrowsing.durationText(3.2), "0:03")
        XCTAssertEqual(AssetBrowsing.durationText(84.6), "1:24")
        XCTAssertEqual(AssetBrowsing.durationText(3_601), "1:00:01")
        XCTAssertEqual(AssetBrowsing.durationText(0.4), "0:00.4")
        XCTAssertNil(AssetBrowsing.durationText(nil))
        XCTAssertEqual(AssetBrowsing.licenceLabel(.noCredit), "No credit")
        XCTAssertEqual(AssetBrowsing.licenceLabel(.creditNeeded), "Credit needed")
        XCTAssertEqual(AssetBrowsing.licenceLabel(.aiGenerated), "AI generated")
        XCTAssertEqual(AssetBrowsing.licenceLabel(.unknown), "Unknown licence")

        var track = Asset(provider: "import", providerID: "f/c1a.mp3", kind: .music, name: "c1a", duration: 93, bpm: 118, licenceClass: .aiGenerated)
        XCTAssertEqual(AssetBrowsing.details(track), "1:33 · 118 BPM")
        track.bpm = nil
        XCTAssertEqual(AssetBrowsing.details(track), "1:33")
        XCTAssertEqual(AssetBrowsing.details(Asset(provider: "noto", providerID: "1f680", kind: .sticker, name: "Rocket")), "")
    }

    func testPlacingReusesMediaTheProjectAlreadyHas() throws {
        let asset = Asset(provider: "noto", providerID: "1f680", kind: .sticker, name: "Rocket", hasAlpha: true)
        let item = MediaItem(id: AssetLibrary.mediaID(for: asset.id), path: "assets/sticker/rocket-abc.mov", kind: .video, role: .sticker, duration: t(3), hasVideo: true, hasAlpha: true)
        let placement = try Self.placement(asset: asset, item: item)

        var project = Project.standard(name: "Assets")
        let fresh = AssetPlacing.commands(for: placement, at: t(12), in: project)
        XCTAssertEqual(fresh.count, 2, "adds the media, then places it")
        guard case .addMedia(let added) = fresh[0], case .placeMedia(let ids, let at, _, _, let mode, _, _, _) = fresh[1] else {
            return XCTFail("expected addMedia then placeMedia, got \(fresh)")
        }
        XCTAssertEqual(added.id, item.id)
        XCTAssertEqual(ids, [item.id])
        XCTAssertEqual(at, t(12))
        XCTAssertEqual(mode, .overwrite, "like dropping media: over whatever is there")

        // The folder watcher got there first, under its own ID.
        project.media = [MediaItem(id: "med_scanned", path: item.path, kind: .video, role: .sticker, duration: t(3), hasVideo: true)]
        let again = AssetPlacing.commands(for: placement, at: t(20), in: project)
        XCTAssertEqual(again.count, 1)
        guard case .placeMedia(let reused, _, _, _, _, _, _, _) = again[0] else { return XCTFail("expected placeMedia") }
        XCTAssertEqual(reused, ["med_scanned"])

        // Fonts and LUTs have nothing to place.
        let font = try Self.placement(asset: Asset(provider: "fontsource", providerID: "inter", kind: .font, name: "Inter"), item: nil)
        XCTAssertTrue(AssetPlacing.commands(for: font, at: t(1), in: project).isEmpty)
    }

    func testDragPayloadsRoundTrip() {
        let drags: [LibraryDrag] = [
            .media(["med_a", "med_b"]), .asset("iconify:mdi:rocket"), .transition(.cutSlide),
            .effect("vignette"), .title("callout"), .template("sectionCard")
        ]
        for drag in drags {
            XCTAssertEqual(LibraryDrag.parse(drag.payload), drag, drag.payload)
        }
        XCTAssertEqual(LibraryDrag.parse(MediaDrag.payload(["med_a"])), .media(["med_a"]), "the media browser's payload still works")
        XCTAssertNil(LibraryDrag.parse("tandem-transition:teleport"))
        XCTAssertNil(LibraryDrag.parse("tandem-asset:"))
        XCTAssertNil(LibraryDrag.parse("hello"))
    }

    func testWaveformStrips() {
        XCTAssertEqual(WaveformStrip.columns([0.1, 0.5, 0.2, 0.9], count: 2), [0.5, 0.9])
        XCTAssertEqual(WaveformStrip.columns([0.1, 0.5], count: 4), [0.1, 0.1, 0.5, 0.5])
        XCTAssertEqual(WaveformStrip.columns([], count: 3), [0, 0, 0])
        XCTAssertEqual(WaveformStrip.columns([2, -3], count: 2), [1, 1], "peaks are clamped to 0...1 by size")
        XCTAssertEqual(WaveformStrip.time(atFraction: 0.5, duration: 10), 5)
        XCTAssertEqual(WaveformStrip.time(atFraction: 1.4, duration: 10), 9.9, accuracy: 0.001, "stays inside the file")
        XCTAssertEqual(WaveformStrip.time(atFraction: -1, duration: 10), 0)
    }

    func testTransitionsUsedMost() throws {
        let fixture = try AppFixture()
        try fixture.blade(at: [10, 20, 30])
        let clips = fixture.clips("Camera")
        let track = fixture.track("Camera").id
        try fixture.coordinator.apply(EditBatch(label: "Transitions", commands: [
            .addTransition(trackID: track, transition: Transition(type: .push, duration: t(0.5), fromClipID: clips[0].id, toClipID: clips[1].id)),
            .addTransition(trackID: track, transition: Transition(type: .dissolve, duration: t(0.5), fromClipID: clips[1].id, toClipID: clips[2].id)),
            .addTransition(trackID: track, transition: Transition(type: .dissolve, duration: t(0.5), fromClipID: clips[2].id, toClipID: clips[3].id))
        ]))
        XCTAssertEqual(TransitionUse.mostUsed(in: fixture.project, limit: 6), [.dissolve, .push])
        XCTAssertEqual(TransitionUse.mostUsed(in: fixture.project, limit: 1), [.dissolve])
        XCTAssertTrue(TransitionUse.mostUsed(in: Project.standard(name: "Empty"), limit: 6).isEmpty)
    }

    // MARK: - Helpers

    private func info(_ id: String, _ name: String, _ kinds: [String], state: ProviderStatus.State = .ready) -> ProviderInfo {
        ProviderInfo(id: id, displayName: name, kinds: kinds, status: ProviderStatus(state), rules: ProviderRules(), capabilities: ProviderCapabilities(), website: nil)
    }

    static func placement(asset: Asset, item: MediaItem?) throws -> AssetPlacement {
        AssetPlacement(asset: asset, mediaItem: item, files: item.map { [$0.path] } ?? [], role: item?.role ?? .other, trackName: nil, audio: nil)
    }
}

final class SVGSizingTests: XCTestCase {
    func testRelativeSizesTakeTheViewBoxs() {
        let anthropic = ##"<svg fill="#000" viewBox="0 0 24 24" width="1em" xmlns="http://www.w3.org/2000/svg"><path d="M0 0h24v24z"/></svg>"##
        XCTAssertEqual(SVGSizing.sized(anthropic), ##"<svg fill="#000" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0 0h24v24z"/></svg>"##)
        // Absolute sizes are left alone, and so is anything without a viewBox.
        let fixed = ##"<svg width="256" height="128" viewBox="0 0 512 256"><g/></svg>"##
        XCTAssertEqual(SVGSizing.sized(fixed), fixed)
        let bare = ##"<svg width="100%"><g/></svg>"##
        XCTAssertEqual(SVGSizing.sized(bare), bare)
        // Only the root element changes.
        let nested = ##"<svg viewBox="0 0 10 5" height="1em"><svg width="1em"/></svg>"##
        XCTAssertEqual(SVGSizing.sized(nested), ##"<svg viewBox="0 0 10 5" width="10" height="5"><svg width="1em"/></svg>"##)
    }

    /// AppKit doesn't read four and eight digit hex colours (SVGL's white
    /// logos are `#ffff`), so they lose their alpha digits.
    func testColoursAppKitCanRead() {
        XCTAssertEqual(SVGSizing.readableColours(##"<path fill="#ffff"/><path stroke="#12345678"/>"##), ##"<path fill="#ffffff"/><path stroke="#123456"/>"##)
        let fine = ##"<path fill="#fff" stroke="#0a0b0c"/>"##
        XCTAssertEqual(SVGSizing.readableColours(fine), fine)
    }
}
