import AppKit
import SwiftUI
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// How long the Colour tab takes to redraw after an edit, the way the app
/// hosts it (a real editor model, laid out and drawn in a window), with
/// all its sections open and with one at a time:
///
///     TANDEM_COLOUR_TIMING=1 swift test -c release --package-path tools/tandem --filter ColourInspectorTiming
///
/// `TANDEM_COLOUR_TIMING_ONLY=mixer` opens just those sections and
/// `TANDEM_COLOUR_TIMING_STEPS=4000` runs long enough to `sample` it.
/// Other builds on the Mac move the numbers a lot; compare runs made
/// back to back.
@MainActor
final class ColourInspectorTiming: XCTestCase {
    private func measure(_ name: String, _ makeView: (EditorModel, Clip) -> AnyView) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-colour-timing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Timing.tandem"), name: "Timing", owner: .app)
        let model = EditorModel(session: session)
        defer { model.tearDown(); _ = model.session.close() }
        let camera = MediaItem(
            id: "med_camera", path: "source/take1-camera.mov", kind: .video, role: .camera, takeID: "take1",
            takeOffset: .zero, duration: t(600), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true
        )
        model.apply(EditBatch(label: "Build", commands: [.addMedia(item: camera), .placeMedia(mediaIDs: ["med_camera"], at: .zero, duration: t(600))]))
        // A few hundred clips, like the v14 edit.
        let first = model.project.track(named: "Camera")!.clips[0]
        model.apply(EditBatch(label: "Cuts", commands: stride(from: 598.0, to: 1, by: -2).map { .blade(at: t($0), clipIDs: [first.id]) }))
        model.apply(InspectorEdits.look("med_camera", [
            Effect(id: "fx_a", type: "colorAdjust", params: ["contrast": .number(25), "blackLevel": .number(-7)]),
            Effect(id: "fx_w", type: "colorWheels", params: ["shadowsHue": .number(200), "shadowsAmount": .number(12)]),
            Effect(id: "fx_h", type: "hsl", params: ["redSaturation": .number(-8)]),
            Effect(id: "fx_v", type: "vignette", params: ["amount": .number(-30)])
        ], label: "Grade"))
        let clip = model.project.track(named: "Camera")!.clips[10]
        print("clips on the timeline:", model.project.videoTracks.reduce(0) { $0 + $1.clips.count })

        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 330, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: makeView(model, clip).frame(width: 330, alignment: .top))
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        var edits: [Double] = []
        var updates: [Double] = []
        var draws: [Double] = []
        let count = Int(ProcessInfo.processInfo.environment["TANDEM_COLOUR_TIMING_STEPS"] ?? "") ?? 120
        for step in 0..<count {
            let start = ProcessInfo.processInfo.systemUptime
            model.apply(InspectorEdits.lookParam(model.project.media("med_camera")!, effectID: "fx_a", key: "contrast", value: .number(Double(20 + step % 10)), label: "Contrast"))
            let applied = ProcessInfo.processInfo.systemUptime
            // SwiftUI's update of the tab and its layout.
            RunLoop.main.run(until: Date())
            hosting.layoutSubtreeIfNeeded()
            let laidOut = ProcessInfo.processInfo.systemUptime
            // Drawing all of it, which the app only does for what changed.
            hosting.display()
            edits.append((applied - start) * 1000)
            updates.append((laidOut - applied) * 1000)
            draws.append((ProcessInfo.processInfo.systemUptime - laidOut) * 1000)
        }
        func line(_ name: String, _ times: [Double]) -> String {
            let sorted = times.dropFirst(5).sorted()
            return String(format: "%@: p50 %.2f ms, p90 %.2f ms, max %.2f ms", name, sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last!)
        }
        print("--", name)
        print(line("the edit (model.apply)", edits))
        print(line("the Colour tab's update and layout", updates))
        print(line("drawing the whole tab", draws))
    }

    func testRedrawAfterAnEdit() throws {
        guard ProcessInfo.processInfo.environment["TANDEM_COLOUR_TIMING"] == "1" else { throw XCTSkip("Set TANDEM_COLOUR_TIMING=1") }
        try measure("nothing but the project's revision") { model, _ in AnyView(Text("r\(model.revision)")) }
        let all = ColourSection.allCases.map(\.rawValue)
        let only = ProcessInfo.processInfo.environment["TANDEM_COLOUR_TIMING_ONLY"].map { [$0.split(separator: ",").map(String.init)] }
        for open in only ?? [[], ["light"], ["colour"], ["wheels"], ["mixer"], ["vignette"], all] {
            AppDefaults.store.set(all.filter { !open.contains($0) }.joined(separator: ","), forKey: "colourCollapsedSections")
            try measure("new tab, open: \(open.count == all.count ? "all" : open.joined(separator: ", "))") { model, clip in AnyView(ColourInspector(model: model, clip: clip)) }
        }
        AppDefaults.store.removeObject(forKey: "colourCollapsedSections")
    }
}
