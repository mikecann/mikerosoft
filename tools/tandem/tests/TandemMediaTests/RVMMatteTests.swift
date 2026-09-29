import CryptoKit
import Foundation
import TandemCore
import XCTest
@testable import TandemMedia

/// Robust Video Matting as a selectable matte method. These tests never
/// touch the network: the model store's download is swapped for a copy.
final class RVMMatteTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-rvm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A store for `weights` whose download hands over `served` (by default
    /// the right bytes) and counts how often it was asked.
    func store(for weights: Data, serving served: Data? = nil, downloads: Counter = Counter()) -> RVMModelStore {
        let temp = self.temp!
        return RVMModelStore(
            folder: temp.appendingPathComponent("Models/rvm", isDirectory: true),
            fileName: "model.mlmodel",
            remote: URL(string: "https://example.invalid/model.mlmodel")!,
            sha256: checksum(weights),
            fetch: { _ in
                downloads.increment()
                let file = temp.appendingPathComponent("download-\(UUID().uuidString)")
                try (served ?? weights).write(to: file)
                return file
            }
        )
    }

    func testAModelAlreadyInPlaceIsUsedWithoutDownloading() async throws {
        let weights = Data("weights".utf8)
        let downloads = Counter()
        let store = store(for: weights, downloads: downloads)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try weights.write(to: store.folder.appendingPathComponent("model.mlmodel"))
        let file = try await store.modelFile()
        XCTAssertEqual(try Data(contentsOf: file), weights)
        XCTAssertEqual(downloads.value, 0)
    }

    func testAMissingModelIsDownloadedOnceAndChecked() async throws {
        let weights = Data("weights".utf8)
        let downloads = Counter()
        let store = store(for: weights, downloads: downloads)
        let file = try await store.modelFile()
        XCTAssertEqual(file, store.folder.appendingPathComponent("model.mlmodel"))
        XCTAssertEqual(try Data(contentsOf: file), weights)
        _ = try await store.modelFile()
        XCTAssertEqual(downloads.value, 1)
    }

    func testADownloadThatDoesNotMatchItsChecksumIsRefused() async throws {
        let store = store(for: Data("weights".utf8), serving: Data("something else".utf8))
        do {
            _ = try await store.modelFile()
            XCTFail("a download with the wrong checksum must not be used")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("model.mlmodel").path))
    }

    func testADamagedModelIsDownloadedAgain() async throws {
        let weights = Data("weights".utf8)
        let downloads = Counter()
        let store = store(for: weights, downloads: downloads)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data("half a file".utf8).write(to: store.folder.appendingPathComponent("model.mlmodel"))
        let file = try await store.modelFile()
        XCTAssertEqual(try Data(contentsOf: file), weights)
        XCTAssertEqual(downloads.value, 1)
    }

    func testTheStandardStoreIsTheOfficialReleaseOutsideTheApp() {
        let store = RVMModelStore.standard
        XCTAssertTrue(store.folder.path.hasSuffix("Library/Application Support/Tandem/Models/rvm"), store.folder.path)
        XCTAssertEqual(store.remote.absoluteString,
                       "https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3_1280x720_s0.375_fp16.mlmodel")
        XCTAssertEqual(store.sha256.count, 64)
    }

    func testFramesAreLetterboxedIntoTheModelInput() {
        XCTAssertEqual(RVMMatte.contentRect(width: 3840, height: 2160), CGRect(x: 0, y: 0, width: 1280, height: 720))
        XCTAssertEqual(RVMMatte.contentRect(width: 1920, height: 1080, inputWidth: 1920, inputHeight: 1080), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(RVMMatte.contentRect(width: 1440, height: 1080, inputWidth: 1920, inputHeight: 1080), CGRect(x: 240, y: 0, width: 1440, height: 1080))
        XCTAssertEqual(RVMMatte.contentRect(width: 1080, height: 1920, inputWidth: 1920, inputHeight: 1080), CGRect(x: 656, y: 0, width: 608, height: 1080))
    }

    func testRVMIsTheDefaultWithItsOwnCacheKey() {
        let rvm = AnalysisSettings()
        XCTAssertEqual(rvm.matteModel, .robustVideoMatting, "Mike picked RVM")
        XCTAssertEqual(RVMMatte.version, 2, "version 1 RVM mattes had the light rim; they rebuild")
        var standard = rvm
        standard.matteModel = .vision
        XCTAssertNotEqual(rvm.canonical(for: .matte), standard.canonical(for: .matte), "Vision mattes rebuild as RVM ones")
        XCTAssertTrue(rvm.canonical(for: .matte).contains("\"rvm\":\"\(RVMMatte.version)\""), rvm.canonical(for: .matte))
        // Vision's knobs don't touch an RVM matte, and RVM keeps what the
        // person holds either way, so both cutout modes share one.
        var other = rvm
        other.matteQuality = .fast
        other.matteProps = .personInstances
        other.matteSmoothing = .off
        other.matteMode = .person
        XCTAssertEqual(other.canonical(for: .matte), rvm.canonical(for: .matte))
        var smaller = rvm
        smaller.matteMaxWidth = 1280
        smaller.matteMaxHeight = 720
        XCTAssertNotEqual(smaller.canonical(for: .matte), rvm.canonical(for: .matte))
        XCTAssertEqual(AnalysisKind.allCases.filter { standard.canonical(for: $0) != rvm.canonical(for: $0) }, [.matte])
    }

    func testWithoutTheModelTheJobFallsBackToVisionAndSaysWhy() async throws {
        let movie = temp.appendingPathComponent("take-camera.mov")
        try await SyntheticMedia.writeMovie(to: movie, .init(width: 320, height: 180, duration: 0.5))
        var tuning = MatteJob.Tuning()
        tuning.rvmStore = RVMModelStore(folder: temp.appendingPathComponent("Models/rvm", isDirectory: true), fileName: "model.mlmodel",
                                        remote: URL(string: "https://example.invalid/model.mlmodel")!, sha256: String(repeating: "0", count: 64),
                                        fetch: { _ in throw URLError(.notConnectedToInternet) })
        let folder = temp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = JobContext(id: "rvm", kind: .matte, qos: .utility, scheduler: nil)
        try await MatteJob.run(source: movie, settings: AnalysisSettings(), into: folder, context: context, tuning: tuning)
        let times = try await videoSampleTimes(folder.appendingPathComponent(MatteJob.file))
        let sourceTimes = try await videoSampleTimes(movie)
        XCTAssertEqual(times.count, sourceTimes.count, "a whole matte, made by Vision")
        let note = try XCTUnwrap(context.lastNote)
        XCTAssertTrue(note.contains("RVM") && note.contains("Vision"), note)
        let fallback = try XCTUnwrap(MatteFallback.read(from: folder))
        XCTAssertEqual(fallback.model, tuning.rvmStore.stamp(), "remembers the model file it couldn't use")
    }

    func testTheEdgeFixClearsTheFringeAndPullsTheEdgeInOnePixel() {
        // A soft edge across a row (a shoulder), and a finger 12 px wide.
        let width = 64, height = 8
        var alpha = [UInt8](repeating: 0, count: width * height)
        let ramp: [UInt8] = [10, 30, 60, 90, 130, 170, 210, 240]
        for y in 0..<height {
            for (i, value) in ramp.enumerated() { alpha[y * width + i] = value }
            for x in ramp.count..<24 { alpha[y * width + x] = 255 }
            for x in 40..<52 { alpha[y * width + x] = 255 }
        }
        RVMMatte.cleanEdge(&alpha, width: width, height: height)
        let row = Array(alpha[(3 * width)..<(4 * width)])
        XCTAssertEqual(Array(row[0..<4]), [0, 0, 0, 0], "the faint outer fringe goes")
        XCTAssertGreaterThan(row[6], 0, "the edge stays soft")
        XCTAssertEqual(Array(row[9..<23]), Array(repeating: 255, count: 14), "the solid part stays solid")
        XCTAssertEqual(row[23], 0, "pulled in by a pixel")
        XCTAssertEqual(Array(row[41..<51]), Array(repeating: 255, count: 10), "a finger loses a pixel each side, no more")
        XCTAssertEqual(row[40], 0)
    }
}
