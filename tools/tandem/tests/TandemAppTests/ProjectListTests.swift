import AppKit
import XCTest
@testable import TandemApp
@testable import TandemCore
import TandemMedia

final class ProjectListTests: XCTestCase {
    func testTheListOpensAtTheSizeItWasLeftAt() {
        let screen = CGSize(width: 1_440, height: 900)
        XCTAssertEqual(WelcomeSize.restore(nil, fitting: screen), WelcomeSize.minimum)
        XCTAssertEqual(WelcomeSize.restore(NSStringFromSize(NSSize(width: 900, height: 640)), fitting: screen), CGSize(width: 900, height: 640))
        XCTAssertEqual(WelcomeSize.restore(NSStringFromSize(NSSize(width: 3_000, height: 2_000)), fitting: screen), screen, "kept on screen")
        XCTAssertEqual(WelcomeSize.restore(NSStringFromSize(NSSize(width: 200, height: 100)), fitting: screen), WelcomeSize.minimum, "never smaller than the layout")
        XCTAssertEqual(WelcomeSize.restore("nonsense", fitting: screen), WelcomeSize.minimum)
    }

    func testIconsLiveBesideTheJournal() {
        let url = URL(fileURLWithPath: "/videos/static hosting/Static hosting v2.tandem")
        XCTAssertEqual(ProjectIconFile.url(for: url).path, "/videos/static hosting/.tandem/Static hosting v2.icon.png")
    }

    func testTheIconFrameIsATenthInWhenThereIsAPicture() {
        var project = Project.standard(name: "Frames")
        XCTAssertNil(ProjectIconFrame.time(in: project), "nothing to show")
        let solid = Clip(content: .solid(color: RGBA(r: 1, g: 0, b: 0)), start: t(0), duration: t(100))
        project.videoTracks[0].clips = [solid]
        XCTAssertEqual(ProjectIconFrame.time(in: project), t(10))
        // A gap at the tenth: a moment into the first picture instead.
        project.videoTracks[0].clips = [Clip(content: .solid(color: RGBA(r: 1, g: 0, b: 0)), start: t(40), duration: t(60))]
        XCTAssertEqual(ProjectIconFrame.time(in: project), t(41))
        project.videoTracks[0].hidden = true
        XCTAssertNil(ProjectIconFrame.time(in: project), "hidden tracks don't count")
    }

    func testSavesRefreshTheIconNowAndThen() {
        let now = Date()
        let recent = (date: now.addingTimeInterval(-30), revision: 4)
        let old = (date: now.addingTimeInterval(-600), revision: 4)
        XCTAssertTrue(ProjectIconSchedule.shouldRender(.opened, iconExists: false, last: nil, revision: 1, now: now))
        XCTAssertFalse(ProjectIconSchedule.shouldRender(.opened, iconExists: true, last: nil, revision: 1, now: now))
        XCTAssertFalse(ProjectIconSchedule.shouldRender(.saved, iconExists: true, last: recent, revision: 9, now: now), "not twice in two minutes")
        XCTAssertTrue(ProjectIconSchedule.shouldRender(.saved, iconExists: true, last: old, revision: 9, now: now))
        XCTAssertFalse(ProjectIconSchedule.shouldRender(.saved, iconExists: true, last: old, revision: 4, now: now), "nothing changed")
        XCTAssertTrue(ProjectIconSchedule.shouldRender(.saved, iconExists: true, last: nil, revision: 4, now: now), "the first save this run")
        XCTAssertTrue(ProjectIconSchedule.shouldRender(.closed, iconExists: true, last: recent, revision: 5, now: now), "closing always catches up")
        XCTAssertFalse(ProjectIconSchedule.shouldRender(.closed, iconExists: true, last: recent, revision: 4, now: now))
        XCTAssertTrue(ProjectIconSchedule.shouldRender(.closed, iconExists: false, last: recent, revision: 4, now: now))
    }

    func testAnIconIsARealFrameKeptInTheProjectFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Icon.tandem")
        var project = Project.standard(name: "Icon")
        project.videoTracks[1].clips = [Clip(content: .solid(color: RGBA(r: 0.9, g: 0.5, b: 0.1)), start: t(0), duration: t(5))]
        let file = ProjectIconFile.url(for: projectURL)
        let image = try await XCTUnwrapAsync(await ProjectIcons.make(project: project, folder: ProjectFolder(projectFile: projectURL), analysis: nil, file: file))
        XCTAssertLessThanOrEqual(image.width, Int(ProjectIconFile.size.width))
        XCTAssertLessThanOrEqual(image.height, Int(ProjectIconFile.size.height))
        XCTAssertFalse(ProjectIconFrame.isBlank(image))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // A project with nothing to show drops its old icon for the placeholder.
        let empty = await ProjectIcons.make(project: Project.standard(name: "Icon"), folder: ProjectFolder(projectFile: projectURL), analysis: nil, file: file)
        XCTAssertNil(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testBlackFramesDontMakeIcons() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        XCTAssertTrue(ProjectIconFrame.isBlank(try XCTUnwrap(context.makeImage())))
        context.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 18))
        XCTAssertFalse(ProjectIconFrame.isBlank(try XCTUnwrap(context.makeImage())))
    }

    func testDoubleClickingTheBarDoesWhatSystemSettingsSays() {
        XCTAssertEqual(TitleBarDoubleClick.action(nil), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.action("Maximize"), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.action("Fill"), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.action("Minimize"), .minimize)
        XCTAssertEqual(TitleBarDoubleClick.action("None"), .none)
    }
}

/// `XCTUnwrap` for an async value.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}

@MainActor
final class ProjectIconMenuTests: XCTestCase {
    func testOpenRecentShowsAPlaceholderUntilThereIsAnIcon() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-icon-\(UUID().uuidString)/None.tandem")
        let image = ProjectIcons.shared.menuImage(for: url)
        XCTAssertEqual(image.size, NSSize(width: 32, height: 18))
        XCTAssertTrue(image === ProjectIcons.menuPlaceholder, "never waits for the disk")
    }
}
