import AVFoundation
import CryptoKit
import Foundation
import TandemCore

/// The `pitchShift` audio effect. A clip's sound is rendered once through
/// Apple's time-pitch unit (offline, far faster than real time) into a
/// cached file, and the composition plays that instead of the original.
/// Keyframed semitones change the pitch as it plays. Speed changes still
/// keep their pitch on top, so the two combine.
///
/// Offline, the unit adds no delay (measured: onsets land on the same
/// sample), so the result lines up with the picture as it is.
enum PitchShift {
    static let version = 1
    static let sampleRate = Double(AudioBuffers.sampleRate)
    /// Real sound before the start, so the unit has context there.
    static let preroll = 0.2
    /// Pitch is set per slice of this many frames.
    static let slice = 1024
    /// Where rendered copies are kept (tests point it elsewhere).
    nonisolated(unsafe) static var cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tandem/pitch", isDirectory: true)

    /// The clip's first enabled pitch shift that moves the pitch (a
    /// non-zero value or any keyframes), or nil.
    static func effect(of clip: Clip, registry: EffectRegistry) -> Effect? {
        guard let effects = clip.audio?.effects else { return nil }
        for effect in effects where effect.type == "pitchShift" && effect.enabled {
            let keyed = clip.keyframes["audio.effects.\(effect.id).semitones"].map { !$0.isEmpty } ?? false
            let value = registry.definition("pitchShift").map { $0.resolvedParams(effect)["semitones"]?.number ?? 0 } ?? 0
            if keyed || value != 0 { return effect }
        }
        return nil
    }

    /// The pitch in semitones at a timeline time, keyframes included.
    static func semitones(_ clip: Clip, effectID: String, registry: EffectRegistry, at time: Time) -> Double {
        let audio = clip.resolvedAudio(at: time - clip.start)
        guard let effect = audio.effects.first(where: { $0.id == effectID }) else { return 0 }
        let params = registry.definition("pitchShift")?.resolvedParams(effect) ?? effect.params
        return min(max(params["semitones"]?.number ?? 0, -24), 24)
    }

    /// The cached pitched sound for one audio segment, rendering it if
    /// needed. The file starts at the segment's source start and covers
    /// its whole source range, at the source's own speed.
    static func file(for segment: PlannedSegment, clip: Clip, effect: Effect, source url: URL, registry: EffectRegistry) async throws -> URL {
        let speed = segment.speed > 0 ? segment.speed : 1
        let duration = segment.freeze ? segment.timeline.duration : segment.timeline.duration.scaled(by: speed)
        // Media time to timeline time, for keyframed pitch.
        func timeline(_ media: Double) -> Time {
            segment.timeline.start + Time(seconds: (media - segment.sourceStart.seconds) / speed)
        }
        let keyframes = clip.keyframes["audio.effects.\(effect.id).semitones"] ?? []
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        var identity = "v\(version)|\(url.path)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes?[.size] as? Int ?? 0)"
        identity += "|\(segment.sourceStart.flicks)|\(duration.flicks)|\(effect.params["semitones"]?.number ?? 0)"
        if !keyframes.isEmpty {
            // Where each keyframe falls in the file depends on the timing.
            identity += "|\(segment.timeline.start.flicks)|\(clip.start.flicks)|\(speed)"
            identity += keyframes.map { "|\($0.time.flicks):\($0.value.number ?? 0):\($0.interpolation.rawValue)" }.joined()
        }
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = cacheFolder
        let cached = folder.appendingPathComponent("\(hash.prefix(32)).caf")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent("\(UUID().uuidString).caf")
        try await render(url, from: segment.sourceStart, duration: duration, to: temporary) { media in
            semitones(clip, effectID: effect.id, registry: registry, at: timeline(media))
        }
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.removeItem(at: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: cached)
        }
        return cached
    }

    /// Renders `duration` of a file's sound from `start` with the pitch
    /// `semitones(mediaSeconds)`, as 48 kHz stereo float.
    static func render(_ url: URL, from start: Time, duration: Time, to output: URL, semitones: @escaping (Double) -> Double) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw RenderError.media("No sound in \(url.lastPathComponent) to shift.")
        }
        let available = try await track.load(.timeRange)
        try process(asset: asset, track: track, available: available, from: start, duration: duration, to: output, semitones: semitones)
    }

    /// The decoding and rendering, all synchronous.
    private static func process(
        asset: AVAsset, track: AVAssetTrack, available: CMTimeRange,
        from start: Time, duration: Time, to output: URL, semitones: (Double) -> Double
    ) throws {
        let url = (asset as? AVURLAsset)?.url ?? output
        let pre = min(preroll, max(0, (start.cmTime - available.start).seconds))
        let readStart = start.seconds - pre

        // Decode what's needed (and a little past the end for context).
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: readStart, preferredTimescale: 48_000),
                                       duration: CMTime(seconds: pre + duration.seconds + 0.2, preferredTimescale: 48_000))
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: AudioBuffers.readerSettings)
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? RenderError.media("Couldn't read \(url.lastPathComponent).") }
        var interleaved: [Float] = []
        while let buffer = trackOutput.copyNextSampleBuffer() {
            interleaved += AudioBuffers.samples(in: buffer)
        }
        if reader.status == .failed { throw reader.error ?? RenderError.media("Couldn't read \(url.lastPathComponent).") }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = interleaved.count / 2
        let prerollFrames = Int((pre * sampleRate).rounded())
        let wanted = Int((duration.seconds * sampleRate).rounded())
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw RenderError.media("No sound in \(url.lastPathComponent) there.")
        }
        input.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            input.floatChannelData![0][i] = interleaved[2 * i]
            input.floatChannelData![1][i] = interleaved[2 * i + 1]
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(slice))
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
        player.play()

        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(slice)) else {
            throw RenderError.media("Couldn't set up pitch shifting.")
        }
        var rendered = 0
        var written = 0
        while written < wanted {
            let media = readStart + Double(rendered) / sampleRate
            pitch.pitch = Float(semitones(max(media, start.seconds)) * 100)
            let count = AVAudioFrameCount(min(slice, prerollFrames + wanted - rendered))
            guard count > 0, try engine.renderOffline(count, to: chunk) == .success else { break }
            let produced = Int(chunk.frameLength)
            // Drop the preroll, keep exactly the wanted length.
            let skip = max(0, prerollFrames - rendered)
            let keep = min(produced - skip, wanted - written)
            if keep > 0, skip < produced {
                guard let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(keep)) else { break }
                part.frameLength = AVAudioFrameCount(keep)
                for channel in 0..<2 {
                    part.floatChannelData![channel].update(from: chunk.floatChannelData![channel] + skip, count: keep)
                }
                try file.write(from: part)
                written += keep
            }
            rendered += produced
            if produced == 0 { break }
        }
    }
}
