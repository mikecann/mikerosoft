import CoreGraphics
import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// RGBA8 pixels of a rendered frame, addressed y down like the canvas.
struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CIImage, size: CGSize) {
        width = Int(size.width)
        height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        RenderEngine.context.render(
            image, toBitmap: &data, rowBytes: width * 4,
            bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil
        )
        bytes = data
    }

    init(_ cg: CGImage) {
        width = cg.width
        height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    /// (r, g, b, a) at a canvas position, y down.
    subscript(x: Int, y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return (0..<4).map { Int(bytes[i + $0]) }
    }

    func luma(_ x: Int, _ y: Int) -> Double {
        let p = self[x, y]
        return 0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])
    }

    /// Pixels in a region that aren't black.
    func litPixels(in rect: CGRect? = nil, threshold: Int = 40) -> Int {
        let r = rect ?? CGRect(x: 0, y: 0, width: width, height: height)
        var count = 0
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) where self[x, y][0...2].max()! > threshold {
                count += 1
            }
        }
        return count
    }
}

func assertColor(_ pixel: [Int], _ expected: [Int], tolerance: Int = 3, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    for c in 0..<3 where abs(pixel[c] - expected[c]) > tolerance {
        XCTFail("pixel \(pixel) isn't \(expected) (±\(tolerance)) \(message)", file: file, line: line)
        return
    }
}

/// Renders frames through the real planner and composer, with stand-in
/// images for decoded video, so compositing is tested without AVFoundation.
struct CompositorHarness {
    var project: Project
    var canvas: CGSize
    /// Picture for each media ID, in natural orientation.
    var pictures: [String: CIImage] = [:]
    var mattes: [String: CIImage] = [:]
    var transforms: [String: CGAffineTransform] = [:]
    var format: String?
    var folder = ProjectFolder(root: URL(fileURLWithPath: NSTemporaryDirectory()))
    var registry = EffectRegistry.standard

    init(_ project: Project) {
        self.project = project
        canvas = CGSize(width: project.settings.width, height: project.settings.height)
    }

    struct Sources: FrameSources {
        let plan: RenderPlan
        let time: Time
        let pictures: [String: CIImage]
        let mattes: [String: CIImage]

        func frame(track: Int) -> CIImage? {
            guard let segment = plan.videoSegments.first(where: { $0.track == track && $0.timeline.contains(time) }) else { return nil }
            return segment.role == .matte ? mattes[segment.mediaID] : pictures[segment.mediaID]
        }
    }

    func image(at time: Time) -> CIImage {
        let assets = FakeAssets()
        for id in mattes.keys { assets.mattes[id] = URL(fileURLWithPath: "/dev/null") }
        let plan = RenderPlanner.plan(project, format: format, assets: assets)
        var clips = RenderEngine.sceneClips(project, folder: folder)
        for (id, clip) in clips {
            if let mediaID = clip.clip.mediaID, let t = transforms[mediaID] {
                clips[id]?.pictureTransform = t
            }
        }
        let scene = RenderScene(
            canvas: canvas, frameDuration: project.settings.frameRate.frameDuration,
            format: format, clips: clips, registry: registry, folder: folder
        )
        let stack = plan.instructions.first { $0.range.contains(time) }?.stack ?? []
        return FrameComposer(scene: scene).compose(stack, at: time, sources: Sources(plan: plan, time: time, pictures: pictures, mattes: mattes))
    }

    func render(at time: Time) -> Bitmap {
        Bitmap(image(at: time), size: canvas)
    }
}

func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1, width: CGFloat = 320, height: CGFloat = 180) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

/// Left half one colour, right half another (y is irrelevant).
func split(_ left: CIColor, _ right: CIColor, width: CGFloat = 320, height: CGFloat = 180) -> CIImage {
    CIImage(color: right).cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        .composited(over: CIImage(color: left).cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height)))
}

/// A small test project: 320x180 at 30 fps.
func smallProject(video: [Track], audio: [Track] = [], media: [MediaItem]) -> Project {
    Project(
        name: "Test",
        settings: ProjectSettings(width: 320, height: 180, frameRate: .fps30),
        media: media,
        videoTracks: video,
        audioTracks: audio
    )
}

let redMedia = MediaItem(id: "med_red", path: "red.mov", kind: .video, role: .screen, duration: Time(seconds: 60), width: 320, height: 180, hasVideo: true)
let blueMedia = MediaItem(id: "med_blue", path: "blue.mov", kind: .video, role: .camera, duration: Time(seconds: 60), width: 320, height: 180, hasVideo: true)
let greenMedia = MediaItem(id: "med_green", path: "green.mov", kind: .video, role: .broll, duration: Time(seconds: 60), width: 320, height: 180, hasVideo: true)
