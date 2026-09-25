import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

final class ServiceTests: XCTestCase {
    func testStatusDescribesTheProject() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let status = h.service.status()
        XCTAssertEqual(status.name, "Decision Models")
        XCTAssertEqual(status.revision, 1)
        XCTAssertEqual(status.duration, t(60))
        XCTAssertEqual(status.tracks, 8)
        XCTAssertEqual(status.clips, 9)
        XCTAssertEqual(status.media, 4)
        XCTAssertFalse(status.dirty)
        XCTAssertFalse(status.headless)
        XCTAssertEqual(status.openIn?.owner, "cli")
        XCTAssertEqual(status.openIn?.pid, getpid())
        XCTAssertTrue(status.readableText.contains("revision 1, saved, 01:00.000 long"), status.readableText)
    }

    func testApplyCreditsTheCallerAndReportsWhatChanged() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.apply(.blade(at: t(10)))
        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(result.author, "claude")
        XCTAssertEqual(result.label, "Cut at 00:10.000")
        XCTAssertEqual(result.added.count, 4, "the right-hand pieces of screen, camera, voice and music")
        XCTAssertEqual(Set(result.changed), ["clip_scr1", "clip_cam1", "clip_voc1", "clip_mus1"])
        XCTAssertEqual(result.createdIDs.count, result.added.count)
        XCTAssertEqual(h.service.coordinator.undoLabel, "Cut at 00:10.000")
        XCTAssertTrue(result.readableText.hasPrefix("Applied \"Cut at 00:10.000\" by claude as revision 2."), result.readableText)
    }

    func testDryRunChangesNothing() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let result = try h.service.apply(ApplyRequest(commands: [.rippleDeleteRange(range: TimeRange(start: t(3.7), end: t(4.9)))], dryRun: true), context: h.context)
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.revision, 1)
        XCTAssertEqual(result.duration, t(58.8))
        XCTAssertEqual(h.service.coordinator.project, before)
        XCTAssertEqual(h.service.coordinator.revision, 1)
    }

    func testStaleRevisionIsAServiceError() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.blade(at: t(10)))
        assertServiceError(.staleRevision) {
            _ = try h.service.apply(ApplyRequest(commands: [.blade(at: t(20))], expectedRevision: 1), context: h.context)
        }
    }

    func testFailedEditKeepsEditErrorWording() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        XCTAssertThrowsError(try h.apply(.removeClips(clipIDs: ["clip_nope"]))) { error in
            let service = error as? ServiceError
            XCTAssertEqual(service?.code, "notFound")
            XCTAssertEqual(service?.message, "Not found: clip clip_nope")
        }
    }

    func testUndoAndRedoInMemory() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let before = h.service.coordinator.project
        try h.apply(.blade(at: t(10)), label: "Cut")
        let undone = try h.service.undo(expectedRevision: 2)
        XCTAssertEqual(undone.label, "Cut")
        XCTAssertEqual(undone.revision, 3)
        XCTAssertEqual(h.service.coordinator.project, before)
        let redone = try h.service.redo(expectedRevision: nil)
        XCTAssertEqual(redone.label, "Cut")
        assertServiceError(.nothingToRedo) { _ = try h.service.redo(expectedRevision: nil) }
        assertServiceError(.staleRevision) { _ = try h.service.undo(expectedRevision: 1) }
    }

    func testHeadlessUndoWorksAcrossSessions() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let original = try ProjectFile.load(from: url).project

        try headless(url) { service in
            _ = try service.apply(ApplyRequest(label: "Cut", commands: [.blade(at: t(10))]), context: CallContext(author: "claude"))
        }
        try headless(url) { service in
            _ = try service.apply(ApplyRequest(label: "Marker", commands: [.addMarker(marker: Marker(id: "mk_new", time: t(5), name: "New"))]), context: CallContext(author: "codex"))
        }
        let history = try headless(url) { $0.history(limit: 10) }
        XCTAssertEqual(history.undo.map(\.label), ["Marker", "Cut"])
        XCTAssertEqual(history.undo.map(\.author), ["codex", "claude"])

        let first = try headless(url) { try $0.undo(expectedRevision: nil) }
        XCTAssertEqual(first.label, "Marker")
        XCTAssertEqual(try ProjectFile.load(from: url).project.markers.map(\.id), ["mk_s2"])
        let second = try headless(url) { try $0.undo(expectedRevision: nil) }
        XCTAssertEqual(second.label, "Cut")
        XCTAssertEqual(try ProjectFile.load(from: url).project, original)
        try headless(url) { service in
            XCTAssertThrowsError(try service.undo(expectedRevision: nil))
        }
        let redone = try headless(url) { try $0.redo(expectedRevision: nil) }
        XCTAssertEqual(redone.label, "Cut")
        XCTAssertEqual(try ProjectFile.load(from: url).project.track(named: "Camera")?.clips.count, 3)
    }

    func testHeadlessHistoryGoesStaleWhenTheProjectMovesOn() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        try headless(url) { service in
            _ = try service.apply(ApplyRequest(label: "Cut", commands: [.blade(at: t(10))]), context: CallContext(author: "claude"))
        }
        // An edit made somewhere that doesn't record headless history (the app).
        let session = try ProjectSession.open(url, owner: .app)
        try session.coordinator.apply(EditBatch(label: "Mike's edit", commands: [.blade(at: t(20))]))
        session.close()
        try headless(url) { service in
            assertServiceError(.nothingToUndo) { _ = try service.undo(expectedRevision: nil) }
        }
    }

    func testHeadlessIdempotencySurvivesReopening() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let request = ApplyRequest(label: "Cut", commands: [.blade(at: t(10))], idempotencyKey: "cut-10")
        let first = try headless(url) { try $0.apply(request, context: CallContext()) }
        let second = try headless(url) { try $0.apply(request, context: CallContext()) }
        XCTAssertFalse(first.repeated)
        XCTAssertTrue(second.repeated)
        XCTAssertEqual(second.revision, first.revision)
        XCTAssertEqual(try ProjectFile.load(from: url).project.track(named: "Camera")?.clips.count, 3)
    }

    func testValidateReportsMissingFiles() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.folder.file("music"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: h.folder.file("music/bed.m4a").path, contents: Data())
        let result = h.service.validate()
        XCTAssertFalse(result.ok)
        let missing = result.issues.filter { $0.message.contains("is missing") }
        XCTAssertEqual(Set(missing.compactMap(\.objectID)), ["med_camera", "med_screen", "med_broll"])
    }

    func testMediaListsUsageAndAnalysis() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try await h.service.media(refresh: false)
        let camera = try XCTUnwrap(result.items.first { $0.id == "med_camera" })
        XCTAssertEqual(camera.clips, 4)
        XCTAssertFalse(camera.exists)
        XCTAssertEqual(camera.analysis["transcript"]?.state, "ready")
        XCTAssertEqual(camera.analysis["matte"]?.state, "none")
        XCTAssertNil(result.items.first { $0.id == "med_music" }?.analysis["matte"])
    }

    func testLoudnessShowsTheLevellingGain() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.measured["med_camera"] = Loudness(integratedLUFS: -21.5, truePeakDBTP: -3, loudnessRange: 6)
        let result = try h.service.loudness(mediaID: nil)
        XCTAssertEqual(result.target, -14)
        let voice = try XCTUnwrap(result.clips.first { $0.clipID == "clip_voc1" })
        XCTAssertEqual(voice.normalizeGainDB ?? 0, 7.5, accuracy: 1e-9)
        XCTAssertEqual(result.media.first { $0.mediaID == "med_music" }?.state, "none")
    }

    func testTimelineJSONFiltersToTheRange() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.timeline(from: t(21), to: t(24), format: .json, words: false)
        let project = try XCTUnwrap(result.project)
        XCTAssertEqual(project.track(named: "B-roll")?.clips.map(\.id), ["clip_brl1"])
        XCTAssertEqual(project.track(named: "Camera")?.clips.map(\.id), ["clip_cam1"])
        XCTAssertEqual(project.track(named: "Camera")?.transitions, [], "the dissolve needs clip_cam2, which is outside")
        XCTAssertEqual(project.track(named: "Text")?.clips, [])
        XCTAssertEqual(project.markers, [])
    }

    func testFrameWritesAFileOrReturnsBase64() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let inline = try await FrameRequest(time: t(12)).run(on: h.service, context: h.context)
        XCTAssertEqual(inline.png, FakeRenderer.png.base64EncodedString())
        XCTAssertNil(inline.path)
        let written = try await FrameRequest(time: t(12), output: "frames/f.png").run(on: h.service, context: h.context)
        XCTAssertEqual(written.path, h.folder.file("frames/f.png").standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: h.folder.file("frames/f.png")), FakeRenderer.png)
    }

    func testExportReportsProgressAndResult() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let events = h.service.events.subscribe()
        let outcome = try await ExportRequest(preset: "review", from: t(10), to: t(20)).run(on: h.service, context: h.context)
        XCTAssertEqual(outcome.preset, "Review 720p")
        XCTAssertEqual(outcome.duration, t(10))
        XCTAssertTrue(outcome.path.hasSuffix("exports/Decision Models r1.mp4"), outcome.path)
        var seen: [ExportJob] = []
        for await event in events {
            if let job = event.export { seen.append(job) }
            if event.export?.state == .done { break }
        }
        XCTAssertEqual(seen.first?.state, .running)
        XCTAssertEqual(seen.last?.progress, 1)
        XCTAssertTrue(h.service.status().exports.isEmpty)
        assertServiceError(.notFound) { _ = try h.service.prepareExport(ExportRequest(preset: "vhs")) }
    }

    func testClipUsesTheReviewPresetAndItsRange() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let outcome = try await ClipRequest(start: t(5), end: t(7.5)).run(on: h.service, context: h.context)
        XCTAssertEqual(outcome.duration, t(2.5))
        XCTAssertTrue(outcome.path.hasSuffix("exports/review 00.05.000-00.07.500.mp4"), outcome.path)
    }

    func testWatchWaitsForTheNextChange() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let quiet = await h.service.watch(after: nil, timeout: 0.05)
        XCTAssertFalse(quiet.changed)
        let service = h.service
        let waiter = Task { await service.watch(after: 1, timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try h.apply(.blade(at: t(10)), label: "Cut")
        let result = await waiter.value
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(result.events.map(\.label), ["Cut"])
        // Already past the revision: returns at once.
        let immediate = await h.service.watch(after: 1, timeout: 5)
        XCTAssertTrue(immediate.changed)
    }

    func testScreenshotNeedsTheApp() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        do {
            _ = try await h.service.screenshot(output: nil)
            XCTFail("expected an error")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "unavailable")
        }
        h.service.screenshotProvider = { FakeRenderer.png }
        let shot = try await h.service.screenshot(output: nil)
        XCTAssertEqual(shot.bytes, FakeRenderer.png.count)
    }

    func testEffectsCatalogue() throws {
        let all = try EffectsResult.catalog()
        XCTAssertTrue(all.effects.contains { $0.type == "dropShadow" })
        XCTAssertEqual(all.layouts.map(\.preset), LayoutPreset.allCases)
        XCTAssertEqual(try EffectsResult.catalog(type: "BLUR").effects.map(\.type), ["blur"])
        assertServiceError(.notFound) { _ = try EffectsResult.catalog(type: "glitter") }
    }

    func testGenericHandlerDecodesAndEncodesJSON() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let body = Data(#"{"commands": [{"blade": {"at": "00:10.000"}}], "label": "Cut"}"#.utf8)
        let data = try await h.service.handle(.apply, body: body, context: h.context)
        let result = try ServiceJSON.decoder().decode(ApplyResult.self, from: data)
        XCTAssertEqual(result.label, "Cut")
        do {
            _ = try await h.service.handle(.apply, body: Data(#"{"commands": [{"blade": {"att": 10}}]}"#.utf8), context: h.context)
            XCTFail("expected an error")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "badRequest")
            XCTAssertTrue(error.message.contains("commands[0].blade: unknown field \"att\" (did you mean \"at\"?)"), error.message)
        }
    }
}
