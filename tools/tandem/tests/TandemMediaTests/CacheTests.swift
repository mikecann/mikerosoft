import XCTest
@testable import TandemMedia

final class AnalysisCacheTests: TempFolderTestCase {
    func testKeyDependsOnEveryPart() {
        let base = AnalysisCache.key(fingerprint: "10-20-ab", kind: .proxy, algorithmVersion: 1, settings: "{}")
        XCTAssertEqual(base, AnalysisCache.key(fingerprint: "10-20-ab", kind: .proxy, algorithmVersion: 1, settings: "{}"))
        XCTAssertEqual(base.count, 64)
        XCTAssertNotEqual(base, AnalysisCache.key(fingerprint: "10-21-ab", kind: .proxy, algorithmVersion: 1, settings: "{}"))
        XCTAssertNotEqual(base, AnalysisCache.key(fingerprint: "10-20-ab", kind: .matte, algorithmVersion: 1, settings: "{}"))
        XCTAssertNotEqual(base, AnalysisCache.key(fingerprint: "10-20-ab", kind: .proxy, algorithmVersion: 2, settings: "{}"))
        XCTAssertNotEqual(base, AnalysisCache.key(fingerprint: "10-20-ab", kind: .proxy, algorithmVersion: 1, settings: "{\"q\":1}"))
    }

    func testResultAppearsOnlyWhenCommitted() throws {
        let cache = AnalysisCache(root: temp)
        let key = AnalysisCache.key(fingerprint: "f", kind: .loudness, algorithmVersion: 1, settings: "{}")
        let pending = try cache.begin(kind: .loudness, key: key)
        try Data(repeating: 1, count: 500).write(to: pending.folder.appendingPathComponent("loudness.json"))
        XCTAssertNil(cache.lookup(kind: .loudness, key: key), "half-written results must be invisible")

        let folder = try cache.commit(pending, fingerprint: "f", algorithmVersion: 1, settings: "{}", source: "a.wav")
        XCTAssertEqual(cache.lookup(kind: .loudness, key: key), folder)
        XCTAssertEqual(folder, temp.appendingPathComponent("loudness/\(key)", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.folder.path))
        let manifest = try XCTUnwrap(cache.manifest(kind: .loudness, key: key))
        XCTAssertEqual(manifest.files, ["loudness.json"])
        XCTAssertEqual(manifest.bytes, 500)
        XCTAssertEqual(manifest.source, "a.wav")
        XCTAssertGreaterThanOrEqual(cache.totalSize, 500)
    }

    func testCrashedWritesAreIgnoredThenCleanedUp() throws {
        let key = AnalysisCache.key(fingerprint: "f", kind: .proxy, algorithmVersion: 1, settings: "{}")
        let pending = try AnalysisCache(root: temp).begin(kind: .proxy, key: key)
        try Data(repeating: 1, count: 100).write(to: pending.folder.appendingPathComponent("proxy.mov"))

        // A later process sees only the temporary folder.
        let cache = AnalysisCache(root: temp)
        XCTAssertNil(cache.lookup(kind: .proxy, key: key))
        XCTAssertEqual(cache.totalSize, 0)
        cache.removeStaleTemporaryFolders(olderThan: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.folder.path))
    }

    func testAnotherProcessStillWritingIsLeftAlone() throws {
        let key = "busy"
        let pending = try AnalysisCache(root: temp).begin(kind: .matte, key: key)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: pending.folder.path)
        // The folder is old but the file in it was just written.
        try Data(repeating: 1, count: 100).write(to: pending.folder.appendingPathComponent("matte.mov"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: pending.folder.path)
        AnalysisCache(root: temp).removeStaleTemporaryFolders(olderThan: 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.folder.path))
    }

    func testInFlightWritesSurviveCleanup() throws {
        let cache = AnalysisCache(root: temp)
        let pending = try cache.begin(kind: .proxy, key: "k")
        cache.removeStaleTemporaryFolders(olderThan: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.folder.path))
        cache.discard(pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.folder.path))
    }

    func testSecondCommitOfTheSameKeyKeepsTheFirst() throws {
        let cache = AnalysisCache(root: temp)
        let a = try cache.begin(kind: .waveform, key: "same")
        let b = try cache.begin(kind: .waveform, key: "same")
        try Data("first".utf8).write(to: a.folder.appendingPathComponent("peaks.f32"))
        try Data("second".utf8).write(to: b.folder.appendingPathComponent("peaks.f32"))
        let first = try cache.commit(a, fingerprint: "f", algorithmVersion: 1, settings: "{}", source: "x")
        let second = try cache.commit(b, fingerprint: "f", algorithmVersion: 1, settings: "{}", source: "x")
        XCTAssertEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("peaks.f32"), encoding: .utf8), "first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.folder.path))
    }

    func testEvictsLeastRecentlyUsedFirst() throws {
        let cache = AnalysisCache(root: temp, sizeLimit: 1_000_000)
        var folders: [String: URL] = [:]
        for (index, key) in ["old", "middle", "new"].enumerated() {
            let pending = try cache.begin(kind: .thumbnails, key: key)
            try Data(repeating: 0, count: 10_000).write(to: pending.folder.appendingPathComponent("t.jpg"))
            folders[key] = try cache.commit(pending, fingerprint: key, algorithmVersion: 1, settings: "{}", source: key)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)], ofItemAtPath: folders[key]!.path)
        }
        // Using "old" makes it the most recent.
        _ = cache.lookup(kind: .thumbnails, key: "old")

        cache.sizeLimit = 25_000
        let removed = cache.evictIfNeeded()
        XCTAssertEqual(removed, ["thumbnails/middle"])
        XCTAssertNotNil(cache.lookup(kind: .thumbnails, key: "old"))
        XCTAssertNil(cache.lookup(kind: .thumbnails, key: "middle"))
        XCTAssertNotNil(cache.lookup(kind: .thumbnails, key: "new"))
        XCTAssertLessThanOrEqual(cache.totalSize, 25_000)
    }

    func testCommitEvictsOthersButNeverItself() throws {
        let cache = AnalysisCache(root: temp, sizeLimit: 15_000)
        let first = try cache.begin(kind: .proxy, key: "a")
        try Data(repeating: 0, count: 10_000).write(to: first.folder.appendingPathComponent("proxy.mov"))
        try cache.commit(first, fingerprint: "a", algorithmVersion: 1, settings: "{}", source: "a")
        let second = try cache.begin(kind: .proxy, key: "b")
        try Data(repeating: 0, count: 10_000).write(to: second.folder.appendingPathComponent("proxy.mov"))
        try cache.commit(second, fingerprint: "b", algorithmVersion: 1, settings: "{}", source: "b")
        XCTAssertNil(cache.lookup(kind: .proxy, key: "a"))
        XCTAssertNotNil(cache.lookup(kind: .proxy, key: "b"))
    }
}
