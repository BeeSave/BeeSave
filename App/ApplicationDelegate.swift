import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the bundled icon directly so Dock does not retain a cached placeholder.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url), icon.isValid else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
