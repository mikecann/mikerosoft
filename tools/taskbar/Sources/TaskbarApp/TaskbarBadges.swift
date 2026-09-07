import AppKit
import ApplicationServices

// Dock badges belong to applications, so every window of an app shares its
// badge. Unknown textual status markers are represented as a dot, not a count.
func taskbarBadgeText(_ label: String?) -> String? {
    guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
          !label.isEmpty, label != "0" else { return nil }
    if let count = Int(label), count > 0 { return count > 99 ? "99+" : String(count) }
    return ""
}

func applyingTaskbarBadges(_ badges: [String: String], to items: [TaskbarItem]) -> [TaskbarItem] {
    items.map { item in
        var item = item
        item.badgeLabel = badges[URL(fileURLWithPath: item.appPath).standardizedFileURL.path]
        return item
    }
}

final class TaskbarBadgeSampler {
    static let shared = TaskbarBadgeSampler()
    private let lock = NSLock()
    private let collect: () -> [String: String]
    private let schedule: (@escaping () -> Void) -> Void
    private var cached: [String: String] = [:]
    private var lastRefresh = Date.distantPast
    private var refreshing = false
    var onChange: (() -> Void)?

    init(
        collect: @escaping () -> [String: String] = collectDockBadges,
        schedule: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    ) {
        self.collect = collect
        self.schedule = schedule
    }

    func snapshot(now: Date = Date()) -> [String: String] {
        lock.lock()
        let result = cached
        let shouldRefresh = !refreshing && now.timeIntervalSince(lastRefresh) >= 2
        if shouldRefresh {
            refreshing = true
            lastRefresh = now
        }
        lock.unlock()
        if shouldRefresh {
            // Accessibility calls can block when the Dock is busy. Never do
            // them in drawing or on the taskbar's main event loop.
            schedule { [weak self] in
                guard let self else { return }
                let badges = self.collect()
                self.lock.lock()
                let changed = self.cached != badges
                self.cached = badges
                self.refreshing = false
                self.lock.unlock()
                if changed {
                    DispatchQueue.main.async { [weak self] in self?.onChange?() }
                }
            }
        }
        return result
    }
}

func collectDockBadges() -> [String: String] {
    guard AXIsProcessTrusted(),
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return [:] }
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.2)
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    var result: [String: String] = [:]
    // The Dock exposes application icons under its list. Ignore document,
    // folder and Handoff items; their status labels have different meanings.
    let lists = attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []
    for list in lists {
        for item in attribute(list, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            guard attribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
                  let url = attribute(item, kAXURLAttribute) as? URL,
                  let label = attribute(item, "AXStatusLabel") as? String,
                  taskbarBadgeText(label) != nil else { continue }
            result[url.standardizedFileURL.path] = label
        }
    }
    return result
}

func drawTaskbarBadge(_ label: String?, in iconRect: NSRect) {
    guard let text = taskbarBadgeText(label), iconRect.width >= 12 else { return }
    let font = NSFont.systemFont(ofSize: 8, weight: .bold)
    let textSize = (text as NSString).size(withAttributes: [.font: font])
    let height: CGFloat = text.isEmpty ? 7 : 12
    let width = text.isEmpty ? height : min(iconRect.width, max(height, ceil(textSize.width) + 5))
    let rect = NSRect(x: iconRect.maxX - width, y: iconRect.maxY - height, width: width, height: height)
    NSColor.systemRed.setFill()
    NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
    if !text.isEmpty {
        (text as NSString).draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                               withAttributes: [.font: font, .foregroundColor: NSColor.white])
    }
}
