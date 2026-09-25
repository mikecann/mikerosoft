import Foundation

/// A small starter set for developer videos, shipped as data: about 40
/// animated emoji, 32 icons and the tech logos Mike shows most. Installing
/// it only adds catalogue rows (tagged "starter"); each file is fetched and
/// normalised the first time it's used.
public enum StarterContent {
    public static let tag = "starter"

    /// Noto animated emoji: code point, tags and category, as in Google's
    /// index (September 2026).
    public static let notoEmoji: [(codepoint: String, tags: [String], category: String)] = [
        ("1f680", [":rocket:"], "Travel and places"),
        ("1f525", [":fire:", ":burn:", ":lit:"], "Smileys and emotions"),
        ("26a1", [":electricity:", ":zap:", ":lightning:"], "Smileys and emotions"),
        ("2705", [":check-mark:", ":check-mark-green:"], "Symbols"),
        ("274c", [":cross-mark:", ":x:"], "Symbols"),
        ("26a0_fe0f", [":warning:"], "Symbols"),
        ("1f4af", [":100:", ":one-hundred:", ":hundred:", ":points:"], "Smileys and emotions"),
        ("1f389", [":party-popper:"], "Smileys and emotions"),
        ("1f973", [":partying-face:"], "Smileys and emotions"),
        ("1f914", [":thinking-face:"], "Smileys and emotions"),
        ("1f92f", [":mind-blown:", ":exploding-head:"], "Smileys and emotions"),
        ("1f440", [":eyes:"], "Smileys and emotions"),
        ("1f60e", [":sunglasses-face:"], "Smileys and emotions"),
        ("1f602", [":joy:"], "Smileys and emotions"),
        ("1f923", [":rofl:"], "Smileys and emotions"),
        ("1f62d", [":loudly-crying:"], "Smileys and emotions"),
        ("1f631", [":screaming:"], "Smileys and emotions"),
        ("1f605", [":grin-sweat:"], "Smileys and emotions"),
        ("1f643", [":upside-down-face:"], "Smileys and emotions"),
        ("1f644", [":rolling-eyes:"], "Smileys and emotions"),
        ("1f609", [":wink:"], "Smileys and emotions"),
        ("1f60d", [":heart-eyes:"], "Smileys and emotions"),
        ("1f929", [":star-struck:"], "Smileys and emotions"),
        ("1f62c", [":grimacing:"], "Smileys and emotions"),
        ("1f913", [":nerd-face:"], "Smileys and emotions"),
        ("1fae1", [":salute:"], "Smileys and emotions"),
        ("1f44d", [":thumbs-up:", ":+1:"], "Smileys and emotions"),
        ("1f44e", [":thumbs-down:"], "Smileys and emotions"),
        ("1f44f", [":clap:"], "Smileys and emotions"),
        ("1f64c", [":raising-hands:", ":hooray:"], "Smileys and emotions"),
        ("1f4aa", [":muscle:", ":flex:", ":bicep:", ":strong:"], "Smileys and emotions"),
        ("1f44b", [":wave:"], "Smileys and emotions"),
        ("1f4a1", [":light-bulb:"], "Objects"),
        ("1f4a5", [":collision:"], "Smileys and emotions"),
        ("2728", [":sparkles:"], "Smileys and emotions"),
        ("1f6a8", [":police-car-light:"], "Travel and places"),
        ("23f0", [":alarm-clock:"], "Objects"),
        ("231b", [":hourglass-done:"], "Objects"),
        ("1f4b8", [":money-with-wings:"], "Objects"),
        ("1f41b", [":bug:"], "Animals and nature"),
        ("1f480", [":skull:"], "Smileys and emotions"),
        ("1f3af", [":direct-hit:", ":target:"], "Activities and events"),
        ("1f4c8", [":chart-increasing:"], "Objects")
    ]

    /// Icons from Material Design Icons (Apache 2.0, no credit needed),
    /// chosen for developer videos.
    public static let iconifyIcons: [String] = [
        "mdi:check-bold", "mdi:close-thick", "mdi:alert", "mdi:rocket-launch", "mdi:fire",
        "mdi:lightning-bolt", "mdi:clock-outline", "mdi:timer-sand", "mdi:database", "mdi:code-braces",
        "mdi:console", "mdi:server", "mdi:cloud", "mdi:api", "mdi:web",
        "mdi:lock", "mdi:key", "mdi:shield-check", "mdi:bug", "mdi:cog",
        "mdi:account", "mdi:account-group", "mdi:magnify", "mdi:arrow-right", "mdi:refresh",
        "mdi:lightbulb-on", "mdi:star", "mdi:heart", "mdi:thumb-up", "mdi:source-branch",
        "mdi:file-code", "mdi:robot"
    ]

    /// What Iconify says about the sets the starter icons come from.
    public static let iconSets: [String: IconifyProvider.IconSet] = [
        "mdi": IconifyProvider.IconSet(
            name: "Material Design Icons",
            author: .init(name: "Pictogrammers", url: "https://github.com/Templarian/MaterialDesign"),
            license: .init(title: "Apache 2.0", spdx: "Apache-2.0", url: "https://github.com/Templarian/MaterialDesign/blob/master/LICENSE"),
            category: "Material",
            palette: false
        )
    ]

    /// SVGL logos: the brand, the file (`https://svgl.app/library/<file>.svg`),
    /// the background it's drawn for, and whether it's a wordmark.
    public static let svglLogos: [(title: String, file: String, background: String?, wordmark: Bool, categories: [String])] = [
        ("Convex", "convex", nil, false, ["Database", "Software"]),
        ("Convex", "convex_wordmark_light", "light", true, ["Database", "Software"]),
        ("Convex", "convex_wordmark_dark", "dark", true, ["Database", "Software"]),
        ("React", "react_light", "light", false, ["Library"]),
        ("React", "react_dark", "dark", false, ["Library"]),
        ("Next.js", "nextjs_icon_dark", nil, false, ["Framework", "Vercel"]),
        ("TypeScript", "typescript", nil, false, ["Language"]),
        ("OpenAI", "openai", "light", false, ["AI"]),
        ("OpenAI", "openai_dark", "dark", false, ["AI"]),
        ("Anthropic", "anthropic_black", "light", false, ["AI"]),
        ("Anthropic", "anthropic_white", "dark", false, ["AI"]),
        ("Vercel", "vercel", "light", false, ["Hosting", "Vercel"]),
        ("Vercel", "vercel_dark", "dark", false, ["Hosting", "Vercel"]),
        ("GitHub", "github_light", "light", false, ["Software"]),
        ("GitHub", "github_dark", "dark", false, ["Software"])
    ]

    /// Every starter asset, as catalogue rows waiting to be fetched. Each
    /// carries `remote["starter"] = "1"` so pruning leaves it alone.
    public static func assets(iconColour: String = "#FFFFFF") -> [Asset] {
        starterRows(iconColour: iconColour).map { asset in
            var marked = asset
            marked.remote["starter"] = "1"
            return marked
        }
    }

    private static func starterRows(iconColour: String) -> [Asset] {
        var result: [Asset] = []
        for emoji in notoEmoji {
            var asset = NotoEmojiProvider.asset(codepoint: emoji.codepoint, tags: emoji.tags, categories: [emoji.category])
            asset.tags.append(tag)
            result.append(asset)
        }
        for name in iconifyIcons {
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let set = iconSets[parts[0]] else { continue }
            var asset = IconifyProvider.asset(prefix: parts[0], icon: parts[1], set: set, colour: iconColour)
            asset.tags.append(tag)
            result.append(asset)
        }
        for logo in svglLogos {
            let url = "https://svgl.app/library/\(logo.file).svg"
            var name = logo.title + (logo.wordmark ? " wordmark" : "")
            if let background = logo.background { name += " (for \(background) backgrounds)" }
            result.append(Asset(
                provider: "svgl",
                providerID: logo.file,
                kind: .logo,
                name: name,
                tags: [logo.title, "logo"] + logo.categories + (logo.wordmark ? ["wordmark"] : []) + (logo.background.map { [$0] } ?? []) + [tag],
                summary: "\(logo.title) logo, a trademark of its owner",
                hasAlpha: true,
                licenceClass: .noCredit,
                previewURL: URL(string: url),
                thumbnailURL: URL(string: url),
                remote: ["svg": url, "title": logo.title]
            ))
        }
        return result
    }
}

extension AssetLibrary {
    /// Adds the starter set to the catalogue. Safe to run again: known
    /// assets keep whatever has been downloaded. Returns the starter assets
    /// as stored.
    @discardableResult
    public func installStarterContent() throws -> [Asset] {
        try catalog.mergeRemote(StarterContent.assets(iconColour: settings.iconColour))
    }
}
