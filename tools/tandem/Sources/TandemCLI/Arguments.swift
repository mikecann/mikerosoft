import Foundation

/// A usage mistake: printed with a hint and exit code 2.
struct UsageError: Error {
    var message: String
}

/// Command-line arguments, parsed by hand: a command, positional
/// arguments, `--name value` options and `--flag` switches.
struct Arguments {
    var command: String?
    var positionals: [String] = []
    var options: [String: String] = [:]
    /// Every value of options that can repeat, like `--search a --search b`.
    var repeated: [String: [String]] = [:]
    var flags: Set<String> = []

    /// Options that take a value.
    static let valueOptions: Set<String> = [
        "project", "author", "from", "to", "min", "keep", "limit", "label", "key", "expect",
        "output", "preset", "width", "height", "port", "timeout", "name", "format",
        "out", "search", "rewrite", "recipe", "max-words", "y", "track", "size",
        "kind", "provider", "at", "duration", "variations"
    ]
    /// Options that are on or off.
    static let flagOptions: Set<String> = ["json", "refresh", "words", "summary", "apply", "dry-run", "help", "version", "once", "portrait", "online", "optional", "with-cache"]
    static let shortOptions: [String: String] = ["o": "output", "h": "help", "v": "version"]

    static func parse(_ arguments: [String]) throws -> Arguments {
        var result = Arguments()
        var index = 0
        func value(for name: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw UsageError(message: "--\(name) needs a value.") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                result.positionals += arguments[(index + 1)...]
                break
            }
            if argument.hasPrefix("--") {
                var name = String(argument.dropFirst(2))
                var inline: String?
                if let equals = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if valueOptions.contains(name) {
                    let given = try inline ?? value(for: name)
                    result.options[name] = given
                    result.repeated[name, default: []].append(given)
                } else if flagOptions.contains(name) {
                    guard inline == nil else { throw UsageError(message: "--\(name) doesn't take a value.") }
                    result.flags.insert(name)
                } else {
                    let known = Array(valueOptions.union(flagOptions))
                    let hint = closest(name, in: known).map { " Did you mean --\($0)?" } ?? ""
                    throw UsageError(message: "Unknown option --\(name).\(hint)")
                }
            } else if argument.hasPrefix("-"), argument.count > 1, !argument.dropFirst().allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) {
                let short = String(argument.dropFirst())
                guard let name = shortOptions[short] else { throw UsageError(message: "Unknown option \(argument).") }
                if valueOptions.contains(name) {
                    let given = try value(for: name)
                    result.options[name] = given
                    result.repeated[name, default: []].append(given)
                } else {
                    result.flags.insert(name)
                }
            } else if result.command == nil {
                result.command = argument
            } else {
                result.positionals.append(argument)
            }
            index += 1
        }
        return result
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    /// All values given for an option that may repeat.
    func values(_ name: String) -> [String] { repeated[name] ?? [] }

    /// Fails when an option or flag was given that `command` doesn't use.
    func check(allowed: Set<String>, command: String) throws {
        let global: Set<String> = ["project", "author", "json", "help"]
        for name in Set(options.keys).union(flags) where !allowed.contains(name) && !global.contains(name) {
            let takes = allowed.sorted().map { "--\($0)" }.joined(separator: ", ")
            throw UsageError(message: "`tandem \(command)` doesn't take --\(name).\(takes.isEmpty ? "" : " It takes \(takes).")")
        }
    }

    func positional(_ index: Int, _ name: String, command: String) throws -> String {
        guard index < positionals.count else {
            throw UsageError(message: "`tandem \(command)` needs \(name).")
        }
        return positionals[index]
    }

    func expectPositionals(atMost count: Int, command: String) throws {
        if positionals.count > count {
            let extra = positionals[count...].joined(separator: " ")
            throw UsageError(message: "`tandem \(command)` got unexpected arguments: \(extra)")
        }
    }

    func number(_ name: String) throws -> Double? {
        guard let text = options[name] else { return nil }
        guard let value = Double(text) else { throw UsageError(message: "--\(name) needs a number, not \"\(text)\".") }
        return value
    }

    func integer(_ name: String) throws -> Int? {
        guard let text = options[name] else { return nil }
        guard let value = Int(text) else { throw UsageError(message: "--\(name) needs a whole number, not \"\(text)\".") }
        return value
    }

    static func closest(_ word: String, in candidates: [String]) -> String? {
        var best: (String, Int)?
        for candidate in candidates {
            let distance = editDistance(word, candidate)
            if distance <= 2, distance < (best?.1 ?? Int.max) { best = (candidate, distance) }
        }
        return best?.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
