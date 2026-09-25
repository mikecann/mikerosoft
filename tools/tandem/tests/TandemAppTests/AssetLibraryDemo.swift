import AVFoundation
import XCTest
@testable import TandemApp
@testable import TandemAssets

/// Makes a scratch asset library for looking at the browser, so testing
/// never touches Mike's own library:
///
///     TANDEM_ASSET_DEMO_ROOT=/private/tmp/claude-501/tandem-app/assets-lib \
///     TANDEM_ASSET_DEMO_FOLDERS=/private/tmp/.../mike-music:/private/tmp/.../mike-sfx \
///     swift test --package-path tools/tandem --filter AssetLibraryDemo
///
/// Then launch the app with `TANDEM_ASSETS_ROOT` set to the same folder.
/// Skipped unless `TANDEM_ASSET_DEMO_ROOT` is set.
final class AssetLibraryDemo: XCTestCase {
    func testBuildScratchLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["TANDEM_ASSET_DEMO_ROOT"], !root.isEmpty else {
            throw XCTSkip("Set TANDEM_ASSET_DEMO_ROOT to build a scratch asset library")
        }
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let library = try AssetLibrary(root: url, previewFolder: url.appendingPathComponent("previews", isDirectory: true))
        try library.installStarterContent()
        for folder in (environment["TANDEM_ASSET_DEMO_FOLDERS"] ?? "").split(separator: ":") where !folder.isEmpty {
            let report = try await library.addImportFolder(URL(fileURLWithPath: String(folder), isDirectory: true))
            XCTAssertGreaterThan(report.added + report.unchanged, 0, String(folder))
        }
        XCTAssertGreaterThan(try library.count(AssetQuery()), 0)
    }
}

final class AssetMediaTests: XCTestCase {
    /// A second of silence then a second at half level: the peaks say so.
    func testPeaksFollowTheSound() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peaks-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            // The file is finished when the writer goes away.
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
            buffer.frameLength = 96_000
            for index in 0..<96_000 {
                buffer.floatChannelData![0][index] = index < 48_000 ? 0 : 0.5 * sin(Float(index) * 0.05)
            }
            try file.write(from: buffer)
        }

        let peaks = try XCTUnwrap(AssetMedia.peaks(of: url, count: 10))
        XCTAssertEqual(peaks.count, 10)
        XCTAssertEqual(peaks.prefix(5).max() ?? 1, 0, accuracy: 0.001)
        for peak in peaks.suffix(5) { XCTAssertEqual(peak, 0.5, accuracy: 0.02) }
    }
}
