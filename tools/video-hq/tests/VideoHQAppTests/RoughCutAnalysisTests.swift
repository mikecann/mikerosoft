import AVFoundation
import AppKit
import Foundation
import XCTest
@testable import VideoHQApp

final class RoughCutAnalysisTests: XCTestCase {
    func testSpacebarShortcutOnlyHandlesUnmodifiedSpaceOutsideTextEditing() {
        XCTAssertTrue(
            RoughCutPlaybackShortcut.shouldHandle(
                keyCode: 49,
                modifiers: [],
                isEditingText: false
            )
        )
        XCTAssertFalse(
            RoughCutPlaybackShortcut.shouldHandle(
                keyCode: 49,
                modifiers: [],
                isEditingText: true
            )
        )
        XCTAssertFalse(
            RoughCutPlaybackShortcut.shouldHandle(
                keyCode: 49,
                modifiers: [.command],
                isEditingText: false
            )
        )
        XCTAssertFalse(
            RoughCutPlaybackShortcut.shouldHandle(
                keyCode: 36,
                modifiers: [],
                isEditingText: false
            )
        )
    }

    func testRoughCutProcessSeparatesClipReviewFromVisualPlanning() {
        XCTAssertEqual(RoughCutProcessStage.allCases, [.review, .visuals])
        XCTAssertEqual(RoughCutProcessStage.review.label, "1. Clips")
        XCTAssertEqual(RoughCutProcessStage.visuals.label, "2. Visuals")
    }

    @MainActor
    func testPlaybackClockReattachesWithoutRecreatingItsOwner() {
        let firstPlayer = AVPlayer()
        let secondPlayer = AVPlayer()
        let clock = RoughCutPlaybackClock(player: firstPlayer)

        clock.attach(to: secondPlayer)

        XCTAssertTrue(clock.observedPlayer === secondPlayer)
    }

    @MainActor
    func testPlaybackClockSynchronizesImmediatelyAfterAPausedSeek() {
        let clock = RoughCutPlaybackClock(player: AVPlayer())

        clock.synchronize(to: 27)

        XCTAssertEqual(clock.currentTime, 27, accuracy: 0.001)
    }

    func testExpandedJoinedClipShowsOneListPlayheadOnItsActiveChild() {
        XCTAssertTrue(
            RoughCutListPlayheadVisibility.showOnParent(
                isActive: true,
                isExpanded: false
            )
        )
        XCTAssertFalse(
            RoughCutListPlayheadVisibility.showOnParent(
                isActive: true,
                isExpanded: true
            )
        )
        XCTAssertTrue(RoughCutListPlayheadVisibility.showOnChild(isActive: true))
        XCTAssertFalse(RoughCutListPlayheadVisibility.showOnChild(isActive: false))
    }

    func testLiveScrubPositionOverridesThePeriodicPlayerClock() {
        XCTAssertEqual(
            RoughCutDisplayedPlaybackPosition.sourceTime(
                scrubbedSourceTime: 42,
                clockSourceTime: 10
            ),
            42
        )
        XCTAssertEqual(
            RoughCutDisplayedPlaybackPosition.sourceTime(
                scrubbedSourceTime: nil,
                clockSourceTime: 10
            ),
            10
        )
    }

    func testVisualDraftOnlyPersistsAfterAnActualUserEdit() {
        XCTAssertFalse(
            RoughCutVisualDraftPersistence.shouldPersist(
                isDirty: false,
                selectedGroupCount: 2
            )
        )
        XCTAssertTrue(
            RoughCutVisualDraftPersistence.shouldPersist(
                isDirty: true,
                selectedGroupCount: 2
            )
        )
        XCTAssertFalse(
            RoughCutVisualDraftPersistence.shouldPersist(
                isDirty: true,
                selectedGroupCount: 0
            )
        )
    }

    func testAutoplayCompletionOnlyAppliesToTheCurrentAuthorizedBuild() {
        XCTAssertTrue(
            RoughCutAutoplayAuthorization.isCurrent(
                expectedGeneration: 4,
                playbackGeneration: 4,
                authorizedGeneration: 4
            )
        )
        XCTAssertFalse(
            RoughCutAutoplayAuthorization.isCurrent(
                expectedGeneration: 4,
                playbackGeneration: 5,
                authorizedGeneration: 4
            )
        )
        XCTAssertFalse(
            RoughCutAutoplayAuthorization.isCurrent(
                expectedGeneration: 4,
                playbackGeneration: 4,
                authorizedGeneration: nil
            )
        )
    }

    func testTimelineTracksUseTheSameSourceTimeCoordinate() {
        XCTAssertEqual(
            RoughCutTimelineGeometry.normalizedPosition(
                time: 170.5,
                duration: 1_057.6
            ),
            170.5 / 1_057.6,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            RoughCutTimelineGeometry.normalizedRange(
                start: 170.5,
                end: 180.5,
                duration: 1_057.6
            ).start,
            170.5 / 1_057.6,
            accuracy: 0.000_001
        )
    }

    func testFilteredCompositionCanBeReusedWhenOnlyTheStartingClipChanges() {
        let plan = RoughCutPlaybackPlan(clips: [
            RoughCutPlaybackClip(
                regionID: "one",
                sourceStart: 5,
                sourceEnd: 8,
                crossfadeAfter: 0
            ),
            RoughCutPlaybackClip(
                regionID: "two",
                sourceStart: 20,
                sourceEnd: 24,
                crossfadeAfter: 0
            ),
        ])

        XCTAssertTrue(
            RoughCutPlaybackReuse.shouldReuse(
                isPlayingComposition: true,
                activePlan: plan,
                requestedPlan: plan
            )
        )
        XCTAssertFalse(
            RoughCutPlaybackReuse.shouldReuse(
                isPlayingComposition: false,
                activePlan: plan,
                requestedPlan: plan
            )
        )
        XCTAssertEqual(
            plan.playbackStartTime(forRegionID: "two"),
            3,
            accuracy: 0.001
        )
    }

    func testEditedTimelineRemovesSourceGapsAndIncludesCrossfades() {
        let plan = RoughCutPlaybackPlan(clips: [
            RoughCutPlaybackClip(
                regionID: "one",
                sourceStart: 5,
                sourceEnd: 8,
                crossfadeAfter: 0.04
            ),
            RoughCutPlaybackClip(
                regionID: "two",
                sourceStart: 20,
                sourceEnd: 24,
                crossfadeAfter: 0
            ),
            RoughCutPlaybackClip(
                regionID: "three",
                sourceStart: 50,
                sourceEnd: 52,
                crossfadeAfter: 0
            ),
        ])

        XCTAssertEqual(plan.timelineClips[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(plan.timelineClips[0].end, 2.96, accuracy: 0.001)
        XCTAssertEqual(plan.timelineClips[1].start, 2.96, accuracy: 0.001)
        XCTAssertEqual(plan.timelineClips[1].end, 6.96, accuracy: 0.001)
        XCTAssertEqual(plan.timelineClips[2].start, 6.96, accuracy: 0.001)
        XCTAssertEqual(plan.timelineClips[2].end, 8.96, accuracy: 0.001)

        let joinedRange = plan.playbackRange(forRegionIDs: ["one", "two"])
        XCTAssertEqual(joinedRange?.start ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(joinedRange?.end ?? -1, 6.96, accuracy: 0.001)
        XCTAssertEqual(
            plan.playbackBoundaries(
                forRegionGroups: [["one", "two"], ["three"]]
            ),
            [6.96]
        )
        XCTAssertEqual(
            plan.playbackStartTime(forSourceTime: 50),
            6.96,
            accuracy: 0.001
        )
    }

    func testReviewedCutPlaybackMapsEditedTimeBackOntoTheSourceTimeline() {
        let plan = RoughCutPlaybackPlan(clips: [
            RoughCutPlaybackClip(
                regionID: "one",
                sourceStart: 10,
                sourceEnd: 12,
                crossfadeAfter: 0
            ),
            RoughCutPlaybackClip(
                regionID: "two",
                sourceStart: 20,
                sourceEnd: 23,
                crossfadeAfter: 0
            ),
        ])

        XCTAssertEqual(plan.sourceTime(at: 0.5), 10.5, accuracy: 0.001)
        XCTAssertEqual(plan.sourceTime(at: 2.0), 20.0, accuracy: 0.001)
        XCTAssertEqual(plan.sourceTime(at: 2.5), 20.5, accuracy: 0.001)
        XCTAssertEqual(plan.sourceTime(at: 99), 23, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(plan.playbackTime(forSourceTime: 20.5)), 2.5, accuracy: 0.001)
        XCTAssertNil(plan.playbackTime(forSourceTime: 15))
        XCTAssertEqual(plan.nearestPlaybackTime(forSourceTime: 15), 2, accuracy: 0.001)
        XCTAssertEqual(plan.nearestPlaybackTime(forSourceTime: 19), 2, accuracy: 0.001)

        let regions = [
            RoughCutRegion(
                id: "one",
                start: 10,
                end: 12,
                text: "One",
                decision: "keep",
                confidence: 1,
                reason: "keep",
                duplicateOf: nil,
                hasTranscriptEvidence: true
            ),
            RoughCutRegion(
                id: "two",
                start: 20,
                end: 23,
                text: "Two",
                decision: "keep",
                confidence: 1,
                reason: "keep",
                duplicateOf: nil,
                hasTranscriptEvidence: true
            ),
        ]
        XCTAssertEqual(
            RoughCutTimelineInteraction.regionID(
                at: plan.sourceTime(at: 0.1),
                regions: regions
            ),
            "one"
        )
        XCTAssertEqual(
            RoughCutTimelineInteraction.regionID(
                at: plan.sourceTime(at: 2.0),
                regions: regions
            ),
            "two"
        )
    }

    func testPlaybackTimeMappingAccountsForCrossfadeOverlap() throws {
        let plan = RoughCutPlaybackPlan(clips: [
            RoughCutPlaybackClip(
                regionID: "one",
                sourceStart: 10,
                sourceEnd: 12,
                crossfadeAfter: 0.25
            ),
            RoughCutPlaybackClip(
                regionID: "two",
                sourceStart: 20,
                sourceEnd: 22,
                crossfadeAfter: 0
            ),
        ])

        XCTAssertEqual(plan.duration, 3.75, accuracy: 0.001)
        XCTAssertEqual(plan.sourceTime(at: 1.75), 20, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(plan.playbackTime(forSourceTime: 20.5)),
            2.25,
            accuracy: 0.001
        )
    }

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

    func testMediaAnalysisCommandProducesUnclassifiedInputsAndReusesTranscript() {
        let arguments = FilmoraRoughCutRunner.arguments(
            videoURL: URL(fileURLWithPath: "/project/source/camera.mp4"),
            outputDirectoryURL: URL(fileURLWithPath: "/project/work/video-hq-rough-cut/camera/run"),
            transcriptURL: URL(fileURLWithPath: "/project/source/camera.srt")
        )

        XCTAssertEqual(arguments[0...2], ["-m", "filmora_wfp", "rough-cut-inputs"])
        XCTAssertTrue(arguments.contains("--transcript"))
        XCTAssertEqual(arguments.last, "/project/source/camera.srt")
        XCTAssertTrue(arguments.contains("--json"))
    }

    func testCodexRoughCutAnalysisCommandIsEphemeralReadOnlyAndSchemaConstrained() {
        let arguments = CodexRoughCutAnalysisRunner.arguments(
            schemaURL: URL(fileURLWithPath: "/tmp/rough-cut-schema.json"),
            outputURL: URL(fileURLWithPath: "/tmp/rough-cut-output.json"),
            workingDirectoryURL: URL(fileURLWithPath: "/analysis/run")
        )

        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertEqual(
            Array(arguments[arguments.firstIndex(of: "--sandbox")!...].prefix(2)),
            ["--sandbox", "read-only"]
        )
        XCTAssertEqual(
            Array(arguments[arguments.firstIndex(of: "--output-schema")!...].prefix(2)),
            ["--output-schema", "/tmp/rough-cut-schema.json"]
        )
        XCTAssertEqual(
            Array(arguments[arguments.firstIndex(of: "-o")!...].prefix(2)),
            ["-o", "/tmp/rough-cut-output.json"]
        )
    }

    func testCodexRoughCutAnalysisReplacesEveryNeutralDecision() throws {
        let input = Data(
            """
            {
              "schema_version": 1,
              "source": {"filename": "camera.mp4", "duration_seconds": 12},
              "settings": {"classification": "codex"},
              "regions": [
                {
                  "id": "one", "start": 0, "end": 3, "text": "So the idea is",
                  "decision": "review", "confidence": 0,
                  "reason": "awaiting_codex_analysis", "duplicate_of": null,
                  "has_transcript_evidence": true
                },
                {
                  "id": "two", "start": 4, "end": 9, "text": "So the idea is the final version.",
                  "decision": "review", "confidence": 0,
                  "reason": "awaiting_codex_analysis", "duplicate_of": null,
                  "has_transcript_evidence": true
                }
              ]
            }
            """.utf8
        )
        let response = Data(
            """
            {
              "decisions": [
                {
                  "region_id": "one", "classification": "false_start",
                  "confidence": 0.96, "reason": "The speaker restarts this thought in region two.",
                  "duplicate_of": "two"
                },
                {
                  "region_id": "two", "classification": "valid",
                  "confidence": 0.98, "reason": "This is the completed take.",
                  "duplicate_of": null
                }
              ]
            }
            """.utf8
        )

        let plan = try RoughCutPlan.decode(
            from: CodexRoughCutAnalysisRunner.classifiedPlanData(
                inputData: input,
                responseData: response
            )
        )

        XCTAssertEqual(plan.regions.map(\.decision), ["drop", "keep"])
        XCTAssertEqual(plan.regions.map(\.kind), [.falseStart, .valid])
        XCTAssertEqual(plan.regions[0].duplicateOf, "two")
    }

    func testShortSectionWithoutTranscriptIsSkippedInsteadOfNeedingReview() throws {
        let input = Data(
            """
            {
              "schema_version": 1,
              "source": {"filename": "camera.mp4", "duration_seconds": 8},
              "regions": [
                {
                  "id": "short", "start": 0, "end": 1, "text": "",
                  "decision": "review", "confidence": 0,
                  "reason": "awaiting_codex_analysis", "duplicate_of": null,
                  "has_transcript_evidence": false
                },
                {
                  "id": "long", "start": 2, "end": 7, "text": "",
                  "decision": "review", "confidence": 0,
                  "reason": "awaiting_codex_analysis", "duplicate_of": null,
                  "has_transcript_evidence": false
                }
              ]
            }
            """.utf8
        )
        let response = Data(
            """
            {
              "decisions": [
                {
                  "region_id": "short", "classification": "needs_review",
                  "confidence": 0.7, "reason": "Audible region has no useful transcription.",
                  "duplicate_of": null
                },
                {
                  "region_id": "long", "classification": "needs_review",
                  "confidence": 0.7, "reason": "Audible region has no useful transcription.",
                  "duplicate_of": null
                }
              ]
            }
            """.utf8
        )

        let plan = try RoughCutPlan.decode(
            from: CodexRoughCutAnalysisRunner.classifiedPlanData(
                inputData: input,
                responseData: response
            )
        )

        XCTAssertEqual(plan.regions[0].decision, "drop")
        XCTAssertEqual(plan.regions[0].reason, "no_transcript_skip")
        XCTAssertEqual(plan.regions[0].kind, .noTranscriptSkip)
        XCTAssertEqual(plan.regions[1].decision, "review")
        XCTAssertEqual(plan.regions[1].kind, .needsReview)
    }

    func testCodexReasonPresentationHidesInternalClassificationPrefix() {
        XCTAssertEqual(
            RoughCutReasonPresentation.text(
                for: "codex_needs_review: Audible region has no useful transcription."
            ),
            "Audible region has no useful transcription."
        )
        XCTAssertEqual(
            RoughCutReasonPresentation.text(for: "no_transcript_skip"),
            "No transcript skip"
        )
    }

    func testCodexRoughCutAnalysisReturnsValidatedJoinSuggestionsInTheSamePass() throws {
        let input = Data(
            """
            {
              "schema_version": 1,
              "source": {"filename": "camera.mp4", "duration_seconds": 12},
              "regions": [
                {
                  "id": "one", "start": 0, "end": 3, "text": "This is",
                  "decision": "review", "confidence": 0,
                  "reason": "awaiting_codex_analysis", "duplicate_of": null,
                  "has_transcript_evidence": true
                },
                {
                  "id": "two", "start": 4, "end": 8, "text": "one complete sentence.",
                  "decision": "review", "confidence": 0,
                  "reason": "awaiting_codex_analysis", "duplicate_of": null,
                  "has_transcript_evidence": true
                },
                {
                  "id": "three", "start": 9, "end": 12, "text": "Next thought.",
                  "decision": "review", "confidence": 0,
                  "reason": "awaiting_codex_analysis", "duplicate_of": null,
                  "has_transcript_evidence": true
                }
              ]
            }
            """.utf8
        )
        let response = Data(
            """
            {
              "decisions": [
                {
                  "region_id": "one", "classification": "valid", "confidence": 0.98,
                  "reason": "Intended speech.", "duplicate_of": null
                },
                {
                  "region_id": "two", "classification": "valid", "confidence": 0.98,
                  "reason": "Intended speech.", "duplicate_of": null
                },
                {
                  "region_id": "three", "classification": "valid", "confidence": 0.98,
                  "reason": "Intended speech.", "duplicate_of": null
                }
              ],
              "join_suggestions": [
                {
                  "region_ids": ["one", "two"], "confidence": 0.95,
                  "reason": "The first clip ends mid-sentence."
                },
                {
                  "region_ids": ["one", "three"], "confidence": 0.8,
                  "reason": "Not adjacent."
                }
              ]
            }
            """.utf8
        )

        let result = try CodexRoughCutAnalysisRunner.classifiedResult(
            inputData: input,
            responseData: response
        )

        XCTAssertEqual(result.joinSuggestions.count, 1)
        XCTAssertEqual(result.joinSuggestions[0].regionIDs, ["one", "two"])
        XCTAssertEqual(result.joinSuggestions[0].decision, .pending)
    }

    func testCodexRoughCutRequestIncludesOptionalScriptAsSupportingContext() throws {
        let request = try CodexRoughCutAnalysisRunner.requestData(
            inputData: Data("{\"regions\":[]}".utf8),
            transcriptData: Data("{\"segments\":[]}".utf8),
            script: "# Script\\nThe intended spoken line."
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request) as? [String: Any]
        )

        XCTAssertEqual(
            payload["reference_script"] as? String,
            "# Script\\nThe intended spoken line."
        )
    }

    func testJoinSuggestionsProduceMatchingNumberedIndicatorsForBothSectionRows() {
        let suggestions = [
            RoughCutJoinSuggestion(
                regionIDs: ["one", "two"],
                confidence: 0.99,
                reason: "The sentence continues."
            ),
            RoughCutJoinSuggestion(
                regionIDs: ["four", "five", "six"],
                confidence: 0.95,
                reason: "One interrupted thought."
            ),
        ]

        let indicators = RoughCutJoinSectionIndicator.byRegionID(
            suggestions: suggestions
        )

        XCTAssertEqual(indicators["one"]?.first?.proposalNumber, 1)
        XCTAssertEqual(indicators["one"]?.first?.clipNumber, 1)
        XCTAssertEqual(indicators["two"]?.first?.proposalNumber, 1)
        XCTAssertEqual(indicators["two"]?.first?.clipNumber, 2)
        XCTAssertEqual(indicators["four"]?.first?.proposalNumber, 2)
        XCTAssertEqual(indicators["six"]?.first?.clipNumber, 3)
        XCTAssertEqual(indicators["six"]?.first?.clipCount, 3)
        XCTAssertEqual(indicators["one"]?.first?.showsInlineAction, false)
        XCTAssertEqual(indicators["two"]?.first?.showsInlineAction, true)
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

    func testRegionFiltersCanShowOnlyReviewSectionsWithoutAnExplicitDecision() {
        let valid = region(id: "valid", text: "Clean take")
        let review = RoughCutRegion(
            id: "review",
            start: 5,
            end: 7,
            text: "Check this take",
            decision: "review",
            confidence: 0.5,
            reason: "short_clip_suspicious",
            duplicateOf: nil,
            hasTranscriptEvidence: true
        )
        let decidedReview = RoughCutRegion(
            id: "decided-review",
            start: 8,
            end: 10,
            text: "Already reviewed",
            decision: "review",
            confidence: 0.5,
            reason: "short_clip_suspicious",
            duplicateOf: nil,
            hasTranscriptEvidence: true
        )
        let regions = [valid, review, decidedReview]
        let decisions: [String: RoughCutManualDecision] = [
            "decided-review": .keep,
        ]

        XCTAssertEqual(
            RoughCutRegionFilter.all.apply(to: regions, manualDecisions: decisions).map(\.id),
            ["valid", "review", "decided-review"]
        )
        XCTAssertEqual(
            RoughCutRegionFilter.needsReview.apply(
                to: regions,
                manualDecisions: decisions
            ).map(\.id),
            ["review", "decided-review"]
        )
        XCTAssertEqual(
            RoughCutRegionFilter.awaitingDecision.apply(
                to: regions,
                manualDecisions: decisions
            ).map(\.id),
            ["review"]
        )

        let combined = RoughCutRegionFilterSelection(
            filters: [.valid, .awaitingDecision]
        )
        XCTAssertEqual(
            combined.apply(to: regions, manualDecisions: decisions).map(\.id),
            ["valid", "review"]
        )
    }

    func testRegionFilterSelectionPersistsBesideTheAnalysis() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RoughCutViewStateStore(analysisDirectoryURL: root)
        let selection = RoughCutRegionFilterSelection(
            filters: [.valid, .falseStart, .awaitingDecision]
        )

        try store.save(selection)

        XCTAssertEqual(try store.load(), selection)
    }

    func testRoughCutProcessStartsWithOneStoryBeatPerAcceptedRegion() {
        let process = RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["speech-0001", "speech-0003", "speech-0004"]
        )

        XCTAssertEqual(process.groups.map(\.regionIDs), [
            ["speech-0001"],
            ["speech-0003"],
            ["speech-0004"],
        ])
        XCTAssertEqual(process.groups.map(\.visual.layout), [
            .unassigned,
            .unassigned,
            .unassigned,
        ])
    }

    func testClipClickSelectionReplacesNormallyAndAddsWithShift() {
        XCTAssertEqual(
            RoughCutClipSelection.select(
                "three",
                in: ["one", "two"],
                additive: false
            ),
            ["three"]
        )
        XCTAssertEqual(
            RoughCutClipSelection.select(
                "three",
                in: ["one", "two"],
                additive: true
            ),
            ["one", "two", "three"]
        )
    }

    func testClipClickOnlyContinuesPlaybackWhenPlaybackWasAlreadyRunning() {
        XCTAssertFalse(
            RoughCutPlaybackStartBehavior.rowSelection(
                wasPlaying: false
            ).shouldAutoplay
        )
        XCTAssertTrue(
            RoughCutPlaybackStartBehavior.rowSelection(
                wasPlaying: true
            ).shouldAutoplay
        )
        XCTAssertTrue(RoughCutPlaybackStartBehavior.explicitPlay.shouldAutoplay)
        XCTAssertTrue(
            RoughCutPlaybackContinuation.shouldContinue(
                isPlayerPlaying: false,
                isAutoplayBuildPending: true
            )
        )
    }

    func testUncheckingTheFocusedClipMovesFocusToAStillSelectedClip() {
        let updated = RoughCutClipSelection.toggle(
            "one",
            in: ["one", "two"],
            focusedGroupID: "one",
            orderedGroupIDs: ["one", "two", "three"]
        )

        XCTAssertEqual(updated.selectedGroupIDs, ["two"])
        XCTAssertEqual(updated.focusedGroupID, "two")
    }

    func testRoughCutProcessMergesAndUnmergesContiguousStoryBeats() throws {
        let original = RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["one", "two", "three", "four"]
        )
        let merged = try original.merging(groupIDs: ["two", "three"])

        XCTAssertEqual(merged.groups.map(\.regionIDs), [
            ["one"],
            ["two", "three"],
            ["four"],
        ])
        XCTAssertThrowsError(try original.merging(groupIDs: ["one", "three"]))

        let restored = merged.unmerging(groupIDs: [merged.groups[1].id])
        XCTAssertEqual(restored.groups.map(\.regionIDs), [
            ["one"],
            ["two"],
            ["three"],
            ["four"],
        ])
    }

    func testReviewHierarchyReplacesJoinedClipsWithExpandableParent() throws {
        let process = try RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["one", "two", "three"]
        ).merging(groupIDs: ["one", "two"])

        let items = RoughCutReviewHierarchy.items(
            regionIDsInSourceOrder: ["one", "rejected", "two", "three"],
            visibleRegionIDs: ["one", "rejected", "two", "three"],
            process: process
        )

        XCTAssertEqual(items.map(\.regionIDs), [
            ["one", "two"],
            ["rejected"],
            ["three"],
        ])
        XCTAssertTrue(items[0].isJoinedParent)
        XCTAssertEqual(items[0].groupID, process.groups[0].id)
        XCTAssertNil(items[1].groupID)
    }

    func testCodexJoinSuggestionsKeepOnlyContiguousAcceptedClips() throws {
        let response = try JSONDecoder().decode(
            RoughCutJoinSuggestionResponse.self,
            from: Data(
                """
                {
                  "suggestions": [
                    {
                      "region_ids": ["one", "two"],
                      "confidence": 0.94,
                      "reason": "The first clip ends mid-sentence."
                    },
                    {
                      "region_ids": ["one", "three"],
                      "confidence": 0.81,
                      "reason": "Not actually adjacent."
                    },
                    {
                      "region_ids": ["missing", "four"],
                      "confidence": 0.76,
                      "reason": "Contains an unknown clip."
                    },
                    {
                      "region_ids": ["four"],
                      "confidence": 0.72,
                      "reason": "Only one clip."
                    }
                  ]
                }
                """.utf8
            )
        )

        let validated = RoughCutJoinSuggestionValidator.validated(
            response.suggestions,
            acceptedRegionIDs: ["one", "two", "three", "four"]
        )

        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated[0].regionIDs, ["one", "two"])
        XCTAssertEqual(validated[0].confidence, 0.94, accuracy: 0.001)
    }

    func testLegacyJoinSuggestionsLoadAsAwaitingAndDecisionsRoundTrip() throws {
        let legacy = try JSONDecoder().decode(
            RoughCutJoinSuggestionResponse.self,
            from: Data(
                """
                {
                  "suggestions": [{
                    "region_ids": ["one", "two"],
                    "confidence": 0.94,
                    "reason": "The sentence continues."
                  }]
                }
                """.utf8
            )
        )

        XCTAssertEqual(legacy.suggestions[0].decision, .pending)

        var rejected = legacy.suggestions[0]
        rejected.decision = .rejected
        let encoded = try JSONEncoder().encode(
            RoughCutJoinSuggestionResponse(suggestions: [rejected])
        )
        let decoded = try JSONDecoder().decode(
            RoughCutJoinSuggestionResponse.self,
            from: encoded
        )
        XCTAssertEqual(decoded.suggestions[0].decision, .rejected)
    }

    func testJoinSuggestionReconciliationPreservesDecisionsAndOlderProposals() {
        let previous = [
            RoughCutJoinSuggestion(
                regionIDs: ["one", "two"],
                confidence: 0.8,
                reason: "Old reason",
                decision: .rejected
            ),
            RoughCutJoinSuggestion(
                regionIDs: ["three", "four"],
                confidence: 0.7,
                reason: "Keep this older proposal",
                decision: .pending
            ),
        ]
        let refreshed = [
            RoughCutJoinSuggestion(
                regionIDs: ["one", "two"],
                confidence: 0.96,
                reason: "Better current reason",
                decision: .pending
            ),
            RoughCutJoinSuggestion(
                regionIDs: ["four", "five"],
                confidence: 0.91,
                reason: "New proposal",
                decision: .pending
            ),
        ]

        let reconciled = RoughCutJoinSuggestionReconciler.reconcile(
            refreshed: refreshed,
            previous: previous,
            acceptedRegionIDs: ["one", "two", "three", "four", "five"]
        )

        XCTAssertEqual(reconciled.map(\.regionIDs), [
            ["one", "two"],
            ["three", "four"],
            ["four", "five"],
        ])
        XCTAssertEqual(reconciled[0].decision, .rejected)
        XCTAssertEqual(reconciled[0].reason, "Better current reason")
        XCTAssertEqual(reconciled[1].decision, .pending)
    }

    func testJoinApprovalAndUndoAreReversibleWithoutDeletingProposal() throws {
        let proposal = RoughCutJoinSuggestion(
            regionIDs: ["two", "three"],
            confidence: 0.95,
            reason: "One interrupted sentence.",
            decision: .pending
        )
        let initialProcess = RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["one", "two", "three", "four"]
        )

        let approved = try RoughCutJoinDecisionWorkflow.apply(
            .approved,
            to: proposal,
            process: initialProcess
        )
        XCTAssertEqual(approved.proposal.decision, .approved)
        XCTAssertEqual(approved.process.groups.map(\.regionIDs), [
            ["one"],
            ["two", "three"],
            ["four"],
        ])

        let undone = try RoughCutJoinDecisionWorkflow.apply(
            .pending,
            to: approved.proposal,
            process: approved.process
        )
        XCTAssertEqual(undone.proposal.decision, .pending)
        XCTAssertEqual(undone.process.groups.map(\.regionIDs), [
            ["one"],
            ["two"],
            ["three"],
            ["four"],
        ])

        let rejected = try RoughCutJoinDecisionWorkflow.apply(
            .rejected,
            to: approved.proposal,
            process: approved.process
        )
        XCTAssertEqual(rejected.proposal.decision, .rejected)
        XCTAssertEqual(rejected.process.groups.map(\.regionIDs), undone.process.groups.map(\.regionIDs))
    }

    func testCodexJoinSuggestionCommandIsEphemeralReadOnlyAndSchemaConstrained() {
        let arguments = CodexJoinSuggestionRunner.arguments(
            schemaURL: URL(fileURLWithPath: "/tmp/join-schema.json"),
            outputURL: URL(fileURLWithPath: "/tmp/join-output.json"),
            workingDirectoryURL: URL(fileURLWithPath: "/analysis/run")
        )

        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertEqual(
            Array(arguments[arguments.firstIndex(of: "--sandbox")!...].prefix(2)),
            ["--sandbox", "read-only"]
        )
        XCTAssertEqual(
            Array(arguments[arguments.firstIndex(of: "--output-schema")!...].prefix(2)),
            ["--output-schema", "/tmp/join-schema.json"]
        )
        XCTAssertEqual(
            Array(arguments[arguments.firstIndex(of: "-o")!...].prefix(2)),
            ["-o", "/tmp/join-output.json"]
        )
        XCTAssertTrue(arguments.contains("--skip-git-repo-check"))
    }

    func testSpeechJoinPlannerTrimsToWordHandlesAndUsesShortCrossfade() throws {
        let regions = try RoughCutPlan.decode(
            from: Data(
                """
                {
                  "schema_version": 1,
                  "source": {"filename": "camera.mov", "duration_seconds": 20},
                  "regions": [
                    {
                      "id": "one", "start": 1.00, "end": 4.20,
                      "text": "This sentence is", "decision": "keep", "confidence": 1,
                      "reason": "keep", "duplicate_of": null,
                      "has_transcript_evidence": true
                    },
                    {
                      "id": "two", "start": 8.00, "end": 10.40,
                      "text": "continued here.", "decision": "keep", "confidence": 1,
                      "reason": "keep", "duplicate_of": null,
                      "has_transcript_evidence": true
                    }
                  ]
                }
                """.utf8
            )
        ).regions
        let transcript = try RoughCutTranscript.decode(
            from: Data(
                """
                {
                  "schema_version": 1,
                  "segments": [
                    {
                      "start": 1.08, "end": 4.10, "text": "This sentence is",
                      "words": [
                        {"start": 1.08, "end": 1.30, "text": "This"},
                        {"start": 3.80, "end": 4.10, "text": "is"}
                      ]
                    },
                    {
                      "start": 8.07, "end": 10.31, "text": "continued here.",
                      "words": [
                        {"start": 8.07, "end": 8.50, "text": "continued"},
                        {"start": 10.00, "end": 10.31, "text": "here."}
                      ]
                    }
                  ]
                }
                """.utf8
            )
        )

        let plan = RoughCutSpeechJoinPlanner.plan(
            regions: regions,
            words: transcript.words,
            joinedPairs: [RoughCutRegionPair(left: "one", right: "two")]
        )

        XCTAssertEqual(plan.clips[0].sourceStart, 1.00, accuracy: 0.001)
        XCTAssertEqual(plan.clips[0].sourceEnd, 4.18, accuracy: 0.001)
        XCTAssertEqual(plan.clips[0].crossfadeAfter, 0.04, accuracy: 0.001)
        XCTAssertEqual(plan.clips[1].sourceStart, 8.01, accuracy: 0.001)
        XCTAssertEqual(plan.clips[1].sourceEnd, 10.39, accuracy: 0.001)
        XCTAssertEqual(plan.duration, 5.52, accuracy: 0.001)
    }

    func testReviewedCutPlannerOmitsRejectedSectionsAndPreservesApprovedJoins() throws {
        let regions = try RoughCutPlan.decode(
            from: Data(
                """
                {
                  "schema_version": 1,
                  "source": {"filename": "camera.mov", "duration_seconds": 20},
                  "regions": [
                    {
                      "id": "one", "start": 1.00, "end": 4.20,
                      "text": "This sentence is", "decision": "keep", "confidence": 1,
                      "reason": "keep", "duplicate_of": null,
                      "has_transcript_evidence": true
                    },
                    {
                      "id": "rejected", "start": 4.20, "end": 8.00,
                      "text": "A false start", "decision": "drop", "confidence": 1,
                      "reason": "false_start", "duplicate_of": "one",
                      "has_transcript_evidence": true
                    },
                    {
                      "id": "two", "start": 8.00, "end": 10.40,
                      "text": "continued here.", "decision": "keep", "confidence": 1,
                      "reason": "keep", "duplicate_of": null,
                      "has_transcript_evidence": true
                    },
                    {
                      "id": "three", "start": 12.00, "end": 14.00,
                      "text": "A complete next sentence.", "decision": "keep", "confidence": 1,
                      "reason": "keep", "duplicate_of": null,
                      "has_transcript_evidence": true
                    }
                  ]
                }
                """.utf8
            )
        ).regions
        let transcript = try RoughCutTranscript.decode(
            from: Data(
                """
                {
                  "schema_version": 1,
                  "segments": [
                    {
                      "start": 1.08, "end": 4.10, "text": "This sentence is",
                      "words": [
                        {"start": 1.08, "end": 1.30, "text": "This"},
                        {"start": 3.80, "end": 4.10, "text": "is"}
                      ]
                    },
                    {
                      "start": 8.07, "end": 10.31, "text": "continued here.",
                      "words": [
                        {"start": 8.07, "end": 8.50, "text": "continued"},
                        {"start": 10.00, "end": 10.31, "text": "here."}
                      ]
                    }
                  ]
                }
                """.utf8
            )
        )
        let process = try RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["one", "two", "three"]
        ).merging(groupIDs: ["one", "two"])

        let plan = RoughCutReviewedCutPlanner.plan(
            regions: regions,
            words: transcript.words,
            process: process
        )

        XCTAssertEqual(plan.clips.map(\.regionID), ["one", "two", "three"])
        XCTAssertEqual(plan.clips[0].crossfadeAfter, 0.04, accuracy: 0.001)
        XCTAssertEqual(plan.clips[1].sourceStart, 8.01, accuracy: 0.001)
        XCTAssertEqual(plan.clips[2].sourceStart, 12.00, accuracy: 0.001)
        XCTAssertEqual(plan.clips[2].sourceEnd, 14.00, accuracy: 0.001)
        XCTAssertEqual(plan.duration, 7.52, accuracy: 0.001)
    }

    func testFilteredPlaybackUsesOnlyVisibleClipsAndStartsAtClickedClip() {
        let regions = [
            region(id: "one", text: "First"),
            RoughCutRegion(
                id: "hidden",
                start: 4,
                end: 6,
                text: "Hidden",
                decision: "drop",
                confidence: 1,
                reason: "false_start",
                duplicateOf: nil,
                hasTranscriptEvidence: true
            ),
            RoughCutRegion(
                id: "three",
                start: 8,
                end: 10,
                text: "Third",
                decision: "keep",
                confidence: 1,
                reason: "keep",
                duplicateOf: nil,
                hasTranscriptEvidence: true
            ),
        ]
        let process = RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["one", "three"]
        )

        let plan = RoughCutFilteredPlaybackPlanner.plan(
            regions: regions,
            words: [],
            process: process,
            visibleRegionIDs: ["one", "three"],
            startingAt: "three"
        )

        XCTAssertEqual(plan.clips.map(\.regionID), ["three"])
        XCTAssertEqual(plan.clips[0].sourceStart, 8, accuracy: 0.001)
        XCTAssertEqual(plan.clips[0].sourceEnd, 10, accuracy: 0.001)
    }

    func testFilteredPlaybackStartsAtFirstVisibleChildWhenClickedJoinChildIsHidden() throws {
        let regions = [
            region(id: "before", text: "Before"),
            RoughCutRegion(
                id: "hidden-child",
                start: 4,
                end: 6,
                text: "Hidden",
                decision: "keep",
                confidence: 1,
                reason: "keep",
                duplicateOf: nil,
                hasTranscriptEvidence: true
            ),
            RoughCutRegion(
                id: "visible-child",
                start: 8,
                end: 10,
                text: "Visible",
                decision: "keep",
                confidence: 1,
                reason: "keep",
                duplicateOf: nil,
                hasTranscriptEvidence: true
            ),
        ]
        let process = try RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["before", "hidden-child", "visible-child"]
        ).merging(groupIDs: ["hidden-child", "visible-child"])

        let plan = RoughCutFilteredPlaybackPlanner.plan(
            regions: regions,
            words: [],
            process: process,
            visibleRegionIDs: ["before", "visible-child"],
            startingAt: "hidden-child"
        )

        XCTAssertEqual(plan.clips.map(\.regionID), ["visible-child"])
    }

    func testFilteredPlaybackStartsAtTheClickedVisibleChildInsideAJoin() throws {
        let regions = [
            region(id: "one", text: "One"),
            region(id: "two", text: "Two", start: 4, end: 6),
            region(id: "three", text: "Three", start: 8, end: 10),
        ]
        let process = try RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["one", "two", "three"]
        ).merging(groupIDs: ["one", "two", "three"])

        let plan = RoughCutFilteredPlaybackPlanner.plan(
            regions: regions,
            words: [],
            process: process,
            visibleRegionIDs: ["one", "two", "three"],
            startingAt: "two"
        )

        XCTAssertEqual(plan.clips.map(\.regionID), ["two", "three"])
    }

    func testFilteredPlaybackDoesNotInventAJoinAcrossAHiddenMiddleChild() throws {
        let regions = [
            region(id: "one", text: "One"),
            region(id: "two", text: "Two", start: 4, end: 6),
            region(id: "three", text: "Three", start: 8, end: 10),
        ]
        let process = try RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["one", "two", "three"]
        ).merging(groupIDs: ["one", "two", "three"])

        let plan = RoughCutFilteredPlaybackPlanner.plan(
            regions: regions,
            words: [],
            process: process,
            visibleRegionIDs: ["one", "three"]
        )

        XCTAssertEqual(plan.clips.map(\.regionID), ["one", "three"])
        XCTAssertEqual(plan.clips[0].crossfadeAfter, 0, accuracy: 0.001)
    }

    func testRoughCutProcessReconcilesDecisionsAndPersistsVisualPlans() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var process = try RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["one", "two", "three"]
        ).merging(groupIDs: ["one", "two"])
        let mergedID = process.groups[0].id
        process = process.assigningVisual(
            RoughCutVisualPlan(
                layout: .screencastWithCamera,
                detail: "Dashboard walkthrough.mov"
            ),
            toGroupIDs: [mergedID]
        )

        let reconciled = process.reconciled(
            acceptedRegionIDs: ["one", "two", "four"]
        )
        XCTAssertEqual(reconciled.groups.map(\.regionIDs), [
            ["one", "two"],
            ["four"],
        ])
        XCTAssertEqual(reconciled.groups[0].visual.layout, .screencastWithCamera)
        XCTAssertEqual(reconciled.groups[0].visual.detail, "Dashboard walkthrough.mov")

        let store = RoughCutProcessStore(analysisDirectoryURL: root)
        try store.save(reconciled)
        XCTAssertEqual(try store.load(), reconciled)
        let json = String(
            data: try Data(contentsOf: store.processURL),
            encoding: .utf8
        )
        XCTAssertTrue(json?.contains("\"region_ids\"") == true)
        XCTAssertFalse(json?.contains("\"region_i_ds\"") == true)

        let reset = reconciled.assigningVisual(
            RoughCutVisualPlan(layout: .unassigned, detail: "stale media.mov"),
            toGroupIDs: [reconciled.groups[0].id]
        )
        XCTAssertEqual(reset.groups[0].visual, .unassigned)

        try Data(
            """
            {
              "schema_version": 1,
              "groups": [{
                "id": "legacy",
                "region_i_ds": ["legacy"],
                "visual": {"layout": "unassigned", "detail": "stale.mov"}
              }]
            }
            """.utf8
        ).write(to: store.processURL)
        let migrated = try store.loadOrCreate(acceptedRegionIDs: ["legacy"])
        XCTAssertEqual(migrated.groups[0].regionIDs, ["legacy"])
        XCTAssertEqual(migrated.groups[0].visual, .unassigned)
    }

    func testSelectingAVisualLayoutBuildsThePlanThatIsSavedImmediately() {
        XCTAssertEqual(
            RoughCutVisualEditor.plan(
                selecting: .screencastWithCamera,
                detail: "Dashboard walkthrough.mov"
            ),
            RoughCutVisualPlan(
                layout: .screencastWithCamera,
                detail: "Dashboard walkthrough.mov"
            )
        )
        XCTAssertEqual(
            RoughCutVisualEditor.plan(
                selecting: .talkingHeadFullScreen,
                detail: "stale media.mov"
            ),
            RoughCutVisualPlan(
                layout: .talkingHeadFullScreen,
                detail: ""
            )
        )
    }

    func testVisualPlansTrackAISuggestionsAndManualOverrides() throws {
        let legacy = try JSONDecoder().decode(
            RoughCutVisualPlan.self,
            from: Data(
                """
                {"layout":"talkingHeadFullScreen","detail":""}
                """.utf8
            )
        )
        XCTAssertEqual(legacy.origin, .human)
        XCTAssertFalse(legacy.isAISuggested)

        let suggested = RoughCutVisualPlan(
            layout: .aiBRollFullScreen,
            detail: "Show an agent tangled in spaghetti.",
            origin: .aiSuggested
        )
        XCTAssertTrue(suggested.isAISuggested)

        let overridden = RoughCutVisualEditor.plan(
            selecting: suggested.layout,
            detail: "Show an agent choosing a safer path."
        )
        XCTAssertEqual(overridden.origin, .human)
        XCTAssertFalse(overridden.isAISuggested)
    }

    func testVisualSuggestionsPreserveHumansAndCanRefreshPreviousAISuggestions() {
        let process = RoughCutProcessDocument.initial(
            acceptedRegionIDs: ["human", "old-ai", "empty"]
        ).assigningVisual(
            RoughCutVisualPlan(layout: .talkingHeadFullScreen, detail: ""),
            toGroupIDs: ["human"]
        ).assigningSuggestedVisuals(
            [
                "old-ai": RoughCutVisualPlan(
                    layout: .aiBRollFullScreen,
                    detail: "Old suggestion.",
                    origin: .aiSuggested
                ),
            ]
        )
        let updated = process.assigningSuggestedVisuals([
            "human": RoughCutVisualPlan(
                layout: .aiBRollFullScreen,
                detail: "Do not replace this.",
                origin: .aiSuggested
            ),
            "old-ai": RoughCutVisualPlan(
                layout: .screenRecordingFullScreen,
                detail: "Replacement suggestion.",
                origin: .aiSuggested
            ),
            "empty": RoughCutVisualPlan(
                layout: .screenRecordingFullScreen,
                detail: "Show the relevant documentation page.",
                origin: .aiSuggested
            ),
        ])

        XCTAssertEqual(updated.groups[0].visual.layout, .talkingHeadFullScreen)
        XCTAssertEqual(updated.groups[0].visual.origin, .human)
        XCTAssertEqual(updated.groups[1].visual.detail, "Replacement suggestion.")
        XCTAssertEqual(updated.groups[1].visual.origin, .aiSuggested)
        XCTAssertEqual(updated.groups[2].visual.layout, .screenRecordingFullScreen)
        XCTAssertEqual(updated.groups[2].visual.origin, .aiSuggested)
    }

    func testVisualSuggestionValidatorRejectsUnknownInvalidAndDuplicateResults() {
        let suggestions = [
            RoughCutVisualSuggestion(
                groupID: "one",
                layout: .screenRecordingFullScreen,
                detail: "Show the Convex documentation."
            ),
            RoughCutVisualSuggestion(
                groupID: "one",
                layout: .aiBRollFullScreen,
                detail: "Duplicate."
            ),
            RoughCutVisualSuggestion(
                groupID: "two",
                layout: .unassigned,
                detail: ""
            ),
            RoughCutVisualSuggestion(
                groupID: "three",
                layout: .talkingHeadFullScreen,
                detail: ""
            ),
        ]

        let validated = RoughCutVisualSuggestionValidator.validated(
            suggestions,
            targetGroupIDs: ["one", "two"]
        )

        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated["one"]?.layout, .screenRecordingFullScreen)
        XCTAssertEqual(validated["one"]?.origin, .aiSuggested)
    }

    func testVisualSuggestionRequestIncludesHumanExamplesAndUnplannedTargets() throws {
        let clips = [
            RoughCutVisualSuggestionClip(
                groupID: "one",
                clipNumber: 1,
                transcript: "Show the index documentation.",
                currentVisual: RoughCutVisualPlan(
                    layout: .screenRecordingFullScreen,
                    detail: "Show the Convex index docs."
                )
            ),
            RoughCutVisualSuggestionClip(
                groupID: "two",
                clipNumber: 2,
                transcript: "This unlocks realtime updates.",
                currentVisual: .unassigned
            ),
        ]

        let data = try CodexVisualSuggestionRunner.requestData(clips: clips)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedClips = try XCTUnwrap(json["clips"] as? [[String: Any]])

        XCTAssertEqual(encodedClips.count, 2)
        XCTAssertEqual(encodedClips[0]["group_id"] as? String, "one")
        XCTAssertEqual(
            (encodedClips[0]["current_visual"] as? [String: Any])?["layout"] as? String,
            RoughCutVisualLayout.screenRecordingFullScreen.rawValue
        )
        XCTAssertEqual(encodedClips[1]["current_visual"] as? NSNull, NSNull())
    }

    func testVisualSuggestionPromptIncludesProductionSafetyAndContinuityRules() {
        let prompt = CodexVisualSuggestionRunner.prompt.lowercased()

        XCTAssertTrue(prompt.contains("never invent product ui"))
        XCTAssertTrue(prompt.contains("one continuous recording session"))
        XCTAssertTrue(prompt.contains("shared visual system"))
        XCTAssertTrue(prompt.contains("sourcing note"))
        XCTAssertTrue(prompt.contains("screen recording"))
        XCTAssertTrue(prompt.contains("real reproduction plan"))
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

    func testReviewedPlanUsesSpeechTightBoundariesForJoinedFilmoraExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("rough-cut-plan.json")
        let output = root.appendingPathComponent("reviewed-plan.json")
        let sourceData = Data(
            """
            {
              "schema_version": 1,
              "source": {"filename": "camera.mov", "duration_seconds": 20.0},
              "keep_ranges": [{"start": 1.0, "end": 4.2}, {"start": 8.0, "end": 10.4}],
              "regions": [
                {"id": "one", "start": 1.0, "end": 4.2, "text": "This sentence is", "decision": "keep", "confidence": 1.0, "reason": "keep", "duplicate_of": null, "has_transcript_evidence": true},
                {"id": "two", "start": 8.0, "end": 10.4, "text": "continued here.", "decision": "keep", "confidence": 1.0, "reason": "keep", "duplicate_of": null, "has_transcript_evidence": true}
              ]
            }
            """.utf8
        )
        try sourceData.write(to: source)
        let joinedPlan = RoughCutPlaybackPlan(clips: [
            RoughCutPlaybackClip(
                regionID: "one",
                sourceStart: 1.0,
                sourceEnd: 4.18,
                crossfadeAfter: 0.04
            ),
            RoughCutPlaybackClip(
                regionID: "two",
                sourceStart: 8.01,
                sourceEnd: 10.39,
                crossfadeAfter: 0
            ),
        ])

        try RoughCutReviewedPlanWriter().write(
            sourcePlanURL: source,
            outputURL: output,
            overrides: [:],
            playbackPlan: joinedPlan
        )

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        )
        let keepRanges = try XCTUnwrap(payload["keep_ranges"] as? [[String: Any]])
        XCTAssertEqual(keepRanges.count, 2)
        XCTAssertEqual(keepRanges[0]["start"] as? Double ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(keepRanges[0]["end"] as? Double ?? -1, 4.18, accuracy: 0.001)
        XCTAssertEqual(keepRanges[1]["start"] as? Double ?? -1, 8.01, accuracy: 0.001)
        XCTAssertEqual(keepRanges[1]["end"] as? Double ?? -1, 10.39, accuracy: 0.001)

        // Keep the planner evidence intact. The export-only source ranges belong
        // in keep_ranges, not in the original detected region boundaries.
        let regions = try XCTUnwrap(payload["regions"] as? [[String: Any]])
        XCTAssertEqual(regions[0]["end"] as? Double, 4.2)
        XCTAssertEqual(regions[1]["start"] as? Double, 8.0)
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

    func testTimelineInteractionFindsTheVisualClipUnderThePlayhead() {
        let regions = [
            region(id: "one", text: "First", start: 0, end: 4),
            region(id: "two", text: "Second", start: 5, end: 8),
        ]
        let groups = [
            RoughCutStoryBeat(
                id: "clip-one",
                regionIDs: ["one"],
                visual: .unassigned
            ),
            RoughCutStoryBeat(
                id: "clip-two",
                regionIDs: ["two"],
                visual: .unassigned
            ),
        ]

        XCTAssertEqual(
            RoughCutTimelineInteraction.groupID(
                at: 2,
                regions: regions,
                groups: groups
            ),
            "clip-one"
        )
        XCTAssertEqual(
            RoughCutTimelineInteraction.groupID(
                at: 6,
                regions: regions,
                groups: groups
            ),
            "clip-two"
        )
        XCTAssertNil(
            RoughCutTimelineInteraction.groupID(
                at: 4.5,
                regions: regions,
                groups: groups
            )
        )
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
