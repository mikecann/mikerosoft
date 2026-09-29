import CoreImage
import XCTest
import TandemCore
@testable import TandemRender

/// The Colour tab's whole-take sliders show on every clip of the file
/// while they're dragged, before the look is committed.
final class LookPreviewTests: XCTestCase {
    func testALookOverrideRegradesEveryClipOfTheFileUntilCleared() {
        let v1 = Track(kind: .video, name: "V1", clips: [
            Clip(id: "clip_a", content: .media(mediaID: "med_red"), start: .zero, duration: Time(seconds: 2)),
            Clip(id: "clip_b", content: .media(mediaID: "med_red"), start: Time(seconds: 2), duration: Time(seconds: 2))
        ])
        var h = CompositorHarness(smallProject(video: [v1], media: [redMedia]))
        h.pictures["med_red"] = solid(0.8, 0.1, 0.1)
        let overrides = LiveVideoOverrides()
        h.overrides = overrides
        let red = [204, 26, 26]
        assertColor(h.render(at: Time(seconds: 1))[160, 90], red)

        overrides.setLooks(["med_red": [Effect(type: "colorAdjust", params: ["saturation": .number(-100)])]])
        // The viewer hands over the selected clip's own properties with it.
        overrides.set(["clip_a": VideoProperties()])
        for time in [1.0, 3.0] {
            let pixel = h.render(at: Time(seconds: time))[160, 90]
            XCTAssertEqual(pixel[0], pixel[1], accuracy: 2, "grey at \(time) s: \(pixel)")
        }
        XCTAssertFalse(overrides.isEmpty)

        // The committed look is on screen: every preview goes.
        overrides.set([:])
        XCTAssertTrue(overrides.isEmpty)
        assertColor(h.render(at: Time(seconds: 3))[160, 90], red)
    }

    func testALookOverrideReplacesTheFilesLookRatherThanAddingToIt() {
        var media = redMedia
        media.look = [Effect(type: "colorAdjust", params: ["saturation": .number(-100)])]
        let v1 = Track(kind: .video, name: "V1", clips: [Clip(id: "clip_a", content: .media(mediaID: "med_red"), start: .zero, duration: Time(seconds: 2))])
        var h = CompositorHarness(smallProject(video: [v1], media: [media]))
        h.pictures["med_red"] = solid(0.8, 0.1, 0.1)
        let overrides = LiveVideoOverrides()
        h.overrides = overrides
        let grey = h.render(at: Time(seconds: 1))[160, 90]
        XCTAssertEqual(grey[0], grey[1], accuracy: 2)
        // Dragging saturation back to 0 shows the picture's own colour.
        overrides.setLooks(["med_red": [Effect(type: "colorAdjust", params: ["saturation": .number(0)])]])
        assertColor(h.render(at: Time(seconds: 1))[160, 90], [204, 26, 26])
    }
}
