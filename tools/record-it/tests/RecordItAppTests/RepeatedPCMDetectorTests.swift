import Foundation
import XCTest
@testable import RecordItApp

final class RepeatedPCMDetectorTests: XCTestCase {
    func testFindsAnExactLoopWhenCallbackBoundariesDoNotAlignWithItsPeriod() {
        var detector = RepeatedPCMDetector(
            minimumPeriod: 0.5,
            maximumPeriod: 3,
            requiredMatchDuration: 1,
            retainedDuration: 5,
            analysisInterval: 0.1,
            needleFrameCount: 64
        )
        let sampleRate = 1_000.0
        let periodFrames = 800
        let period = Data((0 ..< periodFrames).flatMap { frame in
            withUnsafeBytes(of: UInt16(frame % 251).littleEndian, Array.init)
        })
        let stream = Data(repeating: period, count: 5)
        let callbackFrameCounts = [137, 251, 89, 313, 173, 211]

        var byteOffset = 0
        var callbackIndex = 0
        var detectedPeriod: TimeInterval?
        while byteOffset < stream.count, detectedPeriod == nil {
            let requestedBytes = callbackFrameCounts[callbackIndex % callbackFrameCounts.count] * 2
            let end = min(stream.count, byteOffset + requestedBytes)
            let chunk = PCMByteChunk(
                data: stream.subdata(in: byteOffset ..< end),
                frameCount: (end - byteOffset) / 2,
                sampleRate: sampleRate,
                bytesPerFrame: 2
            )
            detectedPeriod = detector.append(chunk)
            byteOffset = end
            callbackIndex += 1
        }

        XCTAssertEqual(detectedPeriod ?? 0, 0.8, accuracy: 0.001)
    }

    func testSimilarButNonIdenticalPCMDoesNotTrigger() {
        var detector = RepeatedPCMDetector(
            minimumPeriod: 0.5,
            maximumPeriod: 3,
            requiredMatchDuration: 1,
            retainedDuration: 5,
            analysisInterval: 0.1,
            needleFrameCount: 64
        )
        let sampleRate = 1_000.0
        var detectedPeriod: TimeInterval?

        for callback in 0 ..< 50 {
            let samples = (0 ..< 100).map { UInt16(($0 + callback) % 251).littleEndian }
            let data = samples.withUnsafeBytes { Data($0) }
            detectedPeriod = detector.append(PCMByteChunk(
                data: data,
                frameCount: samples.count,
                sampleRate: sampleRate,
                bytesPerFrame: 2
            )) ?? detectedPeriod
        }

        XCTAssertNil(detectedPeriod)
    }

    func testLongChangingAudioRemainsSafeAfterHistoryIsTrimmed() {
        var detector = RepeatedPCMDetector(
            minimumPeriod: 0.5,
            maximumPeriod: 3,
            requiredMatchDuration: 1,
            retainedDuration: 5,
            analysisInterval: 0.1,
            needleFrameCount: 64
        )
        let sampleRate = 1_000.0

        for callback in 0 ..< 120 {
            let samples = (0 ..< 100).map {
                UInt16(($0 * 31 + callback * 47) % 65_521).littleEndian
            }
            let data = samples.withUnsafeBytes { Data($0) }
            XCTAssertNil(detector.append(PCMByteChunk(
                data: data,
                frameCount: samples.count,
                sampleRate: sampleRate,
                bytesPerFrame: 2
            )))
        }
    }
}

private extension Data {
    init(repeating pattern: Data, count: Int) {
        self.init()
        reserveCapacity(pattern.count * count)
        for _ in 0 ..< count {
            append(pattern)
        }
    }
}
