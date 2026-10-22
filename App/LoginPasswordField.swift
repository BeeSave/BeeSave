import AppKit
import Carbon
import SwiftUI

/// Lives for one presentation of LoginView, including recovery and failed attempts.
@MainActor final class LoginInputSelection {
    private var attempted = false
    private let select: @MainActor () -> Void
    init(select: @escaping @MainActor () -> Void = { LoginInputSelection.selectEnglish() }) { self.select = select }
    func begin() {
        guard !attempted else { return }
        attempted = true
        select()
    }

    static func isEnglish(_ languages: [String]) -> Bool {
        languages.first?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased() == "en"
    }
    static func preferredEnglishIndex(current: [String], enabled: [[String]]) -> Int? {
        guard !isEnglish(current) else { return nil }
        return enabled.firstIndex(where: isEnglish)
    }
    static func selectEnglish() {
        func languages(_ source: TISInputSource) -> [String] {
            guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
            return Unmanaged<CFArray>.fromOpaque(property).takeUnretainedValue() as? [String] ?? []
        }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        guard !isEnglish(languages(current)) else { return }
        let filter: [String: Any] = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                                    kTISPropertyInputSourceIsEnabled as String: true,
                                    kTISPropertyInputSourceIsSelectCapable as String: true]
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let index = preferredEnglishIndex(current: languages(current), enabled: sources.map(languages)) else { return }
        TISSelectInputSource(sources[index])
    }
}

struct LoginPasswordField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    @Binding var focused: Bool
    let selection: LoginInputSelection
    var scale: CGFloat
    var submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> PasswordField {
        let field = PasswordField()
        field.selection = selection
        field.placeholderString = "Введите пароль"
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.setAccessibilityIdentifier("access.password")
        field.setAccessibilityLabel("Пароль бюджета")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: PasswordField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        // AppKit can reset the secure editor's selection when its attributes are set.
        // Binding changes must leave an already configured editor alone.
        let font = NSFont.systemFont(ofSize: 15 * scale)
        if field.font != font { field.font = font }
        let color = NSColor(BeeStyle.text)
        if field.textColor != color { field.textColor = color }
        if field.isEnabled != isEnabled { field.isEnabled = isEnabled }
        field.wantsFocus = focused
        if focused && !context.coordinator.requestedFocus {
            field.focusWhenAttached()
        }
        context.coordinator.requestedFocus = focused
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PasswordField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: max(32, nsView.intrinsicContentSize.height))
    }
    static func dismantleNSView(_ field: PasswordField, coordinator: Coordinator) {
        field.wantsFocus = false
        field.currentEditor()?.string = ""
        field.stringValue = ""
        field.delegate = nil
        field.target = nil
        field.selection = nil
    }
    final class PasswordField: NSSecureTextField {
        var selection: LoginInputSelection?
        var wantsFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenAttached()
        }
        func focusWhenAttached() {
            guard wantsFocus, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsFocus, self.isEnabled, self.currentEditor() == nil else { return }
                self.window?.makeFirstResponder(self)
            }
        }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                // Leave all enabled input sources available after the initial selection.
                currentEditor()?.inputContext?.allowedInputSourceLocales = nil
                selection?.begin()
            }
            return accepted
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LoginPasswordField
        var requestedFocus = false
        init(_ parent: LoginPasswordField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSecureTextField { parent.text = field.stringValue }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        @objc func submit() { parent.submit() }
    }
}
