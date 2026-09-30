import XCTest
@testable import TandemCore

/// What the review layer takes from an agent's batch: the clips it added
/// and changed, by ID, and the places it took something out, but not the
/// clips that only rode along with a ripple.
final class ReviewDiffTests: XCTestCase {
    /// Runs a batch as Claude and returns what it did.
    private func agent(_ coordinator: ProjectCoordinator, _ commands: [EditCommand]) throws -> ReviewChanges {
        let before = coordinator.project
        try coordinator.apply(EditBatch(label: "Agent edit", author: "claude", commands: commands))
        return ReviewDiff.between(before, coordinator.project)
    }

    func testPlacedBRollIsAddedAndNothingElse() throws {
        let (_, c) = try Fixture.edited()
        let changes = try agent(c, [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        let shot = try XCTUnwrap(c.clips("B-roll").first { $0.start == t(40) })
        XCTAssertEqual(changes.added, [shot.id])
        XCTAssertEqual(changes.changed, [])
        XCTAssertEqual(changes.removals, [])
    }

    func testAChangedClipIsFound() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0]
        let changes = try agent(c, [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])]))])
        XCTAssertEqual(changes.changed, [music.id])
        XCTAssertEqual(changes.added, [])
        XCTAssertNotNil(changes.before[music.id], "what it was, to spot an undo")
    }

    /// Tightening a pause cuts the take and moves everything after it up.
    /// Only the join is news: not the halves of the cut clips, the B-roll
    /// that moved with its words, or the music bed that lost a second from
    /// its end.
    func testARippleDeleteMarksTheJoinAndNothingThatMoved() throws {
        let (f, c) = try Fixture.edited()
        let changes = try agent(c, [.rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.changed, [])
        XCTAssertEqual(Set(changes.removals.map(\.trackID)), Set(["Screen", "Camera", "Voice"].map { f.track($0).id }))
        for removal in changes.removals {
            XCTAssertEqual(removal.time, t(10))
            XCTAssertEqual(removal.duration, t(1))
            // Pinned to the clip after the join: the cut clip's right half.
            let anchor = try XCTUnwrap(c.project.clip(try XCTUnwrap(removal.anchorClipID)))
            XCTAssertEqual(anchor.start, t(10))
            XCTAssertEqual(removal.anchorEdge, .start)
            XCTAssertEqual(removal.offset, .zero)
        }
    }

    /// `tandem tighten` cuts several pauses in one batch, latest first:
    /// a mark at each join, where it is after all of them, and still
    /// nothing that only moved, not even the B-roll one of the pauses ran
    /// through.
    func testTighteningSeveralPausesMarksEachJoin() throws {
        let (f, c) = try Fixture.edited()
        let changes = try agent(c, [
            .rippleDeleteRange(range: TimeRange(start: t(40), end: t(41))),
            .rippleDeleteRange(range: TimeRange(start: t(20), end: t(20.5))),
            .rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))
        ])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.changed, [])
        let screen = changes.removals.filter { $0.trackID == f.track("Screen").id }
        XCTAssertEqual(screen.map(\.time), [t(10), t(19), t(38.5)])
        XCTAssertEqual(screen.map(\.duration), [t(1), t(0.5), t(1)])
        XCTAssertEqual(changes.removals.count, 9, "the three take tracks")
        for removal in changes.removals {
            XCTAssertEqual(removal.time(in: c.project), removal.time, "pinned at its join")
        }
    }

    /// A slip shows other media in the same place: a change, even on the
    /// take, and no join, since nothing got shorter.
    func testASlippedTakeClipIsChangedWithNoMark() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30)))
        let second = c.clips("Screen")[1]
        let changes = try agent(c, [.slip(clipID: second.id, delta: t(-2))])
        XCTAssertEqual(Set(changes.changed), Set(c.project.linkedClipIDs(of: second.id)))
        XCTAssertEqual(changes.changed.count, 3, "the screen, the camera and its sound")
        XCTAssertEqual(changes.removals, [])
    }

    /// A pause cut where one take clip ends and the next begins takes from
    /// both, and still makes one mark a track.
    func testARippleDeleteAcrossACutMakesOneMarkATrack() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10.5)))
        let changes = try agent(c, [.rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.changed, [])
        let screen = changes.removals.filter { $0.trackID == f.track("Screen").id }
        XCTAssertEqual(screen.count, 1)
        XCTAssertEqual(screen.first?.time, t(10))
        XCTAssertEqual(screen.first?.duration, t(1))
        XCTAssertEqual(screen.first?.from.count, 2)
    }

    func testOpeningTimeMovesThingsWithoutChangingThem() throws {
        let (_, c) = try Fixture.edited()
        let changes = try agent(c, [.insertTime(at: t(15), duration: t(2))])
        XCTAssertTrue(changes.isEmpty, "\(changes)")
    }

    func testBladingTheTakeIsNotAChange() throws {
        let (_, c) = try Fixture.edited()
        XCTAssertTrue(try agent(c, [.blade(at: t(12))]).isEmpty)
    }

    func testAMovedClipIsChanged() throws {
        let (f, c) = try Fixture.edited()
        let shot = f.clips("B-roll")[0]
        let changes = try agent(c, [.moveClips(clipIDs: [shot.id], delta: t(5), includeLinked: false)])
        XCTAssertEqual(changes.changed, [shot.id])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.removals, [])
    }

    func testTrimmingAClipIsAChange() throws {
        let (f, c) = try Fixture.edited()
        let shot = f.clips("B-roll")[0]
        let changes = try agent(c, [.trim(clipID: shot.id, edge: .end, to: t(24), ripple: false, includeLinked: false)])
        XCTAssertEqual(changes.changed, [shot.id])
        XCTAssertEqual(changes.removals, [])
    }

    /// Closing up the B-roll track only moves B-roll: a shot after the gap
    /// now plays over different words, so it has changed.
    func testRippleDeletingOnlyTheBRollMovesTheShotsAfterIt() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Second shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)))
        let shots = c.clips("B-roll")
        let changes = try agent(c, [.removeClips(clipIDs: [shots[0].id], ripple: true)])
        XCTAssertEqual(changes.changed, [shots[1].id])
        XCTAssertEqual(changes.removals.map(\.trackID), [f.track("B-roll").id])
        XCTAssertEqual(changes.removals.first?.time, t(20))
    }

    func testLiftingAClipLeavesAMarkWhereItWasPinnedToTheNextClip() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Second shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)))
        let shots = c.clips("B-roll")
        let changes = try agent(c, [.removeClips(clipIDs: [shots[0].id], ripple: false)])
        XCTAssertEqual(changes.removals.count, 1)
        let removal = changes.removals[0]
        XCTAssertEqual(removal.trackID, f.track("B-roll").id)
        XCTAssertEqual(removal.time, t(20))
        XCTAssertEqual(removal.duration, t(5))
        XCTAssertEqual(removal.anchorClipID, shots[1].id)
        XCTAssertEqual(removal.anchorEdge, .start)
        XCTAssertEqual(removal.offset, t(-20))
        XCTAssertEqual(removal.time(in: c.project), t(20))
        XCTAssertEqual(removal.from, [shots[0].id])
    }

    /// With nothing after it on the track, the mark stays with the clip
    /// before it.
    func testTheLastClipsMarkIsPinnedToTheOneBefore() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Second shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)))
        let shots = c.clips("B-roll")
        let removal = try XCTUnwrap(try agent(c, [.removeClips(clipIDs: [shots[1].id])]).removals.first)
        XCTAssertEqual(removal.anchorClipID, shots[0].id)
        XCTAssertEqual(removal.anchorEdge, .end)
        XCTAssertEqual(removal.offset, t(15))
    }

    /// Section cards that make room push the whole take along at the
    /// marker; the card is the only news.
    func testSectionCardsThatMakeRoomAreTheOnlyNews() throws {
        let (_, c) = try Fixture.edited()
        let changes = try agent(c, [.addSectionCards(mode: .insert)])
        let card = try XCTUnwrap(c.clips("Graphics").first)
        XCTAssertEqual(changes.added, [card.id])
        XCTAssertEqual(changes.changed, [])
        XCTAssertEqual(changes.removals, [])
    }

    /// A shot placed over another replaces it: the new shot shows that,
    /// with no mark for the one it replaced.
    func testAShotThatReplacesAnotherLeavesNoMark() throws {
        let (f, c) = try Fixture.edited()
        let old = f.clips("B-roll")[0]
        let changes = try agent(c, [.placeMedia(mediaIDs: ["med_broll"], at: t(20), sourceStart: t(4), duration: t(5), mode: .overwrite)])
        let shot = c.clips("B-roll")[0]
        XCTAssertNotEqual(shot.id, old.id)
        XCTAssertEqual(changes.added, [shot.id])
        XCTAssertEqual(changes.removals, [])
    }

    func testANewTransitionIsFound() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10)))
        let camera = c.clips("Camera")
        let changes = try agent(c, [.addTransition(trackID: f.track("Camera").id, transition: Transition(id: "tr_new", type: .dissolve, duration: t(0.5), fromClipID: camera[0].id, toClipID: camera[1].id))])
        XCTAssertEqual(changes.transitions, ["tr_new"])
        XCTAssertEqual(changes.changed, [])
    }

    func testANewLookChangesEveryClipOfTheFile() throws {
        let (f, c) = try Fixture.edited()
        let changes = try agent(c, [.updateMedia(mediaID: "med_camera", patch: .object(["look": .array([.object(["type": .string("vignette")])])]))])
        let cameraClips = Set(c.project.allTracks.flatMap(\.clips).filter { $0.mediaID == "med_camera" }.map(\.id))
        XCTAssertEqual(Set(changes.changed), cameraClips)
        XCTAssertEqual(cameraClips.count, 2, "the picture and its sound")
        XCTAssertFalse(changes.changed.contains(f.clips("Screen")[0].id))
    }
}

/// The log: only agents' batches, followed by clip ID through later edits.
final class ReviewLogTests: XCTestCase {
    /// Runs a batch and updates `log` the way the recorder does.
    @discardableResult
    private func run(_ c: ProjectCoordinator, _ log: inout ReviewLog, by author: String, _ commands: [EditCommand], label: String = "Edit") throws -> Int {
        let before = c.project
        let result = try c.apply(EditBatch(label: label, author: author, commands: commands))
        log.follow(from: before, to: c.project)
        log.record(label: label, author: author, revision: result.revision, before: before, after: c.project)
        log.prune(in: c.project, reverts: false)
        return result.revision
    }

    func testOnlyAgentsEditsAreRecorded() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "user", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        try run(c, &log, by: "", [.placeMedia(mediaIDs: ["med_broll"], at: t(44), duration: t(1))])
        try run(c, &log, by: "system", [.placeMedia(mediaIDs: ["med_broll"], at: t(46), duration: t(1))])
        XCTAssertTrue(log.isEmpty)
        let revision = try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(2))], label: "Add push")
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].label, "Add push")
        XCTAssertEqual(log.entries[0].author, "claude")
        XCTAssertEqual(log.entries[0].revision, revision)
        XCTAssertEqual(log.entries[0].added, [c.clips("B-roll").last!.id])
    }

    /// The highlight is on the clip's ID, so it stays with the clip when
    /// Mike tightens the take before it and then moves it.
    func testTheHighlightFollowsItsClipThroughARippleAndAMove() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        let shot = c.clips("B-roll").last!
        try run(c, &log, by: "user", [.rippleDeleteRange(range: TimeRange(start: t(5), end: t(7)))])
        XCTAssertEqual(c.project.clip(shot.id)?.start, t(38))
        try run(c, &log, by: "user", [.moveClips(clipIDs: [shot.id], delta: t(4), includeLinked: false)])
        XCTAssertEqual(c.project.clip(shot.id)?.start, t(42))
        XCTAssertEqual(log.entries.map(\.added), [[shot.id]])
    }

    func testCuttingAHighlightedClipHighlightsBothHalves() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(4))])
        let shot = c.clips("B-roll").last!
        try run(c, &log, by: "user", [.blade(at: t(42), clipIDs: [shot.id])])
        let halves = c.clips("B-roll").filter { $0.start >= t(40) }.map(\.id)
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(Set(log.entries[0].added), Set(halves))
    }

    /// Mike may only have nudged it: the agent's change still wants a look.
    func testMikeChangingAnAgentsClipKeepsTheHighlight() throws {
        let (f, c) = try Fixture.edited()
        var log = ReviewLog()
        let music = f.clips("Music")[0]
        try run(c, &log, by: "claude", [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])]))])
        try run(c, &log, by: "user", [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-31)])]))])
        XCTAssertEqual(log.entries.map(\.changed), [[music.id]], "even back where it was, by hand")
    }

    func testDeletingAnAgentsClipDropsItsHighlight() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        try run(c, &log, by: "user", [.removeClips(clipIDs: [c.clips("B-roll").last!.id])])
        XCTAssertTrue(log.isEmpty)
    }

    /// A lift's mark stays with the clip after it when Mike tightens the
    /// take before both.
    func testARemovalMarkMovesWithTheClipAfterIt() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Second shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)))
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.removeClips(clipIDs: [c.clips("B-roll")[0].id])])
        try run(c, &log, by: "user", [.rippleDeleteRange(range: TimeRange(start: t(5), end: t(8)))])
        let removal = try XCTUnwrap(log.entries.first?.removals.first)
        XCTAssertEqual(removal.time(in: c.project), t(17))
    }

    /// When the clip a mark was pinned to goes, the mark is pinned again
    /// where its join is now.
    func testAMarkWhoseClipWentIsPinnedAgain() throws {
        let (_, c) = try Fixture.edited()
        try c.run("More shots", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)), .placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(3)))
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.removeClips(clipIDs: [c.clips("B-roll")[0].id])])
        try run(c, &log, by: "user", [.removeClips(clipIDs: [c.clips("B-roll")[0].id])])
        let removal = try XCTUnwrap(log.entries.first?.removals.first)
        XCTAssertEqual(removal.anchorClipID, c.clips("B-roll")[0].id)
        XCTAssertEqual(removal.time(in: c.project), t(20))
    }

    func testTheLogReadsBackAsItWasWritten() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))], label: "Add push")
        try run(c, &log, by: "codex", [.rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))], label: "Tighten")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)/.tandem/Test.review.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try log.save(to: url)
        XCTAssertEqual(ReviewLog.load(from: url), log)
        try ReviewLog().save(to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an empty log leaves no file")
        XCTAssertEqual(ReviewLog.load(from: url), ReviewLog())
    }

    func testABrokenLogReadsAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(ReviewLog.load(from: url), ReviewLog())
    }
}

/// The recorder keeps the log as a coordinator commits, and saves it.
final class ReviewRecorderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".tandem"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var url: URL { ProjectFile.reviewURL(for: folder.appendingPathComponent("Test.tandem")) }

    func testRecordsAgentEditsAndSavesThemForTheNextOpen() throws {
        let (_, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        try c.apply(EditBatch(label: "Mike's", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]))
        XCTAssertTrue(recorder.log.isEmpty)
        try c.apply(EditBatch(label: "Add push", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(3))]))
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push"])
        recorder.close()
        let reopened = ReviewRecorder(coordinator: c, url: url)
        XCTAssertEqual(reopened.log, recorder.log)
        reopened.close()
    }

    func testUndoDropsTheAgentsEditAndRedoBringsItBack() throws {
        let (f, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let music = f.clips("Music")[0]
        try c.apply(EditBatch(label: "Add push", author: "claude", commands: [
            .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)),
            .updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])])),
            .rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))
        ]))
        XCTAssertEqual(recorder.log.entries.count, 1)
        c.undo()
        XCTAssertTrue(recorder.log.isEmpty, "\(recorder.log)")
        c.redo()
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push"])
    }

    /// Undoing Mike's own edit after an agent's leaves the agent's edit.
    func testUndoingMikesEditKeepsTheAgents() throws {
        let (f, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let music = f.clips("Music")[0]
        try c.apply(EditBatch(label: "Quieter", author: "claude", commands: [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])]))]))
        try c.apply(EditBatch(label: "Nudge", commands: [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-34)])]))]))
        c.undo()
        XCTAssertEqual(recorder.log.entries.map(\.changed), [[music.id]])
    }

    func testMarkReviewedClearsTheLogAndItsFile() throws {
        let (_, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        var heard: [ReviewLog] = []
        recorder.observe { heard.append($0) }
        try c.apply(EditBatch(label: "Add push", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]))
        // Reading the log waits for the recorder to catch up.
        XCTAssertEqual(recorder.log.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        recorder.markReviewed()
        XCTAssertTrue(recorder.log.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(heard.map(\.entries.count), [1, 0])
    }

    /// Edits a crash kept in the journal reach the log when the project
    /// opens, once.
    func testCatchesUpOnEditsTheJournalReplayed() throws {
        let (f, c) = try Fixture.edited()
        let journal = ProjectJournal(url: folder.appendingPathComponent(".tandem/Test.journal.jsonl"))
        let batch = EditBatch(label: "Add push", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        journal.append(batch: batch, revision: c.revision + 1, seed: 7)
        var replayed: [(entry: ProjectJournal.Entry, before: Project, after: Project)] = []
        let recovered = try XCTUnwrap(journal.recover(project: f.project, revision: c.revision) { replayed.append(($0, $1, $2)) })
        XCTAssertEqual(replayed.count, 1)
        let reopened = ProjectCoordinator(project: recovered.project, revision: recovered.revision)
        let recorder = ReviewRecorder(coordinator: reopened, url: url)
        defer { recorder.close() }
        recorder.catchUp(replayed)
        recorder.catchUp(replayed)
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push"])
        XCTAssertEqual(recorder.log.entries.first?.added, [reopened.clips("B-roll").last!.id])
    }
}

final class JournalReplayTests: XCTestCase {
    /// Recovery says what each entry did, with the project either side.
    func testRecoverReportsEachEntryWithTheProjectEitherSide() throws {
        let (f, c) = try Fixture.edited()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = ProjectJournal(url: url)
        journal.append(batch: EditBatch(label: "A", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]), revision: c.revision + 1, seed: 1)
        journal.appendSnapshot(project: f.project, revision: c.revision + 2, reason: "undo A")
        var seen: [(String, Int, Int)] = []
        _ = journal.recover(project: f.project, revision: c.revision) { entry, before, after in
            seen.append((entry.batch?.label ?? entry.reason ?? "", before.track(named: "B-roll")!.clips.count, after.track(named: "B-roll")!.clips.count))
        }
        XCTAssertEqual(seen.map(\.0), ["A", "undo A"])
        XCTAssertEqual(seen.map(\.1), [1, 2])
        XCTAssertEqual(seen.map(\.2), [2, 1])
    }
}
