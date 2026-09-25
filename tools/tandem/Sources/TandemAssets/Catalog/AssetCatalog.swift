import Foundation
import TandemMedia

/// The local index of every asset Tandem knows about: SQLite with an FTS5
/// full-text index, plus licence snapshots, usage by project, favourites
/// and the list of import folders.
///
/// Safe to use from any thread. The app and the CLI can open the same file
/// at once; SQLite's WAL mode and a busy timeout keep them out of each
/// other's way.
public final class AssetCatalog: @unchecked Sendable {
    public let url: URL
    private let db: SQLiteConnection
    private let lock = NSRecursiveLock()

    static let schemaVersion = 1

    /// Opens (creating if needed) the catalogue at `url`.
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        try migrate()
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        guard version < Self.schemaVersion else { return }
        try db.transaction {
            try db.execute(Self.schemaV1)
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS assets (
        -- An explicit rowid: the FTS index points at it, and SQLite only
        -- promises to keep rowids through VACUUM when they're declared.
        key INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        tags TEXT NOT NULL DEFAULT '',
        summary TEXT,
        duration REAL,
        bpm REAL,
        musical_key TEXT,
        has_alpha INTEGER NOT NULL DEFAULT 0,
        width INTEGER,
        height INTEGER,
        size INTEGER,
        sha256 TEXT,
        state TEXT NOT NULL,
        licence_class TEXT NOT NULL,
        credit_line TEXT,
        preview_url TEXT,
        thumbnail_url TEXT,
        page_url TEXT,
        remote TEXT,
        folder TEXT,
        original_file TEXT,
        normalised_file TEXT,
        thumbnail_file TEXT,
        peaks_file TEXT,
        loudness_lufs REAL,
        true_peak REAL,
        loudness_range REAL,
        popularity REAL,
        added_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS assets_kind ON assets(kind);
    CREATE INDEX IF NOT EXISTS assets_provider ON assets(provider);

    CREATE VIRTUAL TABLE IF NOT EXISTS assets_fts USING fts5(
        name, tags, summary, provider, provider_id, kind,
        content = 'assets', content_rowid = 'key',
        tokenize = 'unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER IF NOT EXISTS assets_fts_insert AFTER INSERT ON assets BEGIN
        INSERT INTO assets_fts(rowid, name, tags, summary, provider, provider_id, kind)
        VALUES (new.key, new.name, new.tags, new.summary, new.provider, new.provider_id, new.kind);
    END;
    CREATE TRIGGER IF NOT EXISTS assets_fts_delete AFTER DELETE ON assets BEGIN
        INSERT INTO assets_fts(assets_fts, rowid, name, tags, summary, provider, provider_id, kind)
        VALUES ('delete', old.key, old.name, old.tags, old.summary, old.provider, old.provider_id, old.kind);
    END;
    CREATE TRIGGER IF NOT EXISTS assets_fts_update AFTER UPDATE ON assets BEGIN
        INSERT INTO assets_fts(assets_fts, rowid, name, tags, summary, provider, provider_id, kind)
        VALUES ('delete', old.key, old.name, old.tags, old.summary, old.provider, old.provider_id, old.kind);
        INSERT INTO assets_fts(rowid, name, tags, summary, provider, provider_id, kind)
        VALUES (new.key, new.name, new.tags, new.summary, new.provider, new.provider_id, new.kind);
    END;

    CREATE TABLE IF NOT EXISTS licences (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        asset_id TEXT NOT NULL,
        name TEXT NOT NULL,
        spdx TEXT,
        licence_class TEXT NOT NULL,
        url TEXT,
        text TEXT,
        holder TEXT,
        credit_line TEXT,
        certificate TEXT,
        source_url TEXT,
        notes TEXT,
        captured_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS licences_asset ON licences(asset_id, captured_at);

    CREATE TABLE IF NOT EXISTS usage (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        asset_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        project_path TEXT,
        media_id TEXT,
        media_path TEXT,
        used_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS usage_asset ON usage(asset_id, used_at);
    CREATE INDEX IF NOT EXISTS usage_project ON usage(project_id, used_at);

    CREATE TABLE IF NOT EXISTS favourites (
        asset_id TEXT PRIMARY KEY NOT NULL,
        added_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS import_folders (
        id TEXT PRIMARY KEY NOT NULL,
        path TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        added_at REAL NOT NULL,
        last_scan REAL
    );
    """

    // MARK: - Assets

    private static let assetColumns = [
        "id", "provider", "provider_id", "kind", "name", "tags", "summary", "duration", "bpm", "musical_key",
        "has_alpha", "width", "height", "size", "sha256", "state", "licence_class", "credit_line",
        "preview_url", "thumbnail_url", "page_url", "remote", "folder", "original_file", "normalised_file",
        "thumbnail_file", "peaks_file", "loudness_lufs", "true_peak", "loudness_range", "popularity",
        "added_at", "updated_at"
    ]

    private static let upsertSQL: String = {
        let columns = assetColumns.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: assetColumns.count).joined(separator: ", ")
        let updates = assetColumns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        return "INSERT INTO assets (\(columns)) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET \(updates)"
    }()

    /// Tags are stored one per line so the FTS tokenizer sees words and a
    /// tag may contain commas.
    static func encodeTags(_ tags: [String]) -> String {
        tags.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func decodeTags(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    private static let compactEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func bindings(for asset: Asset) -> [SQLValue] {
        let remoteJSON: String? = asset.remote.isEmpty ? nil : (try? compactEncoder.encode(asset.remote)).flatMap { String(data: $0, encoding: .utf8) }
        let loudness = asset.loudness.map(Self.finite)
        return [
            SQLValue(asset.id), SQLValue(asset.provider), SQLValue(asset.providerID), SQLValue(asset.kind.rawValue),
            SQLValue(asset.name), SQLValue(encodeTags(asset.tags)), SQLValue(asset.summary), SQLValue(asset.duration),
            SQLValue(asset.bpm), SQLValue(asset.musicalKey), SQLValue(asset.hasAlpha), SQLValue(asset.width),
            SQLValue(asset.height), SQLValue(asset.size), SQLValue(asset.sha256), SQLValue(asset.state.rawValue),
            SQLValue(asset.licenceClass.rawValue), SQLValue(asset.creditLine), SQLValue(asset.previewURL?.absoluteString),
            SQLValue(asset.thumbnailURL?.absoluteString), SQLValue(asset.pageURL?.absoluteString), SQLValue(remoteJSON),
            SQLValue(asset.files.folder), SQLValue(asset.files.original), SQLValue(asset.files.normalised),
            SQLValue(asset.files.thumbnail), SQLValue(asset.files.peaks), SQLValue(loudness?.integratedLUFS),
            SQLValue(loudness?.truePeakDBTP), SQLValue(loudness?.loudnessRange), SQLValue(asset.popularity),
            SQLValue(asset.addedAt), SQLValue(asset.updatedAt)
        ]
    }

    /// SQLite and JSON can't hold infinities; silence reads as -144 dB,
    /// below the floor of 24-bit audio.
    static func finite(_ loudness: Loudness) -> Loudness {
        func clamp(_ value: Double) -> Double { value.isFinite ? value : -144 }
        return Loudness(integratedLUFS: clamp(loudness.integratedLUFS), truePeakDBTP: clamp(loudness.truePeakDBTP), loudnessRange: clamp(loudness.loudnessRange))
    }

    private static func asset(from row: SQLRow) -> Asset {
        var asset = Asset(
            provider: row.string("provider") ?? "",
            providerID: row.string("provider_id") ?? "",
            kind: AssetKind(rawValue: row.string("kind") ?? "") ?? .image,
            name: row.string("name") ?? "",
            tags: decodeTags(row.string("tags")),
            summary: row.string("summary"),
            duration: row.double("duration"),
            bpm: row.double("bpm"),
            musicalKey: row.string("musical_key"),
            hasAlpha: row.bool("has_alpha"),
            width: row.int("width"),
            height: row.int("height"),
            size: row.int64("size"),
            sha256: row.string("sha256"),
            state: AssetState(rawValue: row.string("state") ?? "") ?? .remote,
            licenceClass: LicenceClass(rawValue: row.string("licence_class") ?? "") ?? .unknown,
            creditLine: row.string("credit_line"),
            previewURL: row.string("preview_url").flatMap(URL.init(string:)),
            thumbnailURL: row.string("thumbnail_url").flatMap(URL.init(string:)),
            pageURL: row.string("page_url").flatMap(URL.init(string:)),
            remote: row.string("remote").flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:],
            files: AssetFiles(
                folder: row.string("folder"),
                original: row.string("original_file"),
                normalised: row.string("normalised_file"),
                thumbnail: row.string("thumbnail_file"),
                peaks: row.string("peaks_file")
            ),
            loudness: row.double("loudness_lufs").map {
                Loudness(integratedLUFS: $0, truePeakDBTP: row.double("true_peak") ?? 0, loudnessRange: row.double("loudness_range") ?? 0)
            },
            popularity: row.double("popularity"),
            addedAt: row.date("added_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
        asset.id = row.string("id") ?? asset.id
        asset.isFavourite = row.bool("is_favourite")
        asset.lastUsed = row.date("last_used")
        return asset
    }

    /// Inserts or replaces an asset. The favourite flag and last-used time
    /// live in their own tables and are ignored here.
    public func upsert(_ asset: Asset) throws {
        try locked { try db.run(Self.upsertSQL, Self.bindings(for: asset)) }
    }

    /// Inserts or replaces several assets in one transaction.
    public func upsert(_ assets: [Asset]) throws {
        try locked {
            try db.transaction {
                for asset in assets { try db.run(Self.upsertSQL, Self.bindings(for: asset)) }
            }
        }
    }

    /// Writes `asset` only if the stored row still has the `updatedAt` it
    /// was read with, so a change made in the meantime (a fetch finishing)
    /// isn't overwritten by a stale copy. Returns whether it wrote.
    @discardableResult
    public func replace(_ asset: Asset, ifUpdatedAt previous: Date) throws -> Bool {
        try locked {
            let sets = Self.assetColumns.dropFirst().map { "\($0) = ?" }.joined(separator: ", ")
            var values = Array(Self.bindings(for: asset).dropFirst())
            values.append(.text(asset.id))
            values.append(SQLValue(previous))
            try db.run("UPDATE assets SET \(sets) WHERE id = ? AND updated_at = ?", values)
            return db.changes > 0
        }
    }

    /// Marks a remote asset as having a cached preview. Leaves assets that
    /// have got further (downloaded or normalised) alone.
    public func markPreviewed(_ id: String) throws {
        try locked { try db.run("UPDATE assets SET state = 'preview' WHERE id = ? AND state = 'remote'", [.text(id)]) }
    }

    /// Records assets a provider returned without losing anything local:
    /// new ones are added as they are, known ones get fresh metadata
    /// (names, tags, preview links, popularity) but keep their state, files
    /// and measurements. Returns the stored versions, in the same order.
    @discardableResult
    public func mergeRemote(_ assets: [Asset]) throws -> [Asset] {
        try locked {
            try db.transaction {
                var merged: [Asset] = []
                for incoming in assets {
                    guard var existing = try assetUnlocked(id: incoming.id) else {
                        try db.run(Self.upsertSQL, Self.bindings(for: incoming))
                        merged.append(incoming)
                        continue
                    }
                    existing.name = incoming.name
                    // Tags the library added itself (the starter set) outlive
                    // the provider's fresh list.
                    let starter = existing.tags.contains(StarterContent.tag) && !incoming.tags.contains(StarterContent.tag)
                    existing.tags = incoming.tags + (starter ? [StarterContent.tag] : [])
                    existing.summary = incoming.summary ?? existing.summary
                    existing.bpm = incoming.bpm ?? existing.bpm
                    existing.musicalKey = incoming.musicalKey ?? existing.musicalKey
                    existing.previewURL = incoming.previewURL ?? existing.previewURL
                    existing.thumbnailURL = incoming.thumbnailURL ?? existing.thumbnailURL
                    existing.pageURL = incoming.pageURL ?? existing.pageURL
                    existing.remote.merge(incoming.remote) { _, new in new }
                    existing.popularity = incoming.popularity ?? existing.popularity
                    if existing.state < .original {
                        // Nothing downloaded yet, so the provider's word is all we have.
                        existing.kind = incoming.kind
                        existing.duration = incoming.duration ?? existing.duration
                        existing.hasAlpha = incoming.hasAlpha
                        existing.width = incoming.width ?? existing.width
                        existing.height = incoming.height ?? existing.height
                        existing.size = incoming.size ?? existing.size
                        existing.licenceClass = incoming.licenceClass
                        existing.creditLine = incoming.creditLine
                    }
                    existing.updatedAt = Date()
                    try db.run(Self.upsertSQL, Self.bindings(for: existing))
                    merged.append(existing)
                }
                return merged
            }
        }
    }

    private static let selectAssets = """
    SELECT a.*,
        EXISTS (SELECT 1 FROM favourites f WHERE f.asset_id = a.id) AS is_favourite,
        (SELECT MAX(u.used_at) FROM usage u WHERE u.asset_id = a.id) AS last_used
    FROM assets a
    """

    private func assetUnlocked(id: String) throws -> Asset? {
        try db.query("\(Self.selectAssets) WHERE a.id = ?", [.text(id)]).first.map(Self.asset(from:))
    }

    /// One asset by ID, with its favourite flag and last use filled in.
    public func asset(id: String) throws -> Asset? {
        try locked { try assetUnlocked(id: id) }
    }

    /// Several assets by ID, in the order asked for, skipping unknown IDs.
    public func assets(ids: [String]) throws -> [Asset] {
        try locked { try ids.compactMap { try assetUnlocked(id: $0) } }
    }

    /// Removes an asset and its favourite flag. Licence snapshots and usage
    /// records stay: they're the history of what was agreed and used.
    public func delete(id: String) throws {
        try locked {
            try db.transaction {
                try db.run("DELETE FROM assets WHERE id = ?", [.text(id)])
                try db.run("DELETE FROM favourites WHERE asset_id = ?", [.text(id)])
            }
        }
    }

    // MARK: - Search

    /// FTS5 query for free text: every word must match, each as a prefix.
    /// Words are quoted so punctuation and FTS keywords in the text are
    /// just words.
    static func ftsExpression(_ text: String) -> String? {
        // Emoji are matched separately; their variation selectors count as
        // marks and would otherwise become words of their own.
        let words = String(text.filter { !isEmoji($0) })
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        // Parenthesised groups need an explicit AND between them.
        return words.map { word in
            let forms = SearchWords.forms(word)
            let terms = ["\"\(forms.prefix)\"*"] + forms.whole.map { "\"\($0)\"" }
            return "(" + terms.joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
    }

    /// Emoji typed into a search ("🚀"). The tokenizer drops them, so they
    /// match the tags directly (Noto stickers carry their emoji as a tag).
    static func emoji(in text: String) -> [String] {
        text.filter(isEmoji).map(String.init)
    }

    static func isEmoji(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && character.unicodeScalars.count > 1)
    }

    private func buildQuery(_ query: AssetQuery, counting: Bool) -> (String, [SQLValue]) {
        var sql: String
        var bindings: [SQLValue] = []
        let fts = Self.ftsExpression(query.text)
        if counting {
            sql = "SELECT COUNT(*) AS n FROM assets a"
        } else {
            sql = """
            SELECT a.*,
                EXISTS (SELECT 1 FROM favourites f WHERE f.asset_id = a.id) AS is_favourite,
                (SELECT MAX(u.used_at) FROM usage u WHERE u.asset_id = a.id) AS last_used
            """
            // bm25 is lower for better matches. Name counts most, then tags,
            // then the provider ID, description and the rest.
            sql += fts == nil ? " FROM assets a" : ", bm25(assets_fts, 10.0, 5.0, 1.0, 0.5, 2.0, 0.5) AS rank FROM assets a"
        }
        var conditions: [String] = []
        if let fts {
            sql += " JOIN assets_fts ON assets_fts.rowid = a.key"
            conditions.append("assets_fts MATCH ?")
            bindings.append(.text(fts))
        }
        for emoji in Self.emoji(in: query.text) {
            conditions.append("instr(a.tags, ?) > 0")
            bindings.append(.text(emoji))
        }
        func inList<T>(_ column: String, _ values: [T], _ value: (T) -> SQLValue) {
            guard !values.isEmpty else { return }
            conditions.append("\(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))")
            bindings.append(contentsOf: values.map(value))
        }
        inList("a.kind", query.kinds.map(\.rawValue).sorted()) { .text($0) }
        inList("a.provider", query.providers.sorted()) { .text($0) }
        inList("a.licence_class", query.licenceClasses.map(\.rawValue).sorted()) { .text($0) }
        if let hasAlpha = query.hasAlpha {
            conditions.append("a.has_alpha = ?")
            bindings.append(SQLValue(hasAlpha))
        }
        if let value = query.minDuration { conditions.append("a.duration >= ?"); bindings.append(.real(value)) }
        if let value = query.maxDuration { conditions.append("a.duration <= ?"); bindings.append(.real(value)) }
        if let value = query.minBPM { conditions.append("a.bpm >= ?"); bindings.append(.real(value)) }
        if let value = query.maxBPM { conditions.append("a.bpm <= ?"); bindings.append(.real(value)) }
        if let minState = query.minState {
            let allowed = AssetState.allCases.filter { $0 >= minState }.map(\.rawValue)
            inList("a.state", allowed) { .text($0) }
        }
        if query.favouritesOnly {
            conditions.append("EXISTS (SELECT 1 FROM favourites f WHERE f.asset_id = a.id)")
        }
        if query.usedOnly {
            conditions.append("EXISTS (SELECT 1 FROM usage u WHERE u.asset_id = a.id)")
        }
        if let projectID = query.projectID {
            conditions.append("EXISTS (SELECT 1 FROM usage u WHERE u.asset_id = a.id AND u.project_id = ?)")
            bindings.append(.text(projectID))
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        guard !counting else { return (sql, bindings) }

        let sort = query.sort ?? (fts == nil ? .popular : .relevance)
        switch sort {
        case .relevance where fts != nil:
            sql += " ORDER BY rank, a.popularity IS NULL, a.popularity DESC, a.name COLLATE NOCASE"
        case .relevance, .popular:
            sql += " ORDER BY a.popularity IS NULL, a.popularity DESC, a.added_at DESC, a.name COLLATE NOCASE"
        case .name:
            sql += " ORDER BY a.name COLLATE NOCASE, a.id"
        case .newest:
            sql += " ORDER BY a.added_at DESC, a.name COLLATE NOCASE"
        case .lastUsed:
            sql += " ORDER BY last_used IS NULL, last_used DESC, a.name COLLATE NOCASE"
        }
        sql += " LIMIT ? OFFSET ?"
        bindings.append(.integer(Int64(max(0, query.limit))))
        bindings.append(.integer(Int64(max(0, query.offset))))
        return (sql, bindings)
    }

    /// Runs a search of the catalogue.
    public func search(_ query: AssetQuery) throws -> [Asset] {
        let (sql, bindings) = buildQuery(query, counting: false)
        return try locked { try db.query(sql, bindings).map(Self.asset(from:)) }
    }

    /// How many assets match, ignoring limit and offset.
    public func count(_ query: AssetQuery) throws -> Int {
        let (sql, bindings) = buildQuery(query, counting: true)
        return try locked { try db.query(sql, bindings).first?.int("n") ?? 0 }
    }

    // MARK: - Licences

    /// Adds a licence snapshot. Earlier snapshots are kept.
    public func addLicence(_ licence: AssetLicence, for assetID: String) throws {
        try locked {
            try db.run("""
            INSERT INTO licences (asset_id, name, spdx, licence_class, url, text, holder, credit_line, certificate, source_url, notes, captured_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(assetID), .text(licence.name), SQLValue(licence.spdx), .text(licence.licenceClass.rawValue),
                SQLValue(licence.url?.absoluteString), SQLValue(licence.text), SQLValue(licence.holder),
                SQLValue(licence.creditLine), SQLValue(licence.certificate), SQLValue(licence.sourceURL?.absoluteString),
                SQLValue(licence.notes), SQLValue(licence.capturedAt)
            ])
        }
    }

    private static func licence(from row: SQLRow) -> AssetLicence {
        AssetLicence(
            name: row.string("name") ?? "",
            spdx: row.string("spdx"),
            licenceClass: LicenceClass(rawValue: row.string("licence_class") ?? "") ?? .unknown,
            url: row.string("url").flatMap(URL.init(string:)),
            text: row.string("text"),
            holder: row.string("holder"),
            creditLine: row.string("credit_line"),
            certificate: row.string("certificate"),
            sourceURL: row.string("source_url").flatMap(URL.init(string:)),
            notes: row.string("notes"),
            capturedAt: row.date("captured_at") ?? Date()
        )
    }

    /// The most recent licence snapshot for an asset.
    public func licence(for assetID: String) throws -> AssetLicence? {
        try locked {
            try db.query("SELECT * FROM licences WHERE asset_id = ? ORDER BY captured_at DESC, id DESC LIMIT 1", [.text(assetID)])
                .first.map(Self.licence(from:))
        }
    }

    /// Every licence snapshot for an asset, oldest first.
    public func licenceHistory(for assetID: String) throws -> [AssetLicence] {
        try locked {
            try db.query("SELECT * FROM licences WHERE asset_id = ? ORDER BY captured_at, id", [.text(assetID)])
                .map(Self.licence(from:))
        }
    }

    // MARK: - Usage

    /// Records that an asset was used in a project.
    public func recordUsage(_ usage: AssetUsage) throws {
        try locked {
            try db.run(
                "INSERT INTO usage (asset_id, project_id, project_path, media_id, media_path, used_at) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(usage.assetID), .text(usage.projectID), SQLValue(usage.projectPath), SQLValue(usage.mediaID), SQLValue(usage.mediaPath), SQLValue(usage.usedAt)]
            )
        }
    }

    private static func usage(from row: SQLRow) -> AssetUsage {
        AssetUsage(
            assetID: row.string("asset_id") ?? "",
            projectID: row.string("project_id") ?? "",
            projectPath: row.string("project_path"),
            mediaID: row.string("media_id"),
            mediaPath: row.string("media_path"),
            usedAt: row.date("used_at") ?? Date()
        )
    }

    /// Every use of an asset, oldest first.
    public func usage(forAsset assetID: String) throws -> [AssetUsage] {
        try locked { try db.query("SELECT * FROM usage WHERE asset_id = ? ORDER BY used_at, id", [.text(assetID)]).map(Self.usage(from:)) }
    }

    /// Every asset use recorded for a project, oldest first.
    public func usage(forProject projectID: String) throws -> [AssetUsage] {
        try locked { try db.query("SELECT * FROM usage WHERE project_id = ? ORDER BY used_at, id", [.text(projectID)]).map(Self.usage(from:)) }
    }

    // MARK: - Favourites

    /// Marks or unmarks a favourite. Favourites keep their files on disk.
    public func setFavourite(_ assetID: String, _ favourite: Bool) throws {
        try locked {
            if favourite {
                try db.run("INSERT OR IGNORE INTO favourites (asset_id, added_at) VALUES (?, ?)", [.text(assetID), SQLValue(Date())])
            } else {
                try db.run("DELETE FROM favourites WHERE asset_id = ?", [.text(assetID)])
            }
        }
    }

    /// Whether an asset is a favourite.
    public func isFavourite(_ assetID: String) throws -> Bool {
        try locked { try !db.query("SELECT 1 FROM favourites WHERE asset_id = ?", [.text(assetID)]).isEmpty }
    }

    /// Assets that must keep their original on disk: favourites and
    /// anything used in a project.
    public func pinnedIDs() throws -> Set<String> {
        try locked {
            let rows = try db.query("SELECT asset_id FROM favourites UNION SELECT asset_id FROM usage")
            return Set(rows.compactMap { $0.string("asset_id") })
        }
    }

    // MARK: - Import folders

    /// A watched folder of assets downloaded by hand.
    public struct ImportFolderRecord: Codable, Equatable, Sendable {
        public var id: String
        public var path: String
        public var name: String
        public var addedAt: Date
        public var lastScan: Date?

        public init(id: String, path: String, name: String, addedAt: Date = Date(), lastScan: Date? = nil) {
            self.id = id
            self.path = path
            self.name = name
            self.addedAt = addedAt
            self.lastScan = lastScan
        }
    }

    /// Every import folder, by name.
    public func importFolders() throws -> [ImportFolderRecord] {
        try locked {
            try db.query("SELECT * FROM import_folders ORDER BY name COLLATE NOCASE").map {
                ImportFolderRecord(id: $0.string("id") ?? "", path: $0.string("path") ?? "", name: $0.string("name") ?? "", addedAt: $0.date("added_at") ?? Date(), lastScan: $0.date("last_scan"))
            }
        }
    }

    /// Adds an import folder or updates its name, path and last scan.
    public func saveImportFolder(_ folder: ImportFolderRecord) throws {
        try locked {
            try db.run("""
            INSERT INTO import_folders (id, path, name, added_at, last_scan) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET path = excluded.path, name = excluded.name, last_scan = excluded.last_scan
            """, [.text(folder.id), .text(folder.path), .text(folder.name), SQLValue(folder.addedAt), SQLValue(folder.lastScan)])
        }
    }

    /// Notes when a folder was last scanned. Does nothing if the folder has
    /// been removed meanwhile.
    public func recordImportFolderScan(id: String, at date: Date) throws {
        try locked { try db.run("UPDATE import_folders SET last_scan = ? WHERE id = ?", [SQLValue(date), .text(id)]) }
    }

    /// Forgets an import folder. Its assets are left to the caller.
    public func removeImportFolder(id: String) throws {
        try locked { try db.run("DELETE FROM import_folders WHERE id = ?", [.text(id)]) }
    }

    /// Forgets an import folder and, in the same transaction, its assets,
    /// except favourites and anything used in a project. A scan saving at
    /// the same moment either lands first (and its rows go too) or finds
    /// the folder gone and saves nothing. Returns the IDs removed.
    public func removeImportFolderAndAssets(id: String) throws -> [String] {
        try locked {
            try db.transaction {
                try db.run("DELETE FROM import_folders WHERE id = ?", [.text(id)])
                let condition = """
                WHERE provider = 'import' AND json_extract(remote, '$.folder') = ?
                  AND id NOT IN (SELECT asset_id FROM favourites)
                  AND id NOT IN (SELECT asset_id FROM usage)
                """
                let ids = try db.query("SELECT id FROM assets \(condition)", [.text(id)]).compactMap { $0.string("id") }
                try db.run("DELETE FROM assets \(condition)", [.text(id)])
                return ids
            }
        }
    }

    /// Saves a scan's rows only if their import folder is still registered,
    /// in one transaction. Returns false (having saved nothing) when the
    /// folder was removed during the scan.
    public func upsert(_ assets: [Asset], ifImportFolderExists folderID: String) throws -> Bool {
        try locked {
            try db.transaction {
                guard !(try db.query("SELECT 1 AS present FROM import_folders WHERE id = ?", [.text(folderID)])).isEmpty else { return false }
                for asset in assets { try db.run(Self.upsertSQL, Self.bindings(for: asset)) }
                return true
            }
        }
    }

    // MARK: - Maintenance

    /// Deletes rows that only came from provider searches, weren't
    /// refreshed since `date`, and aren't favourites, used anywhere or part
    /// of the starter set. Returns the IDs removed.
    @discardableResult
    public func pruneRemote(notUpdatedSince date: Date) throws -> [String] {
        try locked {
            try db.transaction {
                let condition = """
                WHERE state IN ('remote', 'preview') AND updated_at < ?
                  AND id NOT IN (SELECT asset_id FROM favourites)
                  AND id NOT IN (SELECT asset_id FROM usage)
                  AND COALESCE(json_extract(remote, '$.starter'), '') != '1'
                """
                let ids = try db.query("SELECT id FROM assets \(condition)", [SQLValue(date)]).compactMap { $0.string("id") }
                try db.run("DELETE FROM assets \(condition)", [SQLValue(date)])
                return ids
            }
        }
    }
}

extension JSONEncoder {
    /// Stable output for files people might diff: sorted keys, ISO dates.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    /// Matches `JSONEncoder.sorted`.
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
