import AppKit

enum TaskbarItemMetrics {
    static let leadingInset: CGFloat = 6
    static let iconTextGap: CGFloat = 4
    static let trailingInset: CGFloat = 8

    static func iconSize(for height: CGFloat) -> CGFloat {
        min(24, max(12, height - 4))
    }

    static func iconOnlyWidth(iconSize: CGFloat) -> CGFloat {
        leadingInset + iconSize + trailingInset
    }

    static func naturalWidth(textWidth: CGFloat, iconSize: CGFloat) -> CGFloat {
        leadingInset + iconSize + iconTextGap + textWidth + trailingInset
    }
}

func taskbarItemLabel(_ item: TaskbarItem) -> String {
    item.title.isEmpty ? item.owner : item.title
}

func taskbarItemShowsLabel(_ item: TaskbarItem) -> Bool {
    // A closed pinned app is a launcher, not a window, so it should look like
    // an app icon rather than consume the space of a labelled window tile.
    !(item.isPinned && item.pid == nil)
}

func preferredTaskbarItemWidth(
    for item: TaskbarItem,
    textWidth: CGFloat,
    iconSize: CGFloat,
    minimumWidth: CGFloat,
    maximumWidth: CGFloat
) -> CGFloat {
    guard taskbarItemShowsLabel(item) else {
        return TaskbarItemMetrics.iconOnlyWidth(iconSize: iconSize)
    }

    return taskbarItemWidth(
        textWidth: textWidth,
        iconSize: iconSize,
        minimumWidth: minimumWidth,
        maximumWidth: maximumWidth
    )
}

func drawTaskbarIcon(item: TaskbarItem, rect: NSRect) {
    if let icon = TaskbarIconCache.shared.icon(for: item) {
        drawTaskbarIconImage(icon, in: rect)
        return
    }

    NSColor(calibratedWhite: 0.28, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    drawTaskbarText(
        String(item.owner.prefix(1)).uppercased(),
        in: NSRect(x: rect.minX + 6, y: rect.minY + 4, width: 18, height: 18),
        size: 12,
        bold: true,
        active: true
    )
}

private func drawTaskbarIconImage(_ icon: CGImage, in rect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.interpolationQuality = .high
    context.draw(icon, in: rect)
    context.restoreGState()
}

struct TaskbarIconRequest {
    let key: String
    let pid: pid_t?
    let appPath: String

    var retryKey: String {
        "\(key)|\(pid.map(String.init) ?? "none")|\(appPath)"
    }
}

final class TaskbarIconCache {
    static let shared = TaskbarIconCache()

    private let lock = NSLock()
    private let retryInterval: TimeInterval
    private let now: () -> Date
    private let queue: DispatchQueue
    private let iconLoader: (TaskbarIconRequest) -> CGImage?
    private var icons: [String: CGImage] = [:]
    private var loadingKeys: Set<String> = []
    private var failedAt: [String: Date] = [:]

    init(
        retryInterval: TimeInterval = 30,
        now: @escaping () -> Date = { Date() },
        queue: DispatchQueue = DispatchQueue.global(qos: .utility),
        iconLoader: @escaping (TaskbarIconRequest) -> CGImage? = TaskbarIconCache.loadIcon
    ) {
        self.retryInterval = retryInterval
        self.now = now
        self.queue = queue
        self.iconLoader = iconLoader
    }

    func icon(for item: TaskbarItem) -> CGImage? {
        let request = TaskbarIconRequest(
            key: iconKey(for: item),
            pid: item.pid,
            appPath: item.appPath
        )

        lock.lock()
        if let icon = icons[request.key] {
            lock.unlock()
            return icon
        }
        purgeExpiredFailures(at: now())
        let retryIsBlocked = failedAt[request.retryKey] != nil
        let shouldLoad = !loadingKeys.contains(request.key) && !retryIsBlocked
        if shouldLoad {
            loadingKeys.insert(request.key)
        }
        lock.unlock()

        if shouldLoad {
            queue.async { [weak self] in
                guard let self else { return }
                let icon = self.iconLoader(request)
                let completedAt = self.now()
                self.lock.lock()
                if let icon {
                    self.icons[request.key] = icon
                    self.failedAt.removeValue(forKey: request.retryKey)
                } else {
                    self.failedAt[request.retryKey] = completedAt
                }
                self.loadingKeys.remove(request.key)
                self.lock.unlock()
            }
        }

        return nil
    }

    private func purgeExpiredFailures(at time: Date) {
        guard failedAt.values.contains(where: { time.timeIntervalSince($0) >= retryInterval }) else {
            return
        }
        failedAt = failedAt.filter { time.timeIntervalSince($0.value) < retryInterval }
    }

    private func iconKey(for item: TaskbarItem) -> String {
        if !item.bundleID.isEmpty || !item.appPath.isEmpty {
            return item.identity
        }
        if let pid = item.pid {
            return "pid:\(pid)"
        }
        return "owner:\(item.owner)"
    }

    private static func loadIcon(for request: TaskbarIconRequest) -> CGImage? {
        let image: NSImage?
        if !request.appPath.isEmpty {
            image = NSWorkspace.shared.icon(forFile: request.appPath)
        } else if let pid = request.pid,
                  let app = NSRunningApplication(processIdentifier: pid) {
            image = app.icon
        } else {
            image = nil
        }

        guard let image else { return nil }
        var rect = NSRect(origin: .zero, size: NSSize(width: 64, height: 64))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

func drawTaskbarText(
    _ value: String,
    in rect: NSRect,
    size: CGFloat,
    bold: Bool,
    active: Bool,
    textColor: NSColor? = nil
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
        .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
        .foregroundColor: textColor ?? (active ? NSColor(calibratedWhite: 0.10, alpha: 1.0) : NSColor(calibratedWhite: 0.90, alpha: 1.0)),
        .paragraphStyle: paragraph
    ]
    (value as NSString).draw(in: rect, withAttributes: attributes)
}
