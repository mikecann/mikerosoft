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

func drawTaskbarIcon(item: TaskbarItem, rect: NSRect) {
    if let pid = item.pid,
       let app = NSRunningApplication(processIdentifier: pid),
       let icon = app.icon {
        icon.draw(in: rect)
        return
    }

    if !item.appPath.isEmpty {
        NSWorkspace.shared.icon(forFile: item.appPath).draw(in: rect)
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
