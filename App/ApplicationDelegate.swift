import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var updater: InstallUpdateManager?
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updater?.canTerminate() == false ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.vault.close() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the bundled icon directly so Dock does not retain a cached placeholder.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url), icon.isValid else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
