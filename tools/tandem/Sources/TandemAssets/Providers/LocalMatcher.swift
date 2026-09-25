import Foundation

/// Searching a provider's whole index in memory (Noto, SVGL and Fontsource
/// publish everything in one response). Every query word must be the start
/// of some word in the asset; matches in the name rank above matches in
/// tags.
struct LocalMatcher {
    let words: [String]
    /// Emoji in the query, matched against tags as they are.
    let emoji: [String]

    init(_ text: String) {
        words = Self.tokens(text)
        emoji = AssetCatalog.emoji(in: text)
    }

    var isEmpty: Bool { words.isEmpty && emoji.isEmpty }

    static func tokens(_ text: String) -> [String] {
        String(text.filter { !AssetCatalog.isEmoji($0) })
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// A score above zero when every word matches: 2 for each word found in
    /// the name, 1 for each found only in the other text. Nil when a word
    /// doesn't match at all.
    func score(name: String, other: [String]) -> Int? {
        for character in emoji where !other.contains(character) { return nil }
        guard !words.isEmpty else { return emoji.isEmpty ? 0 : 1 }
        let nameTokens = Self.tokens(name)
        let otherTokens = other.flatMap(Self.tokens)
        var total = 0
        for word in words {
            let forms = SearchWords.forms(word)
            func found(in tokens: [String]) -> Bool {
                tokens.contains { token in token.hasPrefix(forms.prefix) || forms.whole.contains(token) }
            }
            if found(in: nameTokens) {
                total += 2
            } else if found(in: otherTokens) {
                total += 1
            } else {
                return nil
            }
        }
        return total
    }

    /// Filters and orders assets: best score first, then popularity, then
    /// the provider's own order.
    func rank(_ assets: [Asset]) -> [Asset] {
        assets.enumerated()
            .compactMap { index, asset in score(name: asset.name, other: asset.tags + [asset.providerID]).map { (asset, $0, index) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if (a.0.popularity ?? 0) != (b.0.popularity ?? 0) { return (a.0.popularity ?? 0) > (b.0.popularity ?? 0) }
                return a.2 < b.2
            }
            .map(\.0)
    }

    /// One page of results, 1-based.
    static func page<T>(_ items: [T], page: Int, perPage: Int) -> [T] {
        let size = max(1, perPage)
        let start = max(0, page - 1) * size
        guard start < items.count else { return [] }
        return Array(items[start..<min(items.count, start + size)])
    }
}

/// The forms a search word matches. The word itself matches as a prefix,
/// so a half-typed word ("generat") still finds "generated". Its other
/// forms match only as whole words, so "clicks" finds "click" and
/// "typing" finds "type" without "note" finding "nothing". (A stemmer in
/// the index would break search as you type: it stores "gener", which
/// "generat" isn't a prefix of.)
enum SearchWords {
    /// The typed word (a prefix) and its other forms (whole words).
    static func forms(_ word: String) -> (prefix: String, whole: [String]) {
        let word = word.lowercased()
        var whole: [String] = []
        func add(_ form: String) {
            if form.count >= 2, form != word, !whole.contains(form) { whole.append(form) }
        }
        /// "runn" also gives "run"; "typ" also gives "type".
        func addRoot(_ root: String) {
            add(root)
            let letters = Array(root)
            if letters.count > 2, letters[letters.count - 1] == letters[letters.count - 2], !"aeiou".contains(letters[letters.count - 1]) {
                add(String(letters.dropLast()))
            } else {
                add(root + "e")
            }
        }
        if word.hasSuffix("ies"), word.count > 4 { add(String(word.dropLast(3)) + "y") }
        // "boxes" and "whooshes" drop "es"; "notes" only drops the "s".
        if word.hasSuffix("es"), word.count > 4, ["s", "x", "z", "ch", "sh"].contains(where: { word.dropLast(2).hasSuffix($0) }) {
            add(String(word.dropLast(2)))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 { add(String(word.dropLast())) }
        if word.hasSuffix("ing"), word.count > 5 { addRoot(String(word.dropLast(3))) }
        if word.hasSuffix("ed"), word.count > 4 { addRoot(String(word.dropLast(2))) }
        // "type" also finds "typing" and "typed".
        if word.hasSuffix("e"), word.count > 3 {
            let stem = String(word.dropLast())
            add(stem + "ing")
            add(stem + "ed")
        }
        return (word, whole)
    }

    /// Every form, the typed word first. For tests and logs.
    static func variants(_ word: String) -> [String] {
        let forms = forms(word)
        return [forms.prefix] + forms.whole
    }
}
