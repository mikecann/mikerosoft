import XCTest
@testable import TandemMedia

final class FolderWatcherTests: TempFolderTestCase {
    /// Collects batches and lets a test wait for the next one.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [FolderWatcher.Changes] = []
        private var expectation: XCTestExpectation?

        func add(_ changes: FolderWatcher.Changes) {
            lock.lock()
            batches.append(changes)
            let waiting = expectation
            expectation = nil
            lock.unlock()
            waiting?.fulfill()
        }

        func expectBatch(_ test: XCTestCase, _ name: String) -> XCTestExpectation {
            let expectation = test.expectation(description: name)
            lock.withLock { self.expectation = expectation }
            return expectation
        }

        var all: [FolderWatcher.Changes] { lock.withLock { batches } }
        var merged: FolderWatcher.Changes {
            all.reduce(into: FolderWatcher.Changes()) { result, batch in
                result.added += batch.added
                result.changed += batch.changed
                result.removed += batch.removed
            }
        }
    }

    func testReportsAddedChangedAndRemovedMedia() throws {
        touch("music/existing.wav")
        let collector = Collector()
        let watcher = FolderWatcher(folder: ProjectFolder(root: temp), debounce: 0.1, settleTime: 0) { collector.add($0) }
        try watcher.start()
        defer { watcher.stop() }

        var next = collector.expectBatch(self, "added")
        touch("source/take-camera.mov", contents: "one")
        touch("notes.txt")
        touch(".tandem/cache/proxy/abc/proxy.mov")
        touch("exports/final.mp4")
        wait(for: [next], timeout: 5)
        XCTAssertEqual(collector.merged.added, ["source/take-camera.mov"])

        next = collector.expectBatch(self, "changed")
        try Data("one and more".utf8).write(to: file("source/take-camera.mov"))
        wait(for: [next], timeout: 5)
        XCTAssertEqual(collector.merged.changed, ["source/take-camera.mov"])

        next = collector.expectBatch(self, "removed")
        try FileManager.default.removeItem(at: file("music/existing.wav"))
        wait(for: [next], timeout: 5)
        XCTAssertEqual(collector.merged.removed, ["music/existing.wav"])
    }

    func testWaitsForAFileToSettle() throws {
        let collector = Collector()
        let watcher = FolderWatcher(folder: ProjectFolder(root: temp), debounce: 0.05, settleTime: 0.6) { collector.add($0) }
        try watcher.start()
        defer { watcher.stop() }

        let reported = collector.expectBatch(self, "settled")
        // A file that keeps growing, like a take being recorded.
        var lastWrite = Date()
        for i in 0..<4 {
            if i > 0 { Thread.sleep(forTimeInterval: 0.2) }
            try Data(repeating: UInt8(i), count: 1000 * (i + 1)).write(to: file("growing.mov"))
            lastWrite = Date()
        }
        wait(for: [reported], timeout: 5)
        XCTAssertEqual(collector.all.count, 1, "reported once, not once per write")
        XCTAssertEqual(collector.merged.added, ["growing.mov"])
        // Modification times are kept to the millisecond, so allow a little.
        XCTAssertGreaterThan(Date().timeIntervalSince(lastWrite), 0.55, "only once it stopped changing for the settle time")
    }

    func testCacheAndExportFoldersNeverTriggerARescan() throws {
        let collector = Collector()
        let watcher = FolderWatcher(folder: ProjectFolder(root: temp), debounce: 0.05, settleTime: 0) { collector.add($0) }
        try watcher.start()
        defer { watcher.stop() }
        for i in 0..<3 {
            try FileManager.default.createDirectory(at: file(".tandem/cache/proxy/.tmp-\(i)"), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file(".tandem/cache/proxy/.tmp-\(i)"), to: file(".tandem/cache/proxy/key\(i)"))
            try FileManager.default.createDirectory(at: file("exports/render\(i)"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: file("exports"), withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(watcher.rescans, 0)
        XCTAssertTrue(collector.all.isEmpty)

        // A new folder of media is looked at.
        let next = collector.expectBatch(self, "new folder")
        try FileManager.default.createDirectory(at: file("broll"), withIntermediateDirectories: true)
        touch("broll/clip.mov")
        wait(for: [next], timeout: 5)
        XCTAssertEqual(collector.merged.added, ["broll/clip.mov"])
    }

    func testStopEndsReporting() throws {
        let collector = Collector()
        let watcher = FolderWatcher(folder: ProjectFolder(root: temp), debounce: 0.05, settleTime: 0) { collector.add($0) }
        try watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
        touch("late.wav")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(collector.all.isEmpty)
    }
}
