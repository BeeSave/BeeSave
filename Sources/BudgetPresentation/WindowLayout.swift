import Foundation

/// Screen fitting works in logical points and includes the real native frame.
public enum WindowLayout {
    public static let workspaceSize = CGSize(width: 1440, height: 900)
    public static let accessSize = CGSize(width: 420, height: 320)

    public static func fitted(_ proposed: CGRect, in available: CGRect, margin: CGFloat = 24) -> CGRect {
        guard available.width > 0, available.height > 0 else { return proposed }
        let inset = min(max(0, margin), max(0, (min(available.width, available.height) - 1) / 2))
        let bounds = available.insetBy(dx: inset, dy: inset)
        let width = min(max(1, proposed.width), bounds.width)
        let height = min(max(1, proposed.height), bounds.height)
        return CGRect(x: min(max(proposed.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(proposed.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    public static func centered(size: CGSize, in available: CGRect) -> CGRect {
        fitted(CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height), in: available)
    }
}

public enum NoticeKind: String, Sendable { case information, success, warning }
public struct AppNotice: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let kind: NoticeKind
    public private(set) var remaining: TimeInterval
    public init(_ text: String, kind: NoticeKind = .information, duration: TimeInterval = 4) {
        id = UUID(); self.text = text; self.kind = kind; remaining = max(0, duration)
    }
    public var transient: Bool { kind != .warning }
    /// Only visible foreground time is charged. Tokens reject stale timers.
    public mutating func elapse(_ seconds: TimeInterval, token: UUID, visible: Bool) -> Bool {
        guard token == id, transient, visible else { return false }
        remaining = max(0, remaining - max(0, seconds))
        return remaining == 0
    }
}
