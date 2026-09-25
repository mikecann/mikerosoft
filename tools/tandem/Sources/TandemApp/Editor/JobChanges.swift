import Foundation
import TandemMedia

/// Which analysis results just landed, so the app redraws or rebuilds only
/// when something it shows has changed. Job lists arrive up to 20 times a
/// second while analysis runs, mostly with progress.
enum JobChanges {
    /// Jobs that are done now and weren't in the previous list.
    static func newlyDone(old: [JobStatus], new: [JobStatus]) -> [JobStatus] {
        let wasDone = Set(old.lazy.filter { $0.state == .done }.map(\.id))
        return new.filter { $0.state == .done && !wasDone.contains($0.id) }
    }

    /// Thumbnails, waveforms and transcripts the timeline and browser draw.
    static func affectsArtwork(_ jobs: [JobStatus]) -> Bool {
        jobs.contains { [.thumbnails, .waveform, .transcript].contains($0.kind) }
    }

    /// Files the composition reads: proxies, mattes, isolated voice, and
    /// loudness for normalising.
    static func affectsPlayback(_ jobs: [JobStatus]) -> Bool {
        jobs.contains { [.proxy, .matte, .isolatedVoice, .loudness].contains($0.kind) }
    }
}
