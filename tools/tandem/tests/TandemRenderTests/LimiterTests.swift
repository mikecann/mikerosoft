import XCTest
import TandemMedia
@testable import TandemRender

final class LimiterTests: XCTestCase {
    /// Interleaved stereo sine.
    func sine(amplitude: Double, frequency: Double, seconds: Double, phase: Double = 0, rate: Double = 48_000) -> [Float] {
        let frames = Int(seconds * rate)
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / rate + phase))
            out[2 * i] = v
            out[2 * i + 1] = v
        }
        return out
    }

    /// Runs the limiter in uneven chunks, then drops the latency so the
    /// output lines up with the input.
    func limit(_ input: [Float], ceiling: Double) -> [Float] {
        var limiter = TruePeakLimiter(channels: 2, ceilingDBTP: ceiling)
        var output: [Float] = []
        var start = 0
        var chunk = 700
        while start < input.count / 2 {
            let end = min(input.count / 2, start + chunk)
            var piece = Array(input[(start * 2)..<(end * 2)])
            limiter.process(&piece)
            output += piece
            start = end
            chunk = chunk == 700 ? 1301 : 700
        }
        output += limiter.flush()
        return Array(output.dropFirst(limiter.latency * 2))
    }

    func truePeak(_ samples: [Float]) -> Double {
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        meter.process(interleaved: samples)
        return meter.truePeak
    }

    func testQuietSignalPassesUnchangedAndInSync() {
        let input = sine(amplitude: 0.1, frequency: 440, seconds: 0.5)
        let output = limit(input, ceiling: -1)
        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(output, input)
    }

    func testLoudSineIsHeldUnderTheCeiling() {
        let input = sine(amplitude: 1.4, frequency: 997, seconds: 0.5)
        let output = limit(input, ceiling: -1)
        XCTAssertLessThanOrEqual(truePeak(output), -1.0 + 0.05)
        // It limits rather than muting: the steady part sits near the ceiling.
        let steady = output[(12_000 * 2)..<(12_100 * 2)].map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(Double(steady), pow(10, -1.6 / 20))
    }

    func testInterSamplePeaksAreCaught() {
        // A quarter-rate sine 45 degrees off the sample grid: every sample
        // reads 3 dB under the real peak.
        let input = sine(amplitude: 0.97, frequency: 12_000, seconds: 0.25, phase: Double.pi / 4)
        let samplePeak = 20 * log10(Double(input.map { abs($0) }.max()!))
        XCTAssertLessThan(samplePeak, -2.5)
        XCTAssertGreaterThan(truePeak(input), -0.5)
        let output = limit(input, ceiling: -1)
        XCTAssertLessThanOrEqual(truePeak(output), -1.0 + 0.05)
    }

    func testAClickIsCaughtAndTheGainRecovers() {
        var input = sine(amplitude: 0.1, frequency: 220, seconds: 1)
        let click = 12_000
        input[click * 2] = 1.9
        input[click * 2 + 1] = -1.9
        let output = limit(input, ceiling: -1)
        let ceiling = Float(pow(10, -1.0 / 20))
        XCTAssertLessThanOrEqual(output.map { abs($0) }.max()!, ceiling)
        // 300 ms later the gain is back to (almost) unity.
        let later = click + 14_400
        for i in later..<(later + 100) {
            XCTAssertEqual(output[i * 2], input[i * 2], accuracy: 0.002)
        }
    }

    func testGainForTargetInterpolatesAcrossTheLimiter() {
        let points = [(gain: 14.25, lufs: -15.13), (gain: 15.0, lufs: -14.6), (gain: 15.75, lufs: -14.1), (gain: 16.75, lufs: -13.5)]
        XCTAssertEqual(ExportPipeline.gainForTarget(-14, points: points)!, 15.75 + 0.1 / 0.6, accuracy: 1e-9)
        // Beyond the loudest candidate it follows the last slope (0.6 dB/dB).
        XCTAssertEqual(ExportPipeline.gainForTarget(-13.2, points: points)!, 16.75 + 0.3 / 0.6, accuracy: 1e-9)
        // One point: assume a dB per dB.
        XCTAssertEqual(ExportPipeline.gainForTarget(-14, points: [(gain: 10, lufs: -16)])!, 12, accuracy: 1e-9)
        XCTAssertNil(ExportPipeline.gainForTarget(-14, points: [(gain: 10, lufs: -Double.infinity)]))
    }
}
