import AVFoundation
import Foundation
import ImageIO
import TandemCore

/// Live Photos: the still an iPhone takes and the short movie it records
/// around it. Exported from Photos, AirDropped or imported with Image
/// Capture they arrive as two files with one name, `IMG_0130.HEIC` and
/// `IMG_0130.mov`. Tandem keeps the pair as one media item, the still,
/// with the movie in `MediaItem.livePhotoVideo`, so 35 photos are 35
/// items rather than 35 photos and 35 two-second videos.
public enum LivePhotos {
    /// The stills a Live Photo can have.
    static let stillExtensions = ["heic", "heif", "jpg", "jpeg"]
    /// Live Photo movies are always QuickTime.
    static let movieExtensions: Set<String> = ["mov"]
    /// Live Photo movies run about three seconds. When there are no content
    /// identifiers to compare, a longer movie is a video that happens to
    /// share a photo's name.
    public static let maximumDuration = 5.0

    /// What decides whether a movie is a still's motion clip.
    public struct Movie: Equatable, Sendable {
        public var duration: Double?
        public var hasVideo: Bool
        public var hasAlpha: Bool
        /// `com.apple.quicktime.content.identifier`, the asset identifier
        /// the iPhone writes into both halves of a Live Photo.
        public var contentIdentifier: String?

        public init(duration: Double?, hasVideo: Bool, hasAlpha: Bool, contentIdentifier: String?) {
            self.duration = duration
            self.hasVideo = hasVideo
            self.hasAlpha = hasAlpha
            self.contentIdentifier = contentIdentifier
        }
    }

    /// Whether `movie` is the motion clip of the still with the same name.
    /// When both carry Apple's content identifier, they decide. Otherwise
    /// the movie has to look like one: short, with a picture and no alpha,
    /// which keeps out an animated sticker or a real video.
    public static func isMotionClip(_ movie: Movie, ofStillWith stillIdentifier: String?) -> Bool {
        if let movieIdentifier = movie.contentIdentifier, let stillIdentifier {
            return movieIdentifier.caseInsensitiveCompare(stillIdentifier) == .orderedSame
        }
        guard movie.hasVideo, !movie.hasAlpha, let duration = movie.duration else { return false }
        return duration > 0 && duration <= maximumDuration
    }

    /// Stills and movies that could be Live Photos: in the same folder,
    /// with the same name bar the extension (in any case). Indices into
    /// `paths`, a HEIC before a JPEG of the same photo.
    static func candidates(_ paths: [String]) -> [(still: Int, movie: Int)] {
        var stills: [String: [Int]] = [:]
        var movies: [String: [Int]] = [:]
        for (index, path) in paths.enumerated() {
            let ext = (path as NSString).pathExtension.lowercased()
            if stillExtensions.contains(ext) {
                stills[key(path), default: []].append(index)
            } else if movieExtensions.contains(ext) {
                movies[key(path), default: []].append(index)
            }
        }
        func rank(_ index: Int) -> Int {
            stillExtensions.firstIndex(of: (paths[index] as NSString).pathExtension.lowercased()) ?? stillExtensions.count
        }
        var pairs: [(still: Int, movie: Int)] = []
        for (key, movieIndices) in movies.sorted(by: { $0.key < $1.key }) {
            guard let stillIndices = stills[key] else { continue }
            for movie in movieIndices.sorted() {
                for still in stillIndices.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
                    pairs.append((still, movie))
                }
            }
        }
        return pairs
    }

    /// Folder and name without the extension, compared in one Unicode form
    /// and case, the way APFS treats names.
    static func key(_ path: String) -> String {
        (path as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Content identifiers

    /// The Live Photo asset identifier in a still's Apple maker note, if it
    /// has one.
    public static func contentIdentifier(ofStill url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        // Key 17 of the maker note holds it (exiftool's ContentIdentifier).
        guard let identifier = maker["17"] as? String, !identifier.isEmpty else { return nil }
        return identifier
    }

    /// The Live Photo asset identifier in a movie's QuickTime metadata, if
    /// it has one.
    public static func contentIdentifier(ofMovie url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata),
              let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataContentIdentifier).first,
              let identifier = try? await item.load(.stringValue), !identifier.isEmpty
        else { return nil }
        return identifier
    }

    // MARK: - Pairing

    /// Pairs Live Photos among `items`, media in `folder`. A movie that
    /// `canPair` allows, and that's the motion clip of a still with the same
    /// name, leaves `items` and is recorded on the still. Returns how many
    /// it paired.
    static func pair(_ items: inout [MediaItem], folder: ProjectFolder, canPair: (MediaItem) -> Bool) async -> Int {
        var paired: [Int: Int] = [:]  // movie index: still index
        var stillsDone = Set<Int>()
        for (still, movie) in candidates(items.map(\.path)) where paired[movie] == nil && !stillsDone.contains(still) {
            let clip = items[movie]
            guard clip.kind == .video, items[still].kind == .image, canPair(clip) else { continue }
            let facts = Movie(
                duration: clip.duration?.seconds, hasVideo: clip.hasVideo, hasAlpha: clip.hasAlpha,
                contentIdentifier: await contentIdentifier(ofMovie: folder.url(for: clip))
            )
            // The still's maker note is only worth reading when the movie
            // has an identifier to compare it with.
            let stillIdentifier = facts.contentIdentifier == nil ? nil : contentIdentifier(ofStill: folder.url(for: items[still]))
            guard isMotionClip(facts, ofStillWith: stillIdentifier) else { continue }
            paired[movie] = still
            stillsDone.insert(still)
        }
        guard !paired.isEmpty else { return 0 }
        for (movie, still) in paired { items[still].livePhotoVideo = items[movie].path }
        items = items.enumerated().filter { paired[$0.offset] == nil }.map(\.element)
        return paired.count
    }

    /// Stills whose motion clip has gone from the folder forget it.
    static func forgetMissingMotionClips(_ items: inout [MediaItem], folder: ProjectFolder) {
        for index in items.indices {
            guard let clip = items[index].livePhotoVideo else { continue }
            if !FileManager.default.fileExists(atPath: folder.url(forPath: clip).path) { items[index].livePhotoVideo = nil }
        }
    }

    /// For files that aren't in a project yet, such as a folder dropped from
    /// Finder: each motion clip among them, with its still.
    public static func motionClips(among urls: [URL]) async -> [URL: URL] {
        var clips: [URL: URL] = [:]
        var stillsDone = Set<Int>()
        for (still, movie) in candidates(urls.map(\.path)) where clips[urls[movie]] == nil && !stillsDone.contains(still) {
            guard let probe = try? await MediaProbe.probe(urls[movie]), probe.kind == .video else { continue }
            let facts = Movie(
                duration: probe.duration?.seconds, hasVideo: probe.hasVideo, hasAlpha: probe.hasAlpha,
                contentIdentifier: await contentIdentifier(ofMovie: urls[movie])
            )
            let stillIdentifier = facts.contentIdentifier == nil ? nil : contentIdentifier(ofStill: urls[still])
            guard isMotionClip(facts, ofStillWith: stillIdentifier) else { continue }
            clips[urls[movie]] = urls[still]
            stillsDone.insert(still)
        }
        return clips
    }

    /// The movies among `urls` that share a folder and a name with a still,
    /// by name alone. For counting a drop before anything's been read;
    /// `motionClips(among:)` is the real answer.
    public static func likelyMotionClips(among urls: [URL]) -> Set<URL> {
        Set(candidates(urls.map(\.path)).map { urls[$0.movie] })
    }
}
