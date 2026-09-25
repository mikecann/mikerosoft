import Foundation
import XCTest
@testable import TandemAssets

/// A fresh folder under the system temp directory, removed at the end of
/// the test.
func makeTempFolder(_ name: String = "assets", file: StaticString = #filePath, line: UInt = #line) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tandem-assets-tests", isDirectory: true)
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension XCTestCase {
    /// A temp folder that's deleted when the test ends.
    func tempFolder(_ name: String = "assets") -> URL {
        let url = makeTempFolder(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func makeCatalog() throws -> AssetCatalog {
        try AssetCatalog(url: tempFolder("catalog").appendingPathComponent("catalog.sqlite"))
    }
}

/// A sample asset with sensible defaults for tests.
func sampleAsset(
    provider: String = "import",
    id: String,
    kind: AssetKind = .sfx,
    name: String,
    tags: [String] = [],
    summary: String? = nil,
    duration: Double? = nil,
    bpm: Double? = nil,
    hasAlpha: Bool = false,
    state: AssetState = .original,
    licence: LicenceClass = .noCredit,
    credit: String? = nil,
    popularity: Double? = nil
) -> Asset {
    Asset(
        provider: provider,
        providerID: id,
        kind: kind,
        name: name,
        tags: tags,
        summary: summary,
        duration: duration,
        bpm: bpm,
        hasAlpha: hasAlpha,
        state: state,
        licenceClass: licence,
        creditLine: credit,
        popularity: popularity
    )
}

/// Loads a recorded fixture committed next to the tests.
func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw AssetError.notFound("fixture \(name)")
    }
    return try Data(contentsOf: url)
}
