import CoreGraphics

/// Stepping and auto-scroll position logic. Only `.line` items are stops;
/// headings, cues, and code scroll past without needing a click.
enum PromptNavigator {
    static func stops(in items: [PromptItem]) -> [Int] {
        items.indices.filter { items[$0].kind == .line }
    }

    static func first(in items: [PromptItem]) -> Int? {
        stops(in: items).first
    }

    static func last(in items: [PromptItem]) -> Int? {
        stops(in: items).last
    }

    static func next(after current: Int?, in items: [PromptItem]) -> Int? {
        let stops = stops(in: items)
        guard let current else { return stops.first }
        return stops.first { $0 > current } ?? stops.last
    }

    static func previous(before current: Int?, in items: [PromptItem]) -> Int? {
        let stops = stops(in: items)
        guard let current else { return stops.first }
        return stops.last { $0 < current } ?? stops.first
    }

    /// The line the reader is on while scrolling: the last stop whose top
    /// has reached the reading line.
    static func stop(atOffset offset: CGFloat, tops: [Int: CGFloat], in items: [PromptItem]) -> Int? {
        let stops = stops(in: items)
        return stops.last { (tops[$0] ?? .greatestFiniteMagnitude) <= offset } ?? stops.first
    }

    /// 0 at the first line, 1 at the last.
    static func progress(of current: Int?, in items: [PromptItem]) -> Double {
        let stops = stops(in: items)
        guard let current, stops.count > 1,
              let position = stops.firstIndex(where: { $0 >= current })
        else { return 0 }
        return Double(position) / Double(stops.count - 1)
    }
}
