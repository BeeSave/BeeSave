import AppKit
import SwiftUI

@MainActor enum BudgetWindows {
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) { windows.add(window) }
    static func unregister(_ window: NSWindow) { windows.remove(window) }

    static func preferred(ordered: [NSWindow], key: NSWindow?) -> NSWindow? {
        if let key, windows.contains(key) { return key }
        if let parent = key?.sheetParent, windows.contains(parent) { return parent }
        return ordered.first { windows.contains($0) }
    }

    static func bringForward() {
        guard let window = preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.attachedSheet?.makeKeyAndOrderFront(nil)
    }
}

struct BudgetWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Marker: NSView {
        private weak var registeredWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let registeredWindow { BudgetWindows.unregister(registeredWindow) }
            registeredWindow = window
            if let window { BudgetWindows.register(window) }
        }
    }
}
