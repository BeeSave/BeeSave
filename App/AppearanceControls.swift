import SwiftUI
import AppKit
import BudgetPresentation

enum BeePickerPresentation { case menu, segmented }

/// Keeps native editing, validation and existing FocusState bindings. The
/// visible focus outline uses the palette rather than the system accent.
struct BeeTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        BeeStyledTextField(field: configuration)
    }
}

private struct BeeStyledTextField<Label: View>: View {
    var field: TextField<Label>
    @Environment(\.beeAppearance) private var appearance
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = appearance.palette(systemDark: scheme == .dark)
        field.textFieldStyle(.plain).foregroundStyle(BeeStyle.text)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(BeeStyle.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(BeeStyle.line, lineWidth: 1).allowsHitTesting(false) }
            .overlay { BeeNativeFocusOutline(color: palette.controlAccent).allowsHitTesting(false) }
    }
}

private struct BeeNativeFocusOutline: NSViewRepresentable {
    var color: AppearanceColor
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ view: FocusView, context: Context) {
        view.outline = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        view.refreshFocus(); view.needsDisplay = true
    }
    final class FocusView: NSView {
        var outline = NSColor.labelColor
        private var focused = false
        private var observer: NSObjectProtocol?
        override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshFocus() }
                }
            }
            refreshFocus()
        }
        override func layout() { super.layout(); refreshFocus() }
        func refreshFocus() {
            let editor = window?.firstResponder as? NSTextView
            let control = editor?.delegate as? NSTextField ?? window?.firstResponder as? NSTextField
            let ownRect = convert(bounds, to: nil)
            let fieldRect = control.map { $0.convert($0.bounds, to: nil) } ?? .zero
            let next = window?.isKeyWindow == true && !ownRect.isEmpty && fieldRect.contains(NSPoint(x: ownRect.midX, y: ownRect.midY))
            if next { control?.focusRingType = .none; editor?.insertionPointColor = outline }
            if focused != next { focused = next; needsDisplay = true }
        }
        override func draw(_ dirtyRect: NSRect) {
            guard focused else { return }
            outline.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25), xRadius: 5, yRadius: 5)
            path.lineWidth = 2.5; path.stroke()
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Public subview tags retain the existing typed selections, including nil.
/// A SwiftUI label and popover avoid macOS popup controls' fixed small font.
struct BeePicker<Selection: Hashable, Options: View>: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    @Binding var selection: Selection
    var options: Options
    var hiddenLabel = false
    var presentation = BeePickerPresentation.menu
    @State private var open = false
    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Options) {
        self.title = title; _selection = selection; options = content()
    }
    func labelsHidden() -> Self { var result = self; result.hiddenLabel = true; return result }
    func beePickerStyle(_ value: BeePickerPresentation) -> Self { var result = self; result.presentation = value; return result }
    var body: some View {
        Group(subviews: options) { children in
            if presentation == .segmented {
                WrappingLayout(spacing: 6) {
                    ForEach(children) { child in
                        if let tag = child.containerValues.tag(for: Selection.self) {
                            Button { selection = tag } label: {
                                child.beeFont(.body).padding(.horizontal, 12).padding(.vertical, 8)
                                    .foregroundStyle(child.containerValues.hasTag(selection) ? BeeStyle.honeyText : BeeStyle.text)
                                    .background(child.containerValues.hasTag(selection) ? BeeStyle.honey : BeeStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(BeeStyle.line) }
                            }.buttonStyle(BeeRowStyle()).accessibilityAddTraits(child.containerValues.hasTag(selection) ? .isSelected : [])
                        }
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel(title)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if !hiddenLabel { Text(title).beeFont(.body) }
                    Button { open = true } label: {
                        HStack(spacing: 10) {
                            if let chosen = children.first(where: { $0.containerValues.hasTag(selection) }) { chosen.beeFont(.body).fixedSize(horizontal: false, vertical: true) }
                            else { Text("Выберите").beeFont(.body) }
                            Image(systemName: "chevron.up.chevron.down").beeFont(.caption).accessibilityHidden(true)
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                            .foregroundStyle(BeeStyle.text).background(BeeStyle.selected, in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(BeeStyle.line) }
                    }.buttonStyle(BeeRowStyle()).accessibilityHint("Выбрать: " + title)
                        .popover(isPresented: $open) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(title).beeFont(.headline)
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ForEach(children) { child in
                                            if let tag = child.containerValues.tag(for: Selection.self) {
                                                Button { selection = tag; open = false } label: {
                                                    HStack(spacing: 12) { child.beeFont(.body).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 8)
                                                        if child.containerValues.hasTag(selection) { Image(systemName: "checkmark").accessibilityHidden(true) }
                                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(child.containerValues.hasTag(selection) ? BeeStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                                                }.buttonStyle(BeeRowStyle()).accessibilityAddTraits(child.containerValues.hasTag(selection) ? .isSelected : [])
                                            }
                                        }
                                    }
                                }.frame(maxHeight: 330)
                                Button("Закрыть") { open = false }.keyboardShortcut(.cancelAction)
                            }.padding(18).frame(width: 380).foregroundStyle(BeeStyle.text).background(BeeStyle.surface).beeAppearance()
                        }
                }
            }
        }
    }
}

struct BeeDatePicker: NSViewRepresentable {
    var title: String
    @Binding var selection: Date
    var displayedComponents: DatePickerComponents
    @Environment(\.beeAppearance) private var appearance
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, selection: Binding<Date>, displayedComponents: DatePickerComponents) { self.title = title; _selection = selection; self.displayedComponents = displayedComponents }
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = .yearMonthDay
        picker.target = context.coordinator; picker.action = #selector(Coordinator.changed(_:))
        picker.isBordered = true; picker.isBezeled = true
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.selection = $selection
        picker.locale = locale; picker.font = .systemFont(ofSize: 15 * appearance.scale)
        picker.isEnabled = enabled
        if picker.dateValue != selection { picker.dateValue = selection }
        picker.setAccessibilityLabel(title); picker.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSDatePicker, context: Context) -> CGSize? { nsView.fittingSize }
    final class Coordinator: NSObject {
        var selection: Binding<Date>
        init(selection: Binding<Date>) { self.selection = selection }
        @objc func changed(_ sender: NSDatePicker) { selection.wrappedValue = sender.dateValue }
    }
}


struct BeeColorWell: NSViewRepresentable {
    var title: String
    @Binding var selection: Color
    @Environment(\.beeAppearance) private var appearance
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(frame: .zero)
        well.colorWellStyle = .default
        well.supportsAlpha = false
        well.maximumLinearExposure = 1
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        return well
    }
    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.selection = $selection
        let color = NSColor(selection)
        if well.color != color { well.color = color }
        well.isEnabled = enabled
        well.setAccessibilityLabel(title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSColorWell, context: Context) -> CGSize? {
        CGSize(width: 44 * appearance.scale, height: 28 * appearance.scale)
    }
    static func dismantleNSView(_ well: NSColorWell, coordinator: Coordinator) { well.deactivate() }
    final class Coordinator: NSObject {
        var selection: Binding<Color>
        init(selection: Binding<Color>) { self.selection = selection }
        @objc func changed(_ sender: NSColorWell) { selection.wrappedValue = Color(nsColor: sender.color) }
    }
}
