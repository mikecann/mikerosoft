import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

final class TranscriptToolsTests: XCTestCase {
    func testWordsMapThroughSourceStartAndSpeed() {
        let transcript = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "before", start: t(8), end: t(9)),
            TranscriptWord(text: "straddles", start: t(9.5), end: t(10.5)),
            TranscriptWord(text: "inside", start: t(12), end: t(13)),
            TranscriptWord(text: "after", start: t(21), end: t(22))
        ])
        // Plays file 10...20 at double speed, starting at 100 on the timeline.
        let clip = Clip(id: "clip_fast", content: .media(mediaID: "med_a"), start: t(100), duration: t(5), sourceStart: t(10), speed: 2)
        let track = Track(id: "trk_voice", kind: .audio, name: "Voice", clips: [clip], rippleMode: .cut)
        let words = TranscriptTools.words(transcript, playedBy: clip, on: track)
        XCTAssertEqual(words.map(\.text), ["straddles", "inside"], "half of \"straddles\" plays, so it stays")
        XCTAssertEqual(words[0].start, t(100), "clamped to the clip's start")
        XCTAssertEqual(words[0].end, t(100.25))
        XCTAssertEqual(words[1].start, t(101))
        XCTAssertEqual(words[1].end, t(101.5))
        XCTAssertEqual(TranscriptTools.timelineTime(ofMediaTime: t(20), in: clip), t(105))
    }

    func testTimelineTranscriptSkipsCutMaterial() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.transcript(id: nil, from: nil, to: nil)
        let text = result.words.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Second section. Now let's look"), text)
        XCTAssertFalse(text.contains("Um"), "file time 30-32 was cut out")
        let now = try XCTUnwrap(result.words.first { $0.text == "Now" })
        XCTAssertEqual(now.start, t(30.5))
        XCTAssertEqual(now.clipID, "clip_voc2")
        XCTAssertTrue(result.readableText.contains("00:30.500  Now let's look at decision models again."), result.readableText)
    }

    func testClipAndMediaTranscripts() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let clip = try h.service.transcript(id: "clip_voc2", from: nil, to: nil)
        XCTAssertTrue(clip.timelineTimes)
        XCTAssertEqual(clip.words.first?.text, "Now")
        let camera = try h.service.transcript(id: "clip_cam2", from: t(31), to: nil)
        XCTAssertEqual(camera.words.first?.text, "let's", "a camera clip plays the same words as its voice clip")
        let media = try h.service.transcript(id: "med_camera", from: t(30), to: t(32))
        XCTAssertFalse(media.timelineTimes)
        XCTAssertEqual(media.words.map(\.text), ["Um,", "wait."])
        assertServiceError(.unavailable) { _ = try h.service.transcript(id: "med_music", from: nil, to: nil) }
        assertServiceError(.invalid) { _ = try h.service.transcript(id: "clip_txt1", from: nil, to: nil) }
        assertServiceError(.notFound) { _ = try h.service.transcript(id: "clip_nope", from: nil, to: nil) }
    }

    func testSearchMapsHitsToTheTimeline() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.search(phrase: "decision models", limit: nil)
        XCTAssertEqual(result.hits.map(\.start), [t(2.55), t(7.55), t(31.65)])
        XCTAssertEqual(result.hits.map(\.end), [t(3.6), t(8.5), t(32.5)])
        XCTAssertEqual(Set(result.hits[2].clipIDs), ["clip_voc2", "clip_cam2"])
        XCTAssertEqual(result.hits[2].mediaStart, t(33.65))
        XCTAssertEqual(result.hits[0].after, "They help you choose")
        XCTAssertFalse(result.hits.contains(where: \.partial))
        XCTAssertTrue(result.unused.isEmpty)
    }

    func testSearchFindsMaterialThatWasCutOut() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.search(phrase: "um wait", limit: nil)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.unused.map(\.mediaStart), [t(30.5)])
        XCTAssertTrue(result.readableText.contains("In the source but not on the timeline"), result.readableText)
    }

    func testSearchMarksPhrasesACutRunsThrough() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // "section um" starts in the first piece and ends in the cut material.
        let result = try h.service.search(phrase: "Section. Um", limit: nil)
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertTrue(result.hits[0].partial)
        XCTAssertEqual(result.hits[0].start, t(29.45))
        XCTAssertEqual(result.hits[0].end, t(29.9), "the end of \"section.\", the last of its words that plays")
        XCTAssertEqual(Set(result.hits[0].clipIDs), ["clip_voc1", "clip_cam1"])
    }

    func testAWordACutRunsThroughIsSaidOnce() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // Cut 29.6-29.7 out of "section." (file 29.45-29.9): 0.15 s of it
        // before the cut, 0.2 s after.
        try h.apply(.rippleDeleteRange(range: TimeRange(start: t(29.6), end: t(29.7)), trackIDs: nil))
        let spoken = try h.service.transcript(id: nil, from: nil, to: nil).words
        XCTAssertEqual(spoken.filter { $0.text == "section." }.count, 1)
        let section = try XCTUnwrap(spoken.first { $0.text == "section." })
        XCTAssertEqual(section.start, t(29.6), "on the piece after the cut, where most of it plays")
        XCTAssertEqual(section.end, t(29.8))
        XCTAssertNotEqual(section.clipID, "clip_voc1")
        let captions = try h.service.captions(CaptionsRequest(), context: h.context)
        let text = captions.captions.map(\.text).joined(separator: " ")
        XCTAssertEqual(text.components(separatedBy: "section.").count - 1, 1, text)
        // Each clip's words in the dump show it once too.
        let dump = try h.service.timeline(from: t(25), to: t(35), format: .text, words: true).text ?? ""
        XCTAssertEqual(dump.components(separatedBy: "section.").count - 1, 1, dump)
        let search = try h.service.search(phrase: "second section", limit: nil)
        XCTAssertEqual(search.hits.count, 2, "\"second\" before the cut, \"section.\" after it")
        XCTAssertTrue(search.hits.allSatisfy(\.partial))
    }

    func testAWordMostlyCutOutIsGone() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // "decision" is file (and timeline) 2.55-3.0; cut 2.6-2.95 out of it.
        try h.apply(.rippleDeleteRange(range: TimeRange(start: t(2.6), end: t(2.95)), trackIDs: nil))
        let text = try h.service.transcript(id: nil, from: nil, to: t(10)).words.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.hasPrefix("So today we talk about models. They help you choose"), text)
        let clip = try h.service.transcript(id: "clip_voc1", from: nil, to: nil).words.map(\.text)
        XCTAssertFalse(clip.contains("decision"), "\(clip)")
    }

    /// The workbench short's numbers from end to end: "of" ran from 28.14
    /// to 29.22 over a silence from 28.26 to 29.05, "and" from 30.18 to
    /// 31.50 over one from 30.74 to 31.40. Trimmed to the voice, both pauses
    /// show, and a cut in the first one says "of" once.
    func testTheWorkbenchPausesAndTheCutAfterWorkbench() throws {
        var peaks = [Float](repeating: 0.001, count: 3500)
        for (start, end) in [(27.66, 28.26), (29.05, 30.74), (31.40, 31.68)] {
            for index in Int((start * 100).rounded())..<Int((end * 100).rounded()) { peaks[index] = 0.25 }
        }
        let raw = Transcript(language: "en-US", engine: "SpeechAnalyzer", words: [
            TranscriptWord(text: "a", start: t(27.48), end: t(27.66)),
            TranscriptWord(text: "workbench", start: t(27.66), end: t(28.14)),
            TranscriptWord(text: "of", start: t(28.14), end: t(29.22)),
            TranscriptWord(text: "this", start: t(29.22), end: t(29.40)),
            TranscriptWord(text: "size", start: t(29.40), end: t(30.18)),
            TranscriptWord(text: "and", start: t(30.18), end: t(31.50)),
            TranscriptWord(text: "then", start: t(31.50), end: t(31.68))
        ])
        var project = APIFixture.project()
        // The take from file 25 at the start of the timeline, uncut.
        project.videoTracks = project.videoTracks.map { track in
            var track = track
            if track.rippleMode == .cut { track.clips = [] }
            return track
        }
        project.audioTracks[0].clips = [
            Clip(id: "clip_voc", content: .media(mediaID: "med_camera"), start: t(0), duration: t(10), sourceStart: t(25))
        ]
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = raw
        XCTAssertTrue(try h.service.pauses(minimum: t(0.45), from: nil, to: nil).pauses.isEmpty, "the engine's times hide them")

        h.analysis.transcripts["med_camera"] = raw.aligned(to: Waveform(samplesPerSecond: 100, peaks: peaks))
        let pauses = try h.service.pauses(minimum: t(0.45), from: nil, to: nil).pauses
        XCTAssertEqual(pauses.map(\.start), [t(3.26), t(5.74)])
        XCTAssertEqual(pauses.map(\.end), [t(4.05), t(6.40)])
        XCTAssertEqual(pauses.map(\.before), ["a workbench", "of this size and"])

        // Cut file 28.35-28.95 (timeline 3.35-3.95), inside the first pause.
        try h.apply(.rippleDeleteRange(range: TimeRange(start: t(3.35), end: t(3.95)), trackIDs: nil))
        let text = try h.service.captions(CaptionsRequest(), context: h.context).captions.map(\.text).joined(separator: " ")
        XCTAssertEqual(text, "a workbench of this size and then")
    }

    func testSearchIgnoresCaseAndPunctuation() {
        let transcript = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "Don't", start: t(0), end: t(0.3)),
            TranscriptWord(text: "real-time", start: t(0.4), end: t(0.8)),
            TranscriptWord(text: "SYNC!", start: t(0.9), end: t(1.2))
        ])
        XCTAssertEqual(TranscriptTools.matches(of: "dont real time sync", in: transcript), [0...2])
        XCTAssertEqual(TranscriptTools.matches(of: "time sync", in: transcript), [1...2])
        XCTAssertEqual(TranscriptTools.matches(of: "sync now", in: transcript), [])
    }

    func testPausesInTimelineTime() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.pauses(minimum: t(0.6), from: nil, to: nil)
        XCTAssertEqual(result.pauses.map(\.start), [t(3.6), t(6.3), t(9), t(29.9)])
        XCTAssertEqual(result.pauses.map(\.end), [t(5), t(7), t(29), t(30.5)])
        XCTAssertEqual(result.pauses[0].before, "talk about decision models.")
        XCTAssertEqual(result.pauses[0].after, "They help you choose")
        XCTAssertEqual(result.pauses[3].clipIDs, ["clip_voc1", "clip_voc2"], "the pause runs across the cut")
        let longer = try h.service.pauses(minimum: t(1), from: nil, to: nil)
        XCTAssertEqual(longer.pauses.map(\.start), [t(3.6), t(9)])
        let ranged = try h.service.pauses(minimum: t(0.6), from: t(5), to: t(29.5))
        XCTAssertEqual(ranged.pauses.map(\.start), [t(6.3), t(9)])
    }

    func testPausesSkipHolesAndUntranscribedClips() throws {
        var project = APIFixture.project()
        // Lift the second voice piece's first 2 s: a hole in the take isn't a pause.
        project.audioTracks[0].clips[1].start = t(32)
        project.audioTracks[0].clips[1].duration = t(28)
        project.audioTracks[0].clips[1].sourceStart = t(34)
        let map = TranscriptTools.speechMap(project, analysis: FakeAnalysis())
        let pauses = TranscriptTools.pauses(in: map, minimum: t(0.6))
        XCTAssertFalse(pauses.contains { $0.start == t(29.9) })

        let noTranscripts = FakeAnalysis()
        noTranscripts.transcripts = [:]
        let empty = TranscriptTools.speechMap(APIFixture.project(), analysis: noTranscripts)
        XCTAssertEqual(empty.missing, ["med_camera"])
        XCTAssertTrue(TranscriptTools.pauses(in: empty, minimum: t(0.6)).isEmpty)
    }

    func testTightenPlanIsFrameAlignedAndKeepsTheSilence() {
        let pause = Pause(start: t(3.6), end: t(5), duration: t(1.4), before: "", after: "", clipIDs: [])
        let cuts = TranscriptTools.plan([pause], keep: t(0.15), frameRate: .fps30)
        XCTAssertEqual(cuts.count, 1)
        let cut = cuts[0].cut
        // 3.6 + 0.075 = 3.675, up to the next frame (3.7); 5 - 0.075 = 4.925, down to 4.9.
        XCTAssertEqual(cut.start, Time.frames(111, at: .fps30))
        XCTAssertEqual(cut.end, Time.frames(147, at: .fps30))
        XCTAssertGreaterThanOrEqual((pause.duration - cut.duration).seconds, 0.15)
        // A pause that would lose less than a frame is left alone.
        let tiny = Pause(start: t(1), end: t(1.2), duration: t(0.2), before: "", after: "", clipIDs: [])
        XCTAssertTrue(TranscriptTools.plan([tiny], keep: t(0.15), frameRate: .fps30).isEmpty)
    }

    func testTightenDryRunThenApplyThenUndo() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let plan = try h.service.tighten(TightenRequest(min: 0.6, keep: 0.15), context: h.context)
        XCTAssertEqual(plan.cuts.count, 4)
        XCTAssertNil(plan.applied)
        XCTAssertEqual(h.service.coordinator.project, before, "a dry run changes nothing")
        XCTAssertEqual(plan.commands.count, 4)
        guard case .rippleDeleteRange(let latest, nil) = plan.commands[0] else { return XCTFail("expected a ripple delete") }
        XCTAssertEqual(latest.start, plan.cuts.last?.cut.start, "latest cut first")
        XCTAssertEqual(plan.durationAfter, plan.durationBefore - plan.removed)

        let applied = try h.service.tighten(TightenRequest(min: 0.6, keep: 0.15, apply: true), context: h.context)
        XCTAssertEqual(applied.applied?.revision, 2)
        XCTAssertEqual(applied.applied?.label, "Tighten 4 pauses to 0.150s")
        XCTAssertEqual(h.service.coordinator.project.duration, plan.durationAfter)
        // The words still line up with the picture and every pause is now short.
        let after = try h.service.pauses(minimum: t(0.2), from: nil, to: nil)
        XCTAssertTrue(after.pauses.allSatisfy { $0.duration <= t(0.2) }, "\(after.pauses)")
        XCTAssertEqual(h.service.coordinator.project.markers.first?.time, t(30) - plan.cuts.prefix(3).reduce(Time.zero) { $0 + $1.cut.duration })
        _ = try h.service.undo(expectedRevision: nil)
        XCTAssertEqual(h.service.coordinator.project, before)
    }

    func testTightenRefusesToDesyncALockedTake() throws {
        var project = APIFixture.project()
        project.videoTracks[1].locked = true
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        let plan = try h.service.tighten(TightenRequest(), context: h.context)
        XCTAssertTrue(plan.warnings.contains { $0.contains("\"Camera\" is locked") }, "\(plan.warnings)")
        assertServiceError(.locked) { _ = try h.service.tighten(TightenRequest(apply: true), context: h.context) }
        assertServiceError(.badRequest) { _ = try h.service.tighten(TightenRequest(min: 0.5, keep: 0.5), context: h.context) }
    }
}

final class CaptionPlanningTests: XCTestCase {
    func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptTools.SpokenWord {
        TranscriptTools.SpokenWord(text: text, start: Time(seconds: start), end: Time(seconds: end), clipID: "clip_v", mediaID: "med_c", confidence: nil)
    }

    func testGroupsBreakAtWordCountSentencesAndPauses() {
        let words = [
            word("So", 0.00, 0.20), word("this", 0.22, 0.40), word("is", 0.42, 0.50), word("Convex.", 0.52, 1.00),
            word("It", 1.02, 1.10), word("syncs.", 1.12, 1.50),
            word("Later", 3.00, 3.40)
        ]
        let captions = TranscriptTools.captions(words, maxWords: 3, frameRate: .fps30)
        XCTAssertEqual(captions.map { $0.words.map(\.text).joined(separator: " ") }, ["So this is", "Convex.", "It syncs.", "Later"])
        for (a, b) in zip(captions, captions.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "captions overlap")
        }
        for caption in captions {
            XCTAssertEqual(caption.start.roundedToFrame(.fps30), caption.start)
            XCTAssertEqual(caption.end.roundedToFrame(.fps30), caption.end)
        }
        XCTAssertEqual(captions[3].end, Time(seconds: 3.6))
    }

    func testDuplicateVoiceTracksAreCaptionedOnce() {
        let words = [word("Hello", 0, 0.5), word("Hello", 0, 0.5), word("there", 0.6, 0.9), word("there", 0.6, 0.9)]
        let captions = TranscriptTools.captions(words, maxWords: 3, frameRate: .fps30)
        XCTAssertEqual(captions.map { $0.words.count }, [2])
    }
}

final class ShortLayoutTests: XCTestCase {
    func testCameraGoesToTheBottomUnlessItsFullFrame() {
        var pip = Clip(content: .media(mediaID: "med_c"), start: .zero, duration: Time(seconds: 2))
        pip.video = LayoutPreset.pipRight.apply(to: nil, role: .camera, shadowID: "fx_s")
        var full = pip
        full.video = LayoutPreset.full.apply(to: pip.video, role: .camera, shadowID: "fx_s")
        XCTAssertEqual(TandemService.portraitSlot(for: pip, role: .camera), .bottom)
        XCTAssertEqual(TandemService.portraitSlot(for: full, role: .camera), .full)
        XCTAssertEqual(TandemService.portraitSlot(for: pip, role: .screen), .top)
    }
}
