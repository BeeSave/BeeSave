import SwiftUI
import AppKit
import BudgetPresentation

struct NoticeWindowAnchor: NSViewRepresentable {
    @Binding var active: Bool
    var register: (NSWindow) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor(active: $active, register: register) }
    func updateNSView(_ view: Anchor, context: Context) { view.active = $active; view.refresh() }
    final class Anchor: NSView {
        var active: Binding<Bool>
        let register: (NSWindow) -> Void
        private var observations: [NSObjectProtocol] = []
        init(active: Binding<Bool>, register: @escaping (NSWindow) -> Void) { self.active = active; self.register = register; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { register(window) }
            observations.forEach(NotificationCenter.default.removeObserver); observations = []
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            refresh()
        }
        func refresh() {
            let next = window?.isKeyWindow == true && NSApp.isActive
            guard active.wrappedValue != next else { return }
            DispatchQueue.main.async { [weak self] in self?.active.wrappedValue = next }
        }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
}

private struct BeeNoticeModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false
    func body(content: Content) -> some View {
        content.background(NoticeWindowAnchor(active: $active, register: model.registerNoticeWindow))
            .overlay(alignment: .top) {
                if active, let notice = model.noticeMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: notice.kind == .warning ? "exclamationmark.triangle" : notice.kind == .success ? "checkmark.circle" : "info.circle")
                            .foregroundStyle(notice.kind == .warning ? Color.orange : Color.primary).accessibilityHidden(true)
                        Text(notice.text).beeFont(.subheadline).fixedSize(horizontal: false, vertical: true)
                        if !notice.transient {
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).accessibilityLabel("Закрыть сообщение")
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 14)
                        .frame(maxWidth: 480, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .padding(16).accessibilityElement(children: .combine)
                        .accessibilityIdentifier("notice.floating")
                        .transition(.opacity).id(notice.id)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.noticeMessage?.id)
    }
}

extension View { func beeNotices() -> some View { modifier(BeeNoticeModifier()) } }
