import Foundation

/// Raw PCM to WAV. ElevenLabs returns bare 16-bit PCM for `pcm_48000`, and
/// AVFoundation needs a header to read it.
public enum WAVFile {
    /// A WAV file around little-endian 16-bit PCM.
    public static func wrap(pcm16 data: Data, sampleRate: Int, channels: Int) -> Data {
        let bytesPerSample = 2
        let blockAlign = channels * bytesPerSample
        // Drop a trailing partial frame rather than write a broken file.
        let usable = data.count - data.count % blockAlign
        var header = Data()
        func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: Int) { var v = UInt32(value).littleEndian; header.append(Data(bytes: &v, count: 4)) }
        func append16(_ value: Int) { var v = UInt16(value).littleEndian; header.append(Data(bytes: &v, count: 2)) }
        append("RIFF")
        append32(36 + usable)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)
        append16(channels)
        append32(sampleRate)
        append32(sampleRate * blockAlign)
        append16(blockAlign)
        append16(bytesPerSample * 8)
        append("data")
        append32(usable)
        return header + data.prefix(usable)
    }

    /// How many channels a bare PCM16 body has, from its length and the
    /// duration that was asked for. Falls back to mono, which is what
    /// ElevenLabs sends for speech and sound effects.
    public static func guessChannels(byteCount: Int, sampleRate: Int, expectedSeconds: Double?) -> Int {
        guard let seconds = expectedSeconds, seconds > 0 else { return 1 }
        let ratio = Double(byteCount) / (Double(sampleRate) * 2 * seconds)
        // Only a body close to twice the mono size is stereo; anything else
        // (a slightly long or short mono take) stays mono.
        return (1.7...2.3).contains(ratio) ? 2 : 1
    }
}
