import Foundation
import TandemCore

/// Which analyses a project needs, worked out from what its edit uses.
///
/// Every file in the project folder shows up in the media browser, and a
/// video folder can hold hundreds (old renders, drafts, B-roll that never
/// made it in). So the cheap analyses (thumbnails, waveforms, loudness, and
/// the conversion of a file macOS can't decode) run for everything, the
/// transcript runs for every camera take so you can search what you said
/// before placing it, and the expensive ones only run for what the edit
/// uses:
///
/// - scrub proxies for large video on the timeline,
/// - a cutout matte for media with a clip whose cutout is on (in any format),
/// - isolated voice for media with a clip using voice isolation,
/// - a transcript for anything on a speech track (the unmuted `cut` audio
///   tracks, like Voice).
///
/// Placing a take or turning on its cutout queues the rest.
public enum AnalysisNeeds {
    public struct Need: Equatable, Sendable {
        public var mediaID: String
        public var kind: AnalysisKind
        public var priority: JobPriority
        /// Set for mattes: the cutout mode the clips ask for.
        public var matteMode: CutoutMode?

        public init(mediaID: String, kind: AnalysisKind, priority: JobPriority, matteMode: CutoutMode? = nil) {
            self.mediaID = mediaID
            self.kind = kind
            self.priority = priority
            self.matteMode = matteMode
        }
    }

    public static func needs(for project: Project, settings: AnalysisSettings = .standard) -> [Need] {
        var onTimeline = Set<String>()
        var onSpeech = Set<String>()
        var cutoutModes: [String: Set<CutoutMode>] = [:]
        var isolated = Set<String>()
        let speechTracks = Set(speechTrackIDs(project))
        for track in project.allTracks {
            for clip in track.clips {
                guard let mediaID = clip.mediaID else { continue }
                onTimeline.insert(mediaID)
                if speechTracks.contains(track.id) { onSpeech.insert(mediaID) }
                if track.kind == .video, let cutout = clip.video?.cutout {
                    let overridden = clip.video?.formatOverrides.values.contains { $0.cutout == true } ?? false
                    if cutout.enabled || overridden { cutoutModes[mediaID, default: []].insert(cutout.mode) }
                }
                if track.kind == .audio, (clip.audio?.voiceIsolation ?? 0) > 0 { isolated.insert(mediaID) }
            }
        }

        var needs: [Need] = []
        // Timeline media first, so its work is queued ahead of the rest.
        let ordered = project.media.filter { onTimeline.contains($0.id) } + project.media.filter { !onTimeline.contains($0.id) }
        for item in ordered {
            let used = onTimeline.contains(item.id)
            let priority: JobPriority = used ? .timeline : .background
            // A file macOS can't decode is converted first, used or not, so
            // the browser can show it; its picture analyses follow the copy.
            for kind in [AnalysisKind.converted, .thumbnails, .waveform, .loudness] where kind.applies(to: item) {
                needs.append(Need(mediaID: item.id, kind: kind, priority: priority))
            }
            if AnalysisKind.transcript.applies(to: item) && (item.role == .camera || onSpeech.contains(item.id)) {
                needs.append(Need(mediaID: item.id, kind: .transcript, priority: priority))
            }
            guard used else { continue }
            if AnalysisKind.proxy.applies(to: item), let width = item.width, let height = item.height,
               width > settings.proxyMaxWidth || height > settings.proxyMaxHeight {
                needs.append(Need(mediaID: item.id, kind: .proxy, priority: .timeline))
            }
            if AnalysisKind.matte.applies(to: item) {
                for mode in (cutoutModes[item.id] ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
                    needs.append(Need(mediaID: item.id, kind: .matte, priority: .timeline, matteMode: mode))
                }
            }
            if isolated.contains(item.id) && AnalysisKind.isolatedVoice.applies(to: item) {
                needs.append(Need(mediaID: item.id, kind: .isolatedVoice, priority: .timeline))
            }
        }
        return needs
    }

    /// The unmuted audio tracks that ripple with the take (Voice), or every
    /// unmuted audio track when none do. The same rule the transcript tools
    /// use to find what's said.
    static func speechTrackIDs(_ project: Project) -> [String] {
        let audio = project.audioTracks.filter { !$0.muted }
        let take = audio.filter { $0.rippleMode == .cut }
        return (take.isEmpty ? audio : take).map(\.id)
    }
}

extension MediaAnalysis {
    /// Queues what `project` needs (see `AnalysisNeeds`). Cheap to call after
    /// every edit: work that's cached or already queued isn't repeated.
    public func requestNeeded(for project: Project) {
        let settings = self.settings
        let byID = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for need in AnalysisNeeds.needs(for: project, settings: settings) {
            guard let item = byID[need.mediaID] else { continue }
            var needSettings: AnalysisSettings?
            if let mode = need.matteMode, mode != settings.matteMode {
                var custom = settings
                custom.matteMode = mode
                needSettings = custom
            }
            submit(need.kind, for: item, priority: need.priority, settings: needSettings)
        }
    }
}
