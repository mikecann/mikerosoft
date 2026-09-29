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

    func testRVMHasItsOwnCacheKeyAndVisionStaysTheDefault() {
        let standard = AnalysisSettings()
        XCTAssertEqual(standard.matteModel, .vision, "version 2 stays the default until Mike picks")
        var rvm = standard
        rvm.matteModel = .robustVideoMatting
        XCTAssertNotEqual(rvm.canonical(for: .matte), standard.canonical(for: .matte))
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

    func testWithoutTheModelTheJobFailsSayingWhy() async throws {
        let movie = temp.appendingPathComponent("take-camera.mov")
        try await SyntheticMedia.writeMovie(to: movie, .init(width: 320, height: 180, duration: 0.5))
        var settings = AnalysisSettings()
        settings.matteModel = .robustVideoMatting
        var tuning = MatteJob.Tuning()
        tuning.rvmStore = RVMModelStore(folder: temp.appendingPathComponent("Models/rvm", isDirectory: true), fileName: "model.mlmodel",
                                        remote: URL(string: "https://example.invalid/model.mlmodel")!, sha256: String(repeating: "0", count: 64),
                                        fetch: { _ in throw URLError(.notConnectedToInternet) })
        let folder = temp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try await MatteJob.run(source: movie, settings: settings, into: folder, context: JobContext(id: "rvm", kind: .matte, qos: .utility, scheduler: nil), tuning: tuning)
            XCTFail("no model, no matte")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("RVM"), error.localizedDescription)
        }
    }
}
