import XCTest
@testable import TokenStatsApp

final class UsageParsingTests: XCTestCase {
    func testCodexParserUsesCumulativeDeltasAndCurrentTurnModel() throws {
        let lines = [
            #"{"timestamp":"2026-07-25T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-25T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":20,"output_tokens":100}}}}"#,
            #"{"timestamp":"2026-07-25T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1600,"cached_input_tokens":900,"cache_write_input_tokens":20,"output_tokens":140}}}}"#
        ]

        let records = CodexUsageParser.parse(lines: lines, sourceID: "session")

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].model, "gpt-5.6-sol")
        XCTAssertEqual(records[0].inputTokens, 400)
        XCTAssertEqual(records[0].cachedInputTokens, 600)
        XCTAssertEqual(records[1].inputTokens, 300)
        XCTAssertEqual(records[1].cachedInputTokens, 300)
        XCTAssertEqual(records[1].outputTokens, 40)
    }

    func testCodexParserCanReadCappedTurnContextPrefix() {
        let lines = [
            #"{"timestamp":"2026-07-25T01:00:00Z","type":"turn_context","model":"gpt-5.5","developer_instructions":"capped"#,
            #"{"timestamp":"2026-07-25T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5}}}}"#
        ]

        let records = CodexUsageParser.parse(lines: lines, sourceID: "session")

        XCTAssertEqual(records.first?.model, "gpt-5.5")
    }

    func testClaudeParserKeepsLatestVersionOfStreamedMessage() throws {
        let lines = [
            #"{"timestamp":"2026-07-25T02:00:00Z","type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":200,"output_tokens":2}}}"#,
            #"{"timestamp":"2026-07-25T02:00:01Z","type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":200,"output_tokens":52}}}"#
        ]

        let records = ClaudeUsageParser.parse(lines: lines, sourceID: "session")

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inputTokens, 2)
        XCTAssertEqual(records[0].cacheWriteTokens, 100)
        XCTAssertEqual(records[0].cachedInputTokens, 200)
        XCTAssertEqual(records[0].outputTokens, 52)
    }

    func testOpenRouterCSVParserAcceptsActivityExportHeaders() throws {
        let csv = """
        Date,Model,Prompt Tokens,Completion Tokens,Total Cost
        2026-07-24,google/gemini-3.1-pro-preview,"1,200",300,$0.0124
        """

        let records = try OpenRouterCSVParser.parse(csv: csv, sourceID: "activity.csv")

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].provider, .openRouter)
        XCTAssertEqual(records[0].inputTokens, 1_200)
        XCTAssertEqual(records[0].outputTokens, 300)
        XCTAssertEqual(records[0].exactCostUSD ?? 0, 0.0124, accuracy: 0.000_001)
    }

    func testOpenRouterActivityParserUsesExactBilledUsage() throws {
        let json = Data(
            """
            {
              "data": [
                {
                  "date": "2026-07-24",
                  "model": "google/gemini-3.1-pro-preview",
                  "prompt_tokens": 1200,
                  "completion_tokens": 300,
                  "reasoning_tokens": 100,
                  "usage": 0.0124,
                  "byok_usage_inference": 0.004
                }
              ]
            }
            """.utf8
        )

        let records = try OpenRouterActivityParser.parse(data: json)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].provider, .openRouter)
        XCTAssertEqual(records[0].model, "google/gemini-3.1-pro-preview")
        XCTAssertEqual(records[0].inputTokens, 1_200)
        XCTAssertEqual(records[0].outputTokens, 300)
        // `usage` is what OpenRouter actually billed. BYOK inference is an
        // estimate for spend paid to another provider, so it must not be added.
        XCTAssertEqual(records[0].exactCostUSD ?? 0, 0.0124, accuracy: 0.000_001)
    }

    func testOpenRouterActivityParserCombinesRowsForTheSameModelAndDay() throws {
        let json = Data(
            """
            {
              "data": [
                {
                  "date": "2026-07-24",
                  "model": "anthropic/claude-sonnet-4",
                  "prompt_tokens": 100,
                  "completion_tokens": 20,
                  "usage": 0.01
                },
                {
                  "date": "2026-07-24",
                  "model": "anthropic/claude-sonnet-4",
                  "prompt_tokens": 200,
                  "completion_tokens": 30,
                  "usage": 0.02
                }
              ]
            }
            """.utf8
        )

        let records = try OpenRouterActivityParser.parse(data: json)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inputTokens, 300)
        XCTAssertEqual(records[0].outputTokens, 50)
        XCTAssertEqual(records[0].exactCostUSD ?? 0, 0.03, accuracy: 0.000_001)
    }

    func testOpenRouterActivityParserAcceptsLiveAPITimestampDates() throws {
        let payload = """
        {
          "data": [
            {
              "date": "2026-07-24 00:00:00",
              "model": "stepfun/step-3.7-flash",
              "prompt_tokens": 120,
              "completion_tokens": 30,
              "usage": 0.0042
            }
          ]
        }
        """

        let records = try OpenRouterActivityParser.parse(data: Data(payload.utf8))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.inputTokens, 120)
        XCTAssertEqual(records.first?.outputTokens, 30)
        XCTAssertEqual(records.first?.exactCostUSD, 0.0042)
    }
}
