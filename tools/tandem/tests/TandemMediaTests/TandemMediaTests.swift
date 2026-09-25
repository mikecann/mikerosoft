import XCTest
@testable import TandemMedia

final class LoudnessMeterTests: XCTestCase {
    /// Stereo 1 kHz sine at `dbfs` on both channels.
    func sine(dbfs: Double, seconds: Double, rate: Double = 48_000, frequency: Double = 1000) -> [Float] {
        let amplitude = pow(10, dbfs / 20)
        let frames = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let value = Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / rate))
            samples[2 * i] = value
            samples[2 * i + 1] = value
        }
        return samples
    }

    func testEBUReferenceSine() {
        // EBU Tech 3341 case 1: stereo 1 kHz at -23 dBFS reads -23.0 LUFS.
        var meter = LoudnessMeter()
        meter.process(interleaved: sine(dbfs: -23, seconds: 5))
        XCTAssertEqual(meter.integrated, -23, accuracy: 0.1)
        XCTAssertEqual(meter.truePeak, -23, accuracy: 0.3)
        XCTAssertLessThan(meter.loudnessRange, 0.5)
    }

    func testRelativeGateIgnoresQuietPassages() {
        // EBU Tech 3341 case 3, shortened: -36, -23, -36 dBFS reads about
        // -23 LUFS because the quiet parts fall under the relative gate.
        // Ungated it would be -24.4. The blocks straddling each change pull
        // it down by about 0.1 LU at this length (0.02 at the full 60 s).
        var meter = LoudnessMeter()
        meter.process(interleaved: sine(dbfs: -36, seconds: 2))
        meter.process(interleaved: sine(dbfs: -23, seconds: 12))
        meter.process(interleaved: sine(dbfs: -36, seconds: 2))
        XCTAssertEqual(meter.integrated, -23, accuracy: 0.15)
    }

    func testSilenceIsMinusInfinity() {
        var meter = LoudnessMeter()
        meter.process(interleaved: [Float](repeating: 0, count: 96_000))
        XCTAssertEqual(meter.integrated, -.infinity)
    }

    func testTruePeakCatchesIntersamplePeaks() {
        // A sine at a quarter of the sample rate, phase shifted 45 degrees,
        // never hits its peak on a sample: samples read -3 dB, true peak 0.
        let rate = 48_000.0
        var samples = [Float]()
        for i in 0..<9_600 {
            let value = Float(sin(2 * Double.pi * 12_000 * Double(i) / rate + Double.pi / 4))
            samples += [value, value]
        }
        var meter = LoudnessMeter()
        meter.process(interleaved: samples)
        XCTAssertGreaterThan(meter.truePeak, -0.6)
    }
}

final class EncoderLockTests: XCTestCase {
    func testExportJumpsTheQueue() async {
        let lock = EncoderLock()
        await lock.acquire()
        actor Log { var order: [String] = []; func add(_ s: String) { order.append(s) } }
        let log = Log()
        let proxy = Task {
            await lock.acquire(priority: .background)
            await log.add("proxy")
            await lock.release()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let export = Task {
            await lock.acquire(priority: .export)
            await log.add("export")
            await lock.release()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await lock.release()
        _ = await (proxy.value, export.value)
        let order = await log.order
        XCTAssertEqual(order, ["export", "proxy"])
    }
}

final class ProjectFolderTests: XCTestCase {
    func testRelativeAndAbsolutePaths() {
        let folder = ProjectFolder(root: URL(fileURLWithPath: "/videos/decision"))
        XCTAssertEqual(folder.url(forPath: "source/a-camera.mov").path, "/videos/decision/source/a-camera.mov")
        XCTAssertEqual(folder.url(forPath: "/elsewhere/b.mov").path, "/elsewhere/b.mov")
        XCTAssertEqual(folder.path(for: URL(fileURLWithPath: "/videos/decision/music/bed.mp3")), "music/bed.mp3")
        XCTAssertEqual(folder.path(for: URL(fileURLWithPath: "/elsewhere/b.mov")), "/elsewhere/b.mov")
    }

    func testRoleGuesses() {
        XCTAssertEqual(MediaScanner.role(forPath: "source/2026-09-25 10.00-camera.mov"), .camera)
        XCTAssertEqual(MediaScanner.role(forPath: "edit/main-screen.mov"), .screen)
        XCTAssertEqual(MediaScanner.role(forPath: "music/c1a.mp3"), .music)
        XCTAssertEqual(MediaScanner.role(forPath: "sfx/whoosh.wav"), .sfx)
        XCTAssertEqual(MediaScanner.role(forPath: "broll/hf-decider.mp4"), .broll)
    }
}
