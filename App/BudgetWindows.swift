import AppKit
import SwiftUI
import BudgetPresentation

enum BudgetWindowRole: String { case access, workspace, settings }

@MainActor enum BudgetWindows {
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    private static var roles: [ObjectIdentifier: BudgetWindowRole] = [:]
    private static let geometryKey = "BeeSave.workspace.frame.v2"
    private static var fullScreenAfterUnlock = false
    private static var sessionLocked = true
    static var reopen: (() -> Void)?
    static func sessionUnlocked() { sessionLocked = false }
    static var sheetAvailableSize: CGSize? {
        guard let window = windows.allObjects.first(where: { roles[ObjectIdentifier($0)] == .workspace && $0.isVisible }) else { return nil }
        let size = window.contentLayoutRect.size
        return CGSize(width: max(320, size.width - 48), height: max(320, size.height - 48))
    }

    static func register(_ window: NSWindow, role: BudgetWindowRole = .workspace) {
        windows.add(window); roles[ObjectIdentifier(window)] = role
    }
    static func unregister(_ window: NSWindow) { windows.remove(window); roles.removeValue(forKey: ObjectIdentifier(window)) }
    static func preferred(ordered: [NSWindow], key: NSWindow?) -> NSWindow? {
        func eligible(_ window: NSWindow) -> Bool {
            guard windows.contains(window) else { return false }
            let role = roles[ObjectIdentifier(window)]
            return role == (sessionLocked ? .access : .workspace)
        }
        if let key, eligible(key) { return key }
        if let parent = key?.sheetParent, eligible(parent) { return parent }
        return ordered.first { eligible($0) && $0.isVisible } ?? ordered.first(where: eligible)
    }
    static func bringForward() {
        guard let window = preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); window.attachedSheet?.makeKeyAndOrderFront(nil)
    }
    static func save(_ window: NSWindow) {
        guard roles[ObjectIdentifier(window)] == .workspace, window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        let f = window.frame
        UserDefaults.standard.set([f.origin.x, f.origin.y, f.width, f.height], forKey: geometryKey)
    }
    static func hideSensitiveWindows() {
        sessionLocked = true
        for window in windows.allObjects where roles[ObjectIdentifier(window)] != .access {
            if roles[ObjectIdentifier(window)] == .workspace {
                fullScreenAfterUnlock = window.styleMask.contains(.fullScreen)
                save(window)
            }
            window.attachedSheet?.orderOut(nil)
            window.orderOut(nil)
        }
    }
    static func configure(_ window: NSWindow, role: BudgetWindowRole) {
        register(window, role: role)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        if role == .settings { window.title = "Настройки"; fitAuxiliaryWindow(window); return }
        guard role == .workspace else { fitAuxiliaryWindow(window); return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let available = screen?.visibleFrame else { return }
        let nativeFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: WindowLayout.workspaceSize))
        var proposed = WindowLayout.centered(size: nativeFrame.size, in: available)
        if let saved = UserDefaults.standard.array(forKey: geometryKey) as? [Double], saved.count == 4,
           saved.allSatisfy(\.isFinite), saved[2] > 0, saved[3] > 0 {
            let rect = CGRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
            let display = NSScreen.screens.max { $0.visibleFrame.intersection(rect).area < $1.visibleFrame.intersection(rect).area }
            proposed = WindowLayout.fitted(rect, in: display?.visibleFrame ?? available)
        } else {
            // Earlier versions let SwiftUI autosave the WindowGroup frame.
            // Preserve an unambiguous legacy frame even when it matches the
            // old default: there is no evidence that it was not user-chosen.
            let prefix = "NSWindow Frame "
            let legacy = UserDefaults.standard.dictionaryRepresentation().keys.filter {
                $0.hasPrefix(prefix) && $0.contains("WindowGroup") && $0.contains(".RootView")
            }
            if legacy.count == 1, let key = legacy.first,
               window.setFrameUsingName(String(key.dropFirst(prefix.count))) {
                let rect = window.frame
                let display = NSScreen.screens.max { $0.visibleFrame.intersection(rect).area < $1.visibleFrame.intersection(rect).area }
                proposed = WindowLayout.fitted(rect, in: display?.visibleFrame ?? available)
            }
        }
        let chrome = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 1000, height: 700)).size
        window.minSize = CGSize(width: min(chrome.width, proposed.width), height: min(chrome.height, proposed.height))
        window.setFrame(proposed, display: false)
    }
    static func fitAuxiliaryWindow(_ window: NSWindow) {
        guard roles[ObjectIdentifier(window)] != .workspace,
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        let fitted = WindowLayout.fitted(window.frame, in: screen.visibleFrame, margin: 0)
        // Content-sized access windows grow for recovery and larger text.
        // Keep their title and lower actions on the current screen.
        if window.frame != fitted { window.setFrame(fitted, display: true) }
    }
    static func standardSize() {
        guard let window = windows.allObjects.first(where: { roles[ObjectIdentifier($0)] == .workspace && $0.isVisible }),
              let screen = window.screen ?? NSScreen.main else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: WindowLayout.workspaceSize))
        window.setFrame(WindowLayout.centered(size: frame.size, in: screen.visibleFrame), display: true)
        save(window)
    }
    static func workspacePresented() {
        guard fullScreenAfterUnlock, let window = windows.allObjects.first(where: { roles[ObjectIdentifier($0)] == .workspace }) else { return }
        fullScreenAfterUnlock = false
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

struct BudgetWindowMarker: NSViewRepresentable {
    var role: BudgetWindowRole = .workspace
    func makeNSView(context: Context) -> NSView { Marker(role: role) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Marker: NSView {
        let role: BudgetWindowRole
        private weak var registeredWindow: NSWindow?
        private var observations: [NSObjectProtocol] = []
        init(role: BudgetWindowRole) { self.role = role; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard registeredWindow !== window else { return }
            if let registeredWindow { BudgetWindows.unregister(registeredWindow) }
            observations.forEach(NotificationCenter.default.removeObserver); observations = []
            registeredWindow = window
            guard let window else { return }
            BudgetWindows.configure(window, role: role)
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] notification in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        BudgetWindows.save(window)
                        if notification.name == NSWindow.didResizeNotification {
                            DispatchQueue.main.async { [weak window] in if let window { BudgetWindows.fitAuxiliaryWindow(window) } }
                        }
                    }
                })
            }
            observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window, !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
                    let fitted = WindowLayout.fitted(window.frame, in: screen.visibleFrame, margin: 0)
                    window.minSize = CGSize(width: min(window.minSize.width, fitted.width), height: min(window.minSize.height, fitted.height))
                    window.setFrame(fitted, display: true)
                }
            })
        }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
}
