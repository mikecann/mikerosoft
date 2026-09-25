import CoreImage
import Foundation
import Metal
import TandemCore
import TandemMedia

/// Shared rendering state: one Metal-backed Core Image context for the whole
/// process, reused by the compositor, frame grabs and export.
enum RenderEngine {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Colour management is off: pixels are composited as the encoded
    /// values they are, the way Filmora and most editors work, so a pass
    /// through the compositor leaves video untouched.
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
            .name: "Tandem"
        ]
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// Scene clips for every clip that could draw, with media looked up.
    /// Picture and matte transforms start as identity; the composition
    /// builder fills them in from the files.
    static func sceneClips(_ project: Project, folder: ProjectFolder) -> [String: SceneClip] {
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var clips: [String: SceneClip] = [:]
        for (index, track) in project.videoTracks.enumerated() {
            for clip in track.clips {
                var scene = SceneClip(clip: clip, trackIndex: index)
                if let id = clip.mediaID, let item = media[id] {
                    scene.media = item
                    if item.kind == .image { scene.imageURL = folder.url(for: item) }
                }
                clips[clip.id] = scene
            }
        }
        return clips
    }
}
