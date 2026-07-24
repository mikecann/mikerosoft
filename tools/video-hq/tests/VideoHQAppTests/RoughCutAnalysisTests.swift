import Foundation
import XCTest
@testable import VideoHQApp

final class RoughCutAnalysisTests: XCTestCase {
    func testRoughCutProcessMovesDirectlyFromReviewToVisuals() {
        XCTAssertEqual(RoughCutProcessStage.allCases, [.review, .visuals])
        XCTAssertEqual(RoughCutProcessStage.review.label, "1. Review")
        XCTAssertEqual(RoughCutProcessStage.visuals.label, "2. Visuals")
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
