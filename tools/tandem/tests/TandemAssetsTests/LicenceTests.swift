import XCTest
@testable import TandemAssets

final class LicenceTests: XCTestCase {
    func testLicenceSnapshotsKeepHistory() throws {
        let catalog = try makeCatalog()
        try catalog.upsert(sampleAsset(id: "a", name: "A"))
        let first = AssetLicence(name: "Old terms", licenceClass: .noCredit, text: "v1", capturedAt: Date(timeIntervalSince1970: 100))
        let second = AssetLicence(
            name: "CC BY 4.0", spdx: "CC-BY-4.0", licenceClass: .creditNeeded,
            url: URL(string: "https://creativecommons.org/licenses/by/4.0/"), text: "v2", holder: "Someone",
            creditLine: "Thing by Someone, CC BY 4.0", certificate: "CERT-1", sourceURL: URL(string: "https://example.com"),
            notes: "note", capturedAt: Date(timeIntervalSince1970: 200)
        )
        try catalog.addLicence(first, for: "import:a")
        try catalog.addLicence(second, for: "import:a")
        XCTAssertEqual(try catalog.licence(for: "import:a"), second)
        XCTAssertEqual(try catalog.licenceHistory(for: "import:a"), [first, second])
        XCTAssertNil(try catalog.licence(for: "import:missing"))
    }

    func testLicenceSurvivesDeletingTheAsset() throws {
        // Licence snapshots are proof of what was agreed; they outlive the row.
        let catalog = try makeCatalog()
        try catalog.upsert(sampleAsset(id: "a", name: "A"))
        try catalog.addLicence(AssetLicence(name: "Terms", licenceClass: .subscription), for: "import:a")
        try catalog.delete(id: "import:a")
        XCTAssertEqual(try catalog.licence(for: "import:a")?.name, "Terms")
    }

    func testSPDXClassification() {
        XCTAssertEqual(LicencePolicy.licenceClass(spdx: "MIT"), .noCredit)
        XCTAssertEqual(LicencePolicy.licenceClass(spdx: "Apache-2.0"), .noCredit)
        XCTAssertEqual(LicencePolicy.licenceClass(spdx: "OFL-1.1"), .noCredit)
        XCTAssertEqual(LicencePolicy.licenceClass(spdx: "CC0-1.0"), .noCredit)
        XCTAssertEqual(LicencePolicy.licenceClass(spdx: "CC-BY-4.0"), .creditNeeded)
        XCTAssertEqual(LicencePolicy.licenceClass(spdx: "CC-BY-3.0"), .creditNeeded)
        XCTAssertTrue(LicencePolicy.isExcluded(spdx: "GPL-3.0-or-later"))
        XCTAssertTrue(LicencePolicy.isExcluded(spdx: "CC-BY-SA-4.0"))
        XCTAssertTrue(LicencePolicy.isExcluded(spdx: "CC-BY-NC-4.0"))
        XCTAssertTrue(LicencePolicy.isExcluded(spdx: "CC-BY-NC-SA-4.0"))
        XCTAssertFalse(LicencePolicy.isExcluded(spdx: "MPL-2.0"))
        XCTAssertFalse(LicencePolicy.isExcluded(spdx: "CC-BY-4.0"))
        XCTAssertEqual(LicencePolicy.creativeCommonsURL(spdx: "CC-BY-4.0")?.absoluteString, "https://creativecommons.org/licenses/by/4.0/")
        XCTAssertEqual(LicencePolicy.creativeCommonsURL(spdx: "CC0-1.0")?.absoluteString, "https://creativecommons.org/publicdomain/zero/1.0/")
    }
}

final class LicenceTermsTests: XCTestCase {
    func testSameTermsIgnoresWhenTheyWereTaken() {
        let a = AssetLicence(name: "Mixkit", licenceClass: .noCredit, capturedAt: Date(timeIntervalSince1970: 1))
        var b = a
        b.capturedAt = Date(timeIntervalSince1970: 2)
        XCTAssertTrue(a.hasSameTerms(as: b))
        b.licenceClass = .subscription
        XCTAssertFalse(a.hasSameTerms(as: b))
    }
}
