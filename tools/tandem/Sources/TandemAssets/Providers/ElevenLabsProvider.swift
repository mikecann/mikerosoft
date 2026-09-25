import Foundation
import TandemCore

/// ElevenLabs sound effects and music, generated from a prompt. Key in the
/// Keychain (service `elevenlabs`).
///
/// - Sound effects: `POST /v1/sound-generation` with the
///   `eleven_text_to_sound_v2` model, 0.5 to 30 s, optional loop and prompt
///   influence. Returned as bare 48 kHz PCM, wrapped into WAV here.
/// - Music: `POST /v1/music` with `music_v2_5`, instrumental by default,
///   as 192 kbps MP3 at 48 kHz (what Mike's music scripts use).
///
/// Keys can be restricted per feature. When a call comes back without the
/// permission it needs, the provider remembers it and says so in its status
/// instead of failing the same way every time.
public final class ElevenLabsProvider: AssetProvider, @unchecked Sendable {
    public let id = "elevenlabs"
    public let displayName = "ElevenLabs"
    public let kinds: Set<AssetKind> = [.sfx, .music]
    public let capabilities = ProviderCapabilities(search: false, similar: false, generate: true)
    public let rules = ProviderRules(
        maxConcurrentRequests: 2,
        cacheTTL: 0,
        notes: [
            "Output made on a paid plan can be used commercially (ElevenLabs Terms, section on Free and Paid Users).",
            "Sound effects cost 40 credits a second when the duration is set.",
            "Mike's plan allows 2 requests at once.",
            "The key needs the sound_generation permission for sound effects and music_generation for music."
        ]
    )
    public var website: URL? { URL(string: "https://elevenlabs.io") }

    public static let keychainService = "elevenlabs"
    public static let soundModel = "eleven_text_to_sound_v2"
    public static let musicModel = "music_v2_5"
    static let api = "https://api.elevenlabs.io/v1"
    static let termsURL = URL(string: "https://elevenlabs.io/terms-of-use")!

    let http: ProviderHTTP
    let secrets: SecretStore
    /// Where refused permissions are remembered between runs.
    let stateFile: URL

    public init(environment: ProviderEnvironment) {
        http = ProviderHTTP(provider: id, rules: rules, environment: environment)
        secrets = environment.secrets
        stateFile = environment.stateFolder.appendingPathComponent("elevenlabs.json")
    }

    // MARK: - Remembered refusals

    /// A refusal from the API, keyed by the permission it named.
    public struct Refusal: Codable, Equatable, Sendable {
        public var message: String
        public var at: Date
    }

    public func refusals() -> [String: Refusal] {
        guard let data = try? Data(contentsOf: stateFile) else { return [:] }
        return (try? JSONDecoder.iso.decode([String: Refusal].self, from: data)) ?? [:]
    }

    private func remember(_ permission: String, _ message: String?) {
        var all = refusals()
        if let message {
            all[permission] = Refusal(message: message, at: Date())
        } else {
            guard all.removeValue(forKey: permission) != nil else { return }
        }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.sorted.encode(all).write(to: stateFile, options: .atomic)
    }

    static func permission(for kind: AssetKind) -> String {
        kind == .music ? "music_generation" : "sound_generation"
    }

    public func status() async -> ProviderStatus {
        guard secrets.secret(service: Self.keychainService) != nil else {
            return ProviderStatus(.needsKey, "Add an ElevenLabs API key to the Keychain: security add-generic-password -s elevenlabs -a elevenlabs -w")
        }
        let refused = refusals()
        let sfx = refused["sound_generation"]
        let music = refused["music_generation"]
        switch (sfx, music) {
        case (nil, nil):
            return .ready
        case (let sfx?, nil):
            return ProviderStatus(.limited, "Sound effects are off: \(sfx.message) Turn on the sound_generation permission for this key in ElevenLabs. Music still works.")
        case (nil, let music?):
            return ProviderStatus(.limited, "Music is off: \(music.message) Sound effects still work.")
        case (let sfx?, let music?):
            return ProviderStatus(.limited, "The key can't make sound effects (\(sfx.message)) or music (\(music.message)).")
        }
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] { [] }

    // MARK: - Generating

    public func generate(_ request: GenerationRequest, into folder: URL) async throws -> [FetchedOriginal] {
        guard let key = secrets.secret(service: Self.keychainService) else {
            throw AssetError.providerUnavailable(provider: displayName, reason: "no API key in the Keychain (service elevenlabs)")
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AssetError.invalid("A generation needs a prompt") }
        guard request.kind == .sfx || request.kind == .music else {
            throw AssetError.invalid("ElevenLabs makes sound effects and music, not \(request.kind.rawValue)")
        }
        let variations = min(max(1, request.variations), 4)
        var results: [FetchedOriginal] = []
        for variation in 0..<variations {
            let target = folder.appendingPathComponent("take-\(variation + 1)", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let result = request.kind == .music
                ? try await music(request, prompt: prompt, key: key, into: target)
                : try await soundEffect(request, prompt: prompt, key: key, into: target)
            results.append(result)
        }
        return results
    }

    /// The JSON body for a sound effect.
    static func soundBody(_ request: GenerationRequest, prompt: String) throws -> Data {
        var body: [String: Any] = ["text": prompt, "model_id": request.model ?? soundModel, "loop": request.loop]
        if let duration = request.duration {
            guard (0.5...30).contains(duration) else { throw AssetError.invalid("Sound effects are 0.5 to 30 seconds long") }
            body["duration_seconds"] = duration
        }
        if let influence = request.promptInfluence {
            guard (0...1).contains(influence) else { throw AssetError.invalid("Prompt influence runs from 0 to 1") }
            body["prompt_influence"] = influence
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The JSON body for music.
    static func musicBody(_ request: GenerationRequest, prompt: String) throws -> Data {
        var body: [String: Any] = ["prompt": prompt, "model_id": request.model ?? musicModel, "force_instrumental": request.instrumental]
        if let duration = request.duration {
            guard (3...600).contains(duration) else { throw AssetError.invalid("Music is 3 to 600 seconds long") }
            body["music_length_ms"] = Int((duration * 1000).rounded())
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func soundEffect(_ request: GenerationRequest, prompt: String, key: String, into folder: URL) async throws -> FetchedOriginal {
        let body = try Self.soundBody(request, prompt: prompt)
        let url = URL(string: "\(Self.api)/sound-generation")!.adding([URLQueryItem(name: "output_format", value: "pcm_48000")])
        let (data, response) = try await call(url, body: body, key: key, permission: "sound_generation")
        let channels = WAVFile.guessChannels(byteCount: data.count, sampleRate: 48_000, expectedSeconds: request.duration)
        let file = ProviderFiles.original(in: folder, ext: "wav")
        try WAVFile.wrap(pcm16: data, sampleRate: 48_000, channels: channels).write(to: file, options: .atomic)
        var remote = remoteDetails(request, prompt: prompt, model: request.model ?? Self.soundModel, format: "pcm_48000")
        remote["channels"] = String(channels)
        if let cost = response.value(forHTTPHeaderField: "character-cost") { remote["characterCost"] = cost }
        return FetchedOriginal(asset: generatedAsset(kind: .sfx, prompt: prompt, remote: remote, duration: Double(data.count) / Double(48_000 * 2 * channels)), file: file)
    }

    private func music(_ request: GenerationRequest, prompt: String, key: String, into folder: URL) async throws -> FetchedOriginal {
        let body = try Self.musicBody(request, prompt: prompt)
        let url = URL(string: "\(Self.api)/music")!.adding([URLQueryItem(name: "output_format", value: "mp3_48000_192")])
        let (data, response) = try await call(url, body: body, key: key, permission: "music_generation")
        let file = ProviderFiles.original(in: folder, ext: "mp3")
        try data.write(to: file, options: .atomic)
        var remote = remoteDetails(request, prompt: prompt, model: request.model ?? Self.musicModel, format: "mp3_48000_192")
        if let song = response.value(forHTTPHeaderField: "song-id") { remote["songID"] = song }
        return FetchedOriginal(asset: generatedAsset(kind: .music, prompt: prompt, remote: remote, duration: request.duration), file: file)
    }

    /// Sends a generation request, remembering a refused permission (and
    /// forgetting it once a call succeeds).
    private func call(_ url: URL, body: Data, key: String, permission: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await http.postJSON(url, body: body, headers: ["xi-api-key": key, "Accept": "audio/*"])
            remember(permission, nil)
            return result
        } catch AssetError.permission(let provider, let message) {
            remember(permission, message)
            throw AssetError.permission(provider: provider, message: message)
        }
    }

    private func remoteDetails(_ request: GenerationRequest, prompt: String, model: String, format: String) -> [String: String] {
        var remote = ["prompt": prompt, "model": model, "outputFormat": format]
        if let duration = request.duration { remote["requestedDuration"] = String(duration) }
        if request.kind == .sfx {
            remote["loop"] = request.loop ? "1" : "0"
            if let influence = request.promptInfluence { remote["promptInfluence"] = String(influence) }
        } else {
            remote["instrumental"] = request.instrumental ? "1" : "0"
        }
        return remote
    }

    private func generatedAsset(kind: AssetKind, prompt: String, remote: [String: String], duration: Double?) -> Asset {
        Asset(
            provider: id,
            providerID: IDs.make(kind == .music ? "music" : "sfx"),
            kind: kind,
            name: Self.shortName(prompt),
            tags: ["generated", "elevenlabs"] + Array(LocalMatcher.tokens(prompt).prefix(12)),
            summary: prompt,
            duration: duration,
            state: .original,
            licenceClass: .aiGenerated,
            pageURL: website,
            remote: remote
        )
    }

    /// The prompt cut to about 60 characters at a word boundary.
    static func shortName(_ prompt: String) -> String {
        let single = prompt.replacingOccurrences(of: "\n", with: " ")
        guard single.count > 60 else { return single }
        let cut = single.prefix(60)
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return trimmed + "..."
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        throw AssetError.unsupported("ElevenLabs assets exist only once generated; generate a new one instead")
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        AssetLicence(
            name: "ElevenLabs Terms of Service (paid plan)",
            licenceClass: .aiGenerated,
            url: Self.termsURL,
            text: "If you access or use the Services through a paid subscription plan, you may use the Services for commercial purposes. Free users may only use the Services for non-commercial purposes. (ElevenLabs Terms of Service, last updated 31 March 2026.)",
            holder: "Generated with ElevenLabs",
            sourceURL: website,
            notes: [asset.remote["model"].map { "Model \($0)." }, asset.summary.map { "Prompt: \($0)" }].compactMap { $0 }.joined(separator: " ")
        )
    }
}
