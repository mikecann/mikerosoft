import Foundation
import TandemCore
import TandemMedia

/// Frame grabs and exports wait for the converted copies of files macOS
/// can't decode (QuickTime Animation and PNG stickers), making them first
/// if need be, so the sticker is in the picture. It takes a second or two
/// for a sticker, once; the copy is cached. Playback doesn't wait: it
/// leaves such a clip out until the background conversion lands.
enum ConvertedMedia {
    /// The context to build from, and why anything couldn't be converted.
    /// Media scanned before Tandem looked for these files isn't marked, so
    /// the files the timeline shows are checked here too.
    static func prepare(_ context: RenderContext) async -> (context: RenderContext, warnings: [String]) {
        guard let analysis = context.analysis else { return (context, []) }
        var context = context
        let shown = Set(context.project.videoTracks.filter { !$0.hidden }.flatMap(\.clips).filter(\.enabled).compactMap(\.mediaID))
        var warnings: [String] = []
        for index in context.project.media.indices {
            var item = context.project.media[index]
            guard shown.contains(item.id), item.kind == .video, item.hasVideo else { continue }
            if item.undecodableCodec == nil {
                guard let source = try? await SourceCache.shared.source(for: context.folder.url(for: item)),
                      let codec = source.undecodableCodec else { continue }
                item.undecodableCodec = codec
                context.project.media[index] = item
            }
            if case .failed(let reason) = await analysis.waitFor(.converted, for: item) {
                warnings.append("Couldn't convert \(item.path): \(reason)")
            }
        }
        return (context, warnings)
    }
}
