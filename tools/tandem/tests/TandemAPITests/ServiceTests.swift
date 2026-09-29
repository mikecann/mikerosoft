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

    func testIdempotencyKeysHoldBetweenTheAppAndTheCLI() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        func hosted<R>(_ body: (TandemService) throws -> R) throws -> R {
            let session = try ProjectSession.open(url, owner: .app)
            let service = TandemService(session: session, mode: .hosted, analysis: FakeAnalysis(), renderer: FakeRenderer())
            defer {
                service.shutdown()
                session.close()
            }
            return try body(service)
        }
        // Applied through the app, which quits before the agent hears back;
        // the agent's retry reaches the CLI.
        let cut = ApplyRequest(label: "Cut", commands: [.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false)], idempotencyKey: "move-broll")
        let first = try hosted { try $0.apply(cut, context: CallContext()) }
        let retried = try headless(url) { try $0.apply(cut, context: CallContext()) }
        XCTAssertTrue(retried.repeated)
        XCTAssertEqual(retried.revision, first.revision)
        // And the other way round.
        let again = ApplyRequest(label: "Again", commands: [.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false)], idempotencyKey: "move-broll-2")
        _ = try headless(url) { try $0.apply(again, context: CallContext()) }
        XCTAssertTrue(try hosted { try $0.apply(again, context: CallContext()) }.repeated)
        XCTAssertEqual(try ProjectFile.load(from: url).project.clip("clip_brl1")?.start, t(22), "each move once")
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
        XCTAssertEqual(result.speechLoudness, -20)
        let voice = try XCTUnwrap(result.clips.first { $0.clipID == "clip_voc1" })
        XCTAssertEqual(voice.normalizeGainDB ?? 0, 7.5, accuracy: 1e-9)
        XCTAssertTrue(voice.speech)
        XCTAssertEqual(result.clips.first { $0.clipID == "clip_mus1" }?.speech, false)
        XCTAssertEqual(result.media.first { $0.mediaID == "med_music" }?.state, "none")
        // The fixture's voice is on the old -14 default, not the speech level.
        XCTAssertTrue(result.readableText.contains("2 of 2 speech clips aren't at the speech level"), result.readableText)

        // The same sum the render makes: at most 30 dB, nothing for silence.
        h.analysis.measured["med_camera"] = Loudness(integratedLUFS: -60, truePeakDBTP: -40, loudnessRange: 6)
        XCTAssertEqual(try h.service.loudness(mediaID: "med_camera").clips.first?.normalizeGainDB, 30)
        h.analysis.measured["med_camera"] = Loudness(integratedLUFS: -.infinity, truePeakDBTP: -.infinity, loudnessRange: 0)
        XCTAssertEqual(try h.service.loudness(mediaID: "med_camera").clips.first?.normalizeGainDB, 0)
    }

    func testNormalizeSpeechFromJSONLevelsTheVoiceAndLeavesTheMusic() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let command = try CommandJSON.decode(try json(#"{"normalizeSpeech": {}}"#))
        XCTAssertEqual(command, .normalizeSpeech)
        let result = try h.apply(command)
        XCTAssertEqual(result.label, "Normalise speech clips")
        XCTAssertEqual(Set(result.changed), ["clip_voc1", "clip_voc2"])
        let project = h.service.coordinator.project
        XCTAssertEqual(project.clip("clip_voc1")?.audio?.normalizeTo, -20)
        XCTAssertEqual(project.clip("clip_mus1")?.audio?.gainDB, -31)

        // Changing the speech level moves them.
        let moved = try h.apply(.updateSettings(patch: .object(["speechLoudness": .number(-18)])))
        XCTAssertEqual(Set(moved.changed), ["clip_voc1", "clip_voc2"])
        XCTAssertEqual(h.service.coordinator.project.clip("clip_voc2")?.audio?.normalizeTo, -18)
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

    func testFramesAndScreenshotsNeverOverwriteTheProjectOrItsMedia() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.service.screenshotProvider = { FakeRenderer.png }
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        let take = h.folder.file("source/take1-camera.mov")
        try Data("camera take".utf8).write(to: take)
        let projectBytes = try Data(contentsOf: h.url)

        for output in ["source/take1-camera.mov", h.folder.file("source/take1-camera.mov").path, "Decision Models.tandem", "Other version.tandem"] {
            do {
                _ = try await FrameRequest(time: t(12), output: output).run(on: h.service, context: h.context)
                XCTFail("a frame shouldn't be written to \(output)")
            } catch {
                XCTAssertEqual((error as? ServiceError)?.code, "invalid", "\(error)")
            }
            do {
                _ = try await ScreenshotRequest(output: output).run(on: h.service, context: h.context)
                XCTFail("a screenshot shouldn't be written to \(output)")
            } catch {
                XCTAssertEqual((error as? ServiceError)?.code, "invalid", "\(error)")
            }
        }
        // Exports and review clips say so before they start, whatever renders them.
        assertServiceError(.invalid) { _ = try h.service.prepareExport(ExportRequest(output: "source/take1-camera.mov")) }
        assertServiceError(.invalid) { _ = try h.service.prepareClip(ClipRequest(start: t(0), end: t(1), output: take.path)) }
        XCTAssertEqual(try Data(contentsOf: take), Data("camera take".utf8))
        XCTAssertEqual(try Data(contentsOf: h.url), projectBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.folder.file("Other version.tandem").path))
        // Anywhere else is fine, including over an earlier frame.
        _ = try await FrameRequest(time: t(12), output: "frames/f.png").run(on: h.service, context: h.context)
        _ = try await FrameRequest(time: t(13), output: "frames/f.png").run(on: h.service, context: h.context)
    }

    func testRenderWarningsAreTheOnesThatMatterHere() async throws {
        // The renderer warns about the whole project; a frame keeps the lines
        // about what plays at its time, once each.
        let warnings = [
            "No cutout matte for source/take1-camera.mov yet, showing the full frame.",
            "No loudness measurement for music/bed.m4a yet, so it isn't normalised.",
            "No cutout matte for source/take1-camera.mov yet, showing the full frame.",
            "Couldn't place servers.mp4 for clip clip_brl1: gone",
            "Graphic clips aren't rendered yet (remotion:BarChart)."
        ]
        let h = try ServiceHarness(renderer: FakeRenderer(warnings: warnings))
        defer { h.close() }
        let early = try await FrameRequest(time: t(2)).run(on: h.service, context: h.context)
        XCTAssertEqual(early.warnings, [
            "No cutout matte for source/take1-camera.mov yet, showing the full frame.",
            "No loudness measurement for music/bed.m4a yet, so it isn't normalised.",
            "Graphic clips aren't rendered yet (remotion:BarChart)."
        ], "the B-roll clip at 20 s doesn't play at 2 s")
        let broll = try await FrameRequest(time: t(21)).run(on: h.service, context: h.context)
        XCTAssertTrue(broll.warnings.contains("Couldn't place servers.mp4 for clip clip_brl1: gone"))
        XCTAssertTrue(broll.readableText.contains("\nWarning: No cutout matte for source/take1-camera.mov yet, showing the full frame."), broll.readableText)
        let clip = try await ClipRequest(start: t(0), end: t(10)).run(on: h.service, context: h.context)
        XCTAssertEqual(clip.warnings.count, 3)
        let whole = try await ExportRequest(preset: "review").run(on: h.service, context: h.context)
        XCTAssertEqual(whole.warnings.count, 4, "no range: every line, once")
        XCTAssertTrue(whole.readableText.contains("Warning: Couldn't place servers.mp4"), whole.readableText)
        // Old results without warnings still decode.
        let old = try ServiceJSON.decoder().decode(ImageResult.self, from: Data(#"{"bytes": 3, "path": "/x.png"}"#.utf8))
        XCTAssertEqual(old.warnings, [])
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

    func testJobUpdatesReachWatchers() async throws {
        let h = try ServiceHarness()
        let events = h.service.events.subscribe()
        let job = JobStatus(id: "job_1", kind: .transcript, mediaID: "med_camera", state: .running, progress: 0.4)
        h.analysis.emit([job])
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.kind, .jobs)
        XCTAssertEqual(event?.jobs, [job])
        XCTAssertEqual(h.service.status().jobs, [job])
        XCTAssertTrue(h.service.status().readableText.contains("transcript med_camera running 40%"))
        let media = try await h.service.media(refresh: false)
        XCTAssertEqual(media.items.first { $0.id == "med_camera" }?.analysis["transcript"]?.state, "ready", "a cached result wins over a job")
        h.close()
        h.analysis.emit([])
        let after = await iterator.next()
        XCTAssertNil(after, "shutting down ends the stream")
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
