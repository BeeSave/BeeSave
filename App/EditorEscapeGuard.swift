import SwiftUI
import AppKit

/// macOS can dismiss a SwiftUI sheet on Escape before its cancel button runs.
/// Consume only Escape in this editor's window and invoke the same close guard.
struct EditorEscapeGuard: NSViewRepresentable {
    var onEscape: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.onEscape = onEscape
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, event.keyCode == 53,
                  let window = coordinator.view?.window, event.window === window,
                  NSApp.keyWindow === window, window.attachedSheet == nil else { return event }
            coordinator.onEscape?()
            return nil
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onEscape = onEscape }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil; coordinator.onEscape = nil
    }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var onEscape: (() -> Void)?
    }
}
