import Foundation
import XCTest
@testable import VideoHQApp

final class RoughCutAnalysisTests: XCTestCase {
    func testDecodesPlannerRegionsAndClassifiesReviewSegments() throws {
        let data = Data(
            """
            {
              "schema_version": 1,
              "source": {"filename": "camera.mp4", "duration_seconds": 20.0},
              "regions": [
                {
                  "id": "speech-0001", "start": 0.0, "end": 4.0,
                  "text": "A clean section", "decision": "keep", "confidence": 0.0,
                  "reason": "no_high_confidence_duplicate", "duplicate_of": null,
                  "has_transcript_evidence": true
                },
                {
                  "id": "speech-0002", "start": 5.0, "end": 7.0,
                  "text": "A false start", "decision": "drop", "confidence": 0.95,
                  "reason": "repeated_opening_or_false_start", "duplicate_of": "speech-0003",
                  "has_transcript_evidence": true
                },
                {
                  "id": "speech-0003", "start": 8.0, "end": 9.0,
                  "text": "", "decision": "drop", "confidence": 0.9,
                  "reason": "no_transcript_word_overlap", "duplicate_of": null,
                  "has_transcript_evidence": false
                },
                {
                  "id": "speech-0004", "start": 10.0, "end": 12.0,
                  "text": "Short but possibly valid", "decision": "review", "confidence": 0.5,
                  "reason": "short_clip_suspicious", "duplicate_of": null,
                  "has_transcript_evidence": true
                }
              ]
            }
            """.utf8
        )

        let plan = try RoughCutPlan.decode(from: data)

        XCTAssertEqual(plan.source.durationSeconds, 20)
        XCTAssertEqual(plan.regions.map(\.kind), [.valid, .falseStart, .badTake, .needsReview])
        XCTAssertEqual(plan.regions[1].duplicateOf, "speech-0003")
    }

    func testSourceLibraryListsVideosAndCopiesAnExternalVideoWithoutOverwriting() throws {
        let root = temporaryDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        let external = root.appendingPathComponent("camera.mov")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("camera bytes".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = RoughCutSourceLibrary(projectDirectoryURL: project)
        let imported = try library.importVideo(at: external)

        XCTAssertEqual(imported, project.appendingPathComponent("source/camera.mov"))
        XCTAssertEqual(try Data(contentsOf: imported), Data("camera bytes".utf8))
        XCTAssertEqual(
            try library.videos().map { $0.resolvingSymlinksInPath() },
            [imported.resolvingSymlinksInPath()]
        )
        XCTAssertThrowsError(try library.importVideo(at: external))
    }

    func testAnalysisStoreReusesACompletedPlannerTranscriptForAnUnchangedSource() throws {
        let root = temporaryDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        let source = project.appendingPathComponent("source/camera.mp4")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("original video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RoughCutAnalysisStore(projectDirectoryURL: project)
        let output = try store.newRunDirectoryURL(
            for: source,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            identifier: "test-run"
        )
        XCTAssertTrue(output.path.contains("/work/video-hq-rough-cut/camera-mp4/"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try samplePlanData(filename: "camera.mp4").write(
            to: output.appendingPathComponent("rough-cut-plan.json")
        )
        try Data("{\"schema_version\":1,\"segments\":[]}".utf8).write(
            to: output.appendingPathComponent("transcript.json")
        )

        let completed = try store.recordCompletedRun(at: output, sourceVideoURL: source)

        let latest = try XCTUnwrap(store.latestAnalysis(for: source))
        XCTAssertEqual(latest.plan, completed.plan)
        XCTAssertEqual(
            latest.directoryURL.resolvingSymlinksInPath(),
            completed.directoryURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            try store.reusableTranscriptURL(for: source),
            output.appendingPathComponent("transcript.json").resolvingSymlinksInPath()
        )

        try Data("changed video contents".utf8).write(to: source)
        XCTAssertNil(try store.latestAnalysis(for: source))
    }

    func testPlannerCommandReusesTheProvidedTranscript() {
        let arguments = FilmoraRoughCutRunner.arguments(
            videoURL: URL(fileURLWithPath: "/project/source/camera.mp4"),
            outputDirectoryURL: URL(fileURLWithPath: "/project/work/video-hq-rough-cut/camera/run"),
            transcriptURL: URL(fileURLWithPath: "/project/source/camera.srt")
        )

        XCTAssertEqual(arguments[0...2], ["-m", "filmora_wfp", "rough-cut-plan"])
        XCTAssertTrue(arguments.contains("--transcript"))
        XCTAssertEqual(arguments.last, "/project/source/camera.srt")
        XCTAssertTrue(arguments.contains("--json"))
    }

    func testManualDecisionsPersistAndAutomaticRemovesTheOverride() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RoughCutOverrideStore(analysisDirectoryURL: root)

        try store.save([
            "speech-0001": .keep,
            "speech-0002": .automatic,
            "speech-0003": .cut,
        ], validRegionIDs: ["speech-0001", "speech-0002", "speech-0003"])

        XCTAssertEqual(
            try store.load(),
            ["speech-0001": .keep, "speech-0003": .cut]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.overridesURL.path))
    }

    func testManualDecisionChangesTheEffectiveRegionWithoutChangingPlannerEvidence() {
        let original = region(id: "one", text: "Keep this")

        let cut = original.applyingManualDecision(.cut)

        XCTAssertEqual(cut.decision, "drop")
        XCTAssertEqual(cut.reason, "manual_cut")
        XCTAssertEqual(cut.kind, .badTake)
        XCTAssertEqual(original.decision, "keep")
        XCTAssertEqual(original.reason, "no_high_confidence_duplicate")
    }

    func testReviewedPlanPreservesPlannerDataAndRebuildsKeepRanges() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("rough-cut-plan.json")
        let output = root.appendingPathComponent("reviewed-plan.json")
        let sourceData = Data(
            """
            {
              "schema_version": 1,
              "source": {"filename": "camera.mp4", "duration_seconds": 8.0},
              "settings": {"threshold_db": -35},
              "keep_ranges": [{"start": 0.0, "end": 2.0}, {"start": 5.0, "end": 6.0}],
              "regions": [
                {"id": "one", "start": 0.0, "end": 2.0, "text": "first", "decision": "keep", "confidence": 0.1, "reason": "original_keep", "duplicate_of": null, "has_transcript_evidence": true},
                {"id": "two", "start": 2.0, "end": 4.0, "text": "second", "decision": "drop", "confidence": 0.9, "reason": "duplicate", "duplicate_of": "one", "has_transcript_evidence": true},
                {"id": "three", "start": 5.0, "end": 6.0, "text": "third", "decision": "review", "confidence": 0.5, "reason": "short_clip_suspicious", "duplicate_of": null, "has_transcript_evidence": true}
              ],
              "review_required": true
            }
            """.utf8
        )
        try sourceData.write(to: source)

        try RoughCutReviewedPlanWriter().write(
            sourcePlanURL: source,
            outputURL: output,
            overrides: ["one": .cut, "two": .keep]
        )

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        )
        XCTAssertNotNil(payload["settings"])
        let regions = try XCTUnwrap(payload["regions"] as? [[String: Any]])
        XCTAssertEqual(regions[0]["decision"] as? String, "drop")
        XCTAssertEqual(regions[0]["reason"] as? String, "manual_cut")
        XCTAssertEqual(regions[0]["video_hq_original_decision"] as? String, "keep")
        XCTAssertEqual(regions[1]["decision"] as? String, "keep")
        XCTAssertEqual(regions[1]["reason"] as? String, "manual_keep")
        let keepRanges = try XCTUnwrap(payload["keep_ranges"] as? [[String: Any]])
        XCTAssertEqual(keepRanges.count, 2)
        XCTAssertEqual(keepRanges[0]["start"] as? Double, 2.0)
        XCTAssertEqual(keepRanges[0]["end"] as? Double, 4.0)
        XCTAssertEqual(keepRanges[1]["start"] as? Double, 5.0)
        XCTAssertEqual(keepRanges[1]["end"] as? Double, 6.0)
        let review = try XCTUnwrap(payload["video_hq_review"] as? [String: Any])
        XCTAssertEqual(review["manual_override_count"] as? Int, 2)
    }

    func testReviewedPlanCanUseTheFilmoraSeedDurationWithoutChangingTheOriginalPlan() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("rough-cut-plan.json")
        let output = root.appendingPathComponent("reviewed-plan.json")
        let sourceData = Data(
            """
            {
              "schema_version": 1,
              "source": {"filename": "camera.mov", "duration_seconds": 8.08},
              "keep_ranges": [{"start": 0.0, "end": 7.0}],
              "regions": [
                {"id": "one", "start": 0.0, "end": 7.0, "text": "first", "decision": "keep", "confidence": 0.1, "reason": "original_keep", "duplicate_of": null, "has_transcript_evidence": true}
              ]
            }
            """.utf8
        )
        try sourceData.write(to: source)

        try RoughCutReviewedPlanWriter().write(
            sourcePlanURL: source,
            outputURL: output,
            overrides: [:],
            filmoraSourceDurationSeconds: 8.0
        )

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        )
        let sourcePayload = try XCTUnwrap(payload["source"] as? [String: Any])
        XCTAssertEqual(sourcePayload["duration_seconds"] as? Double, 8.0)
        let review = try XCTUnwrap(payload["video_hq_review"] as? [String: Any])
        XCTAssertEqual(review["planner_source_duration_seconds"] as? Double, 8.08)
        XCTAssertEqual(review["filmora_source_duration_seconds"] as? Double, 8.0)
    }

    func testFilmoraExportCommandsInspectSeedThenWriteAndValidateNewProject() {
        let seed = URL(fileURLWithPath: "/project/clean-seed.wfp")
        let plan = URL(fileURLWithPath: "/project/reviewed-plan.json")
        let output = URL(fileURLWithPath: "/project/new-rough-cut.wfp")

        XCTAssertEqual(
            FilmoraRoughCutExportRunner.seedArguments(seedURL: seed),
            ["-m", "filmora_wfp", "rough-cut-seed", seed.path, "--json"]
        )
        XCTAssertEqual(
            FilmoraRoughCutExportRunner.projectArguments(
                seedURL: seed,
                planURL: plan,
                outputURL: output,
                expectedSHA256: "abc123"
            ),
            [
                "-m", "filmora_wfp", "rough-cut-project", seed.path, plan.path,
                output.path, "--expect-sha256", "abc123", "--json",
            ]
        )
        XCTAssertEqual(
            FilmoraRoughCutExportRunner.validationArguments(outputURL: output),
            ["-m", "filmora_wfp", "validate", output.path, "--check-media", "--json"]
        )
        XCTAssertEqual(
            FilmoraRoughCutExportRunner.inspectionArguments(seedURL: seed),
            ["-m", "filmora_wfp", "inspect", seed.path, "--reveal-paths", "--json"]
        )
    }

    func testFilmoraSeedMatcherChoosesTheExactRecordingAndClosestDuration() throws {
        let source = URL(fileURLWithPath: "/project/source/camera.mov")
        let matching = FilmoraRoughCutSeed(
            projectURL: URL(fileURLWithPath: "/project/work/camera-seed.wfp"),
            sourceVideoURL: source,
            sourceFilename: "camera.mov",
            sourceDurationSeconds: 99.93,
            sha256: "matching"
        )
        let stale = FilmoraRoughCutSeed(
            projectURL: URL(fileURLWithPath: "/project/work/stale-seed.wfp"),
            sourceVideoURL: source,
            sourceFilename: "camera.mov",
            sourceDurationSeconds: 95,
            sha256: "stale"
        )
        let otherSource = FilmoraRoughCutSeed(
            projectURL: URL(fileURLWithPath: "/project/work/other-seed.wfp"),
            sourceVideoURL: URL(fileURLWithPath: "/project/source/other.mov"),
            sourceFilename: "other.mov",
            sourceDurationSeconds: 100,
            sha256: "other"
        )

        let selected = try FilmoraRoughCutExportRunner.bestMatchingSeed(
            [stale, otherSource, matching],
            sourceVideoURL: source,
            plannedDurationSeconds: 100
        )

        XCTAssertEqual(selected, matching)
    }

    func testTimelineInteractionClampsCursorPositionToTheVideoDuration() {
        XCTAssertEqual(
            RoughCutTimelineInteraction.seconds(x: -20, width: 200, duration: 100),
            0
        )
        XCTAssertEqual(
            RoughCutTimelineInteraction.seconds(x: 100, width: 200, duration: 100),
            50
        )
        XCTAssertEqual(
            RoughCutTimelineInteraction.seconds(x: 240, width: 200, duration: 100),
            100
        )
    }

    func testTimelineInteractionFindsTheSectionUnderThePlayhead() {
        let regions = [
            region(id: "one", text: "First", start: 0, end: 4),
            region(id: "two", text: "Second", start: 5, end: 8),
        ]

        XCTAssertEqual(RoughCutTimelineInteraction.regionID(at: 2, regions: regions), "one")
        XCTAssertNil(RoughCutTimelineInteraction.regionID(at: 4.5, regions: regions))
        XCTAssertEqual(RoughCutTimelineInteraction.regionID(at: 5, regions: regions), "two")
        XCTAssertEqual(RoughCutTimelineInteraction.regionID(at: 8, regions: regions), "two")
    }

    func testScriptCoverageFlagsOffScriptSpeechAndMissingParagraphs() {
        let regions = [
            region(id: "one", text: "Build agents with durable objects."),
            region(id: "two", text: "Remember to like and subscribe."),
        ]
        let script = """
        # Script
        Build agents with durable objects.
        Deploy them safely to production.
        """

        let report = RoughCutScriptCoverage.analyze(script: script, regions: regions)

        XCTAssertGreaterThan(report.score(for: "one") ?? 0, 0.9)
        XCTAssertTrue(report.mismatchedRegionIDs.contains("two"))
        XCTAssertEqual(report.missingParagraphs.map(\.text), ["Deploy them safely to production."])
    }

    private func region(
        id: String,
        text: String,
        start: Double = 0,
        end: Double = 5
    ) -> RoughCutRegion {
        RoughCutRegion(
            id: id,
            start: start,
            end: end,
            text: text,
            decision: "keep",
            confidence: 0,
            reason: "no_high_confidence_duplicate",
            duplicateOf: nil,
            hasTranscriptEvidence: true
        )
    }

    private func samplePlanData(filename: String) -> Data {
        Data(
            """
            {
              "schema_version": 1,
              "source": {"filename": "\(filename)", "duration_seconds": 20.0},
              "regions": []
            }
            """.utf8
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
