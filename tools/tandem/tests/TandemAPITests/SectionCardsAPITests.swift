import Foundation
import XCTest
@testable import TandemAPI
import TandemAssets
@testable import TandemCore

/// A library in a temp folder holding the two section card whooshes under
/// their real IDs, or none.
enum CardSoundsFixture {
    static func library(at root: URL, withSounds: Bool = true) throws -> AssetLibrary {
        let library = try AssetLibrary(root: root, previewFolder: root.appendingPathComponent("previews"), transport: OfflineTransport(), secrets: StaticSecretStore())
        guard withSounds else { return library }
        for (sound, seconds) in [(SectionCardSounds.whooshIn, 1.2), (SectionCardSounds.whooshOut, 1.0)] {
            let parts = sound.assetID.split(separator: ":", maxSplits: 1).map(String.init)
            var asset = Asset(provider: parts[0], providerID: parts[1], kind: .sfx, name: "Whoosh", duration: seconds)
            try AssetFixtures.wav(at: library.folder(for: asset).appendingPathComponent("original.wav"), seconds: seconds)
            asset.state = .normalised
            asset.files = AssetFiles(original: "original.wav")
            try library.catalog.upsert(asset)
        }
        return library
    }
}

/// `cards`: a section card at every section marker, from the service, the
/// CLI and the timeline dump.
final class SectionCardsAPITests: XCTestCase {
    /// The fixture (Section 2 at 30) plus the cold open at 0 and
    /// Methodology at 8, with a note.
    static func project() -> Project {
        var project = APIFixture.project()
        project.markers += [
            Marker(id: "mk_open", time: .zero, name: "Cold open", kind: .section),
            Marker(id: "mk_method", time: t(8), name: "Methodology", kind: .section, note: "Let's keep it fair")
        ]
        project.markers.sort { $0.time < $1.time }
        return project
    }

    func cards(_ project: Project) -> [(clip: Clip, props: SectionCard.Props)] {
        project.videoTracks.flatMap(\.clips).compactMap { clip in SectionCard.props(of: clip).map { (clip, $0) } }.sorted { $0.clip.start < $1.clip.start }
    }

    func testDryRunThenApplyWithTheWhooshes() async throws {
        let folder = TempFolder("tandem-cards")
        let h = try ServiceHarness(project: Self.project())
        defer { h.close() }
        h.service.soundLibrary = try CardSoundsFixture.library(at: folder.url.appendingPathComponent("library"))
        let sfx = h.url.deletingLastPathComponent().appendingPathComponent("assets/sfx")

        let plan = try await h.service.cards(CardsRequest(), context: h.context)
        XCTAssertNil(plan.applied)
        XCTAssertEqual(plan.cards.map(\.number), ["01", "02"])
        XCTAssertEqual(plan.cards.map(\.title), ["Methodology", "Section 2"])
        XCTAssertEqual(plan.cards.first?.subtitle, "Let's keep it fair")
        XCTAssertTrue(plan.sounds.hasPrefix("a whoosh on each sweep"), plan.sounds)
        XCTAssertEqual(h.service.coordinator.revision, 1, "a dry run changes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sfx.path), "or copies anything")
        let text = plan.readableText
        XCTAssertTrue(text.hasPrefix("2 section cards (dry run, revision 1):"), text)
        XCTAssertTrue(text.contains(#"01  00:08.000  "Methodology" / "Let's keep it fair"  card 00:07.567-00:10.767"#), text)
        XCTAssertTrue(text.contains("Run again with --apply"), text)

        let applied = try await h.service.cards(CardsRequest(kicker: "Section", apply: true), context: h.context)
        XCTAssertEqual(applied.applied?.revision, 2)
        XCTAssertEqual(applied.applied?.label, "Add 2 section cards")
        let project = h.service.coordinator.project
        let made = cards(project)
        XCTAssertEqual(made.map(\.props.label), ["01 Methodology", "02 Section 2"])
        XCTAssertEqual(made.map(\.props.kickerLine), ["Section 1 of 2", "Section 2 of 2"])
        let sounds = project.track(named: "SFX")?.clips ?? []
        XCTAssertEqual(sounds.count, 4, "a whoosh in and out for each card")
        XCTAssertEqual(Set(sounds.compactMap(\.linkGroup)), Set(made.compactMap(\.clip.linkGroup)))
        let media = project.media.filter { $0.path.hasPrefix("assets/sfx/") }
        XCTAssertEqual(media.count, 2)
        for item in media {
            XCTAssertTrue(FileManager.default.fileExists(atPath: h.url.deletingLastPathComponent().appendingPathComponent(item.path).path), item.path)
        }
        XCTAssertEqual(Set(sounds.compactMap(\.audio?.gainDB)), [SectionCardSounds.whooshIn.gainDB, SectionCardSounds.whooshOut.gainDB])

        // Running it again renumbers what's there, and adds nothing.
        let again = try await h.service.cards(CardsRequest(apply: true), context: h.context)
        XCTAssertEqual(again.cards.compactMap(\.existingClipID).count, 2)
        XCTAssertEqual(again.sounds, "the cards there keep their sounds")
        XCTAssertEqual(cards(h.service.coordinator.project).count, 2)
        XCTAssertEqual(h.service.coordinator.project.track(named: "SFX")?.clips.count, 4)
        XCTAssertTrue(again.readableText.contains("already there, renumbered"), again.readableText)
    }

    func testSilentWithoutTheWhooshes() async throws {
        let folder = TempFolder("tandem-cards")
        let h = try ServiceHarness(project: Self.project())
        defer { h.close() }
        h.service.soundLibrary = try CardSoundsFixture.library(at: folder.url.appendingPathComponent("library"), withSounds: false)
        let dry = try await h.service.cards(CardsRequest(), context: h.context)
        XCTAssertTrue(dry.sounds.hasPrefix("silent"), dry.sounds)
        let applied = try await h.service.cards(CardsRequest(apply: true), context: h.context)
        XCTAssertTrue(applied.sounds.hasPrefix("silent"), applied.sounds)
        XCTAssertEqual(cards(h.service.coordinator.project).count, 2)
        XCTAssertEqual(h.service.coordinator.project.track(named: "SFX")?.clips.count, 0)
        // And none asked for.
        let quiet = try await h.service.cards(CardsRequest(markers: ["mk_s2"], sounds: false), context: h.context)
        XCTAssertEqual(quiet.sounds, "no sounds (asked for none)")
    }

    func testMistakesComeBackAsServiceErrors() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        do {
            _ = try await h.service.cards(CardsRequest(markers: ["mk_nope"]), context: h.context)
            XCTFail("unknown marker")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
        }
        do {
            _ = try await h.service.cards(CardsRequest(expectedRevision: 7), context: h.context)
            XCTFail("stale")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "staleRevision")
        }
    }

    func testRequestsReadFriendlyForms() throws {
        let request = try ServiceJSON.decodeRequest(CardsRequest.self, from: Data(#"{"markers": ["mk_a"], "duration": "0:04", "kicker": "Tip", "insert": true, "sounds": false, "apply": true}"#.utf8))
        XCTAssertEqual(request.markers, ["mk_a"])
        XCTAssertEqual(request.duration, t(4))
        XCTAssertEqual(request.kicker, "Tip")
        XCTAssertEqual(request.insert, true)
        XCTAssertEqual(request.sounds, false)
        XCTAssertTrue(request.changesProject)
        XCTAssertFalse(CardsRequest().changesProject)
        XCTAssertTrue(ServiceOperation.cards.edits)
        XCTAssertNotNil(MCPTools.named("cards"))
    }

    func testTheTimelineDumpNamesTheCards() throws {
        let h = try ServiceHarness(project: Self.project())
        defer { h.close() }
        try h.apply(.addSectionCards(kicker: "Section"))
        let dump = TimelineDump.render(h.service.coordinator.project, revision: 1)
        XCTAssertTrue(dump.contains(#"section card 01 "Methodology" / "Let's keep it fair" 1 of 2 kicker Section"#), dump)
    }

    func testTheCLIPlansThenAddsThem() async throws {
        let cli = CLITests()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let folder = TempFolder("tandem-cards-cli")
        let root = folder.url.appendingPathComponent("library", isDirectory: true)
        _ = try CardSoundsFixture.library(at: root)
        let env = ["TANDEM_ASSETS_ROOT": root.path, "TANDEM_ASSETS_OFFLINE": "1"]
        let video = folder.url.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        let projectURL = try APIFixture.write(to: video, project: Self.project())

        let plan = try cli.tandem("cards", in: video, env: env)
        XCTAssertEqual(plan.status, 0, plan.stderr)
        XCTAssertTrue(plan.stdout.hasPrefix("2 section cards (dry run, revision 1):"), plan.stdout)
        XCTAssertEqual(cards(try ProjectFile.load(from: projectURL).project).count, 0)

        let applied = try cli.tandem("cards", "--kicker", "Tip", "--apply", "--author", "claude", in: video, env: env)
        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertTrue(applied.stdout.contains("Sound: a whoosh on each sweep"), applied.stdout)
        let project = try ProjectFile.load(from: projectURL).project
        XCTAssertEqual(cards(project).map(\.props.kickerLine), ["Tip 1 of 2", "Tip 2 of 2"])
        XCTAssertEqual(project.track(named: "SFX")?.clips.count, 4)
        let history = try cli.tandem("history", in: video)
        XCTAssertTrue(history.stdout.contains("Add 2 section cards  (claude)"), history.stdout)

        let usage = try cli.tandem("cards", "--insert", "--bogus", in: video, env: env)
        XCTAssertEqual(usage.status, 2, "a usage mistake")
    }
}
