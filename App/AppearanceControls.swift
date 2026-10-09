import SwiftUI
import AppKit
import BudgetPresentation

enum BeePickerPresentation { case menu, segmented }

/// A single native Clear glass surface for the account tabs.
struct BeeSegments: View {
    var title: String
    var labels: [String]
    @Binding var selection: Int
    @Environment(\.beeAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Int?
    @Namespace private var indicator
    var body: some View {
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { index in
                Button { selection = index; focused = index } label: {
                    Text(labels[index]).beeFont(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 38 * appearance.scale)
                        .contentShape(.capsule)
                        .background {
                            if selection == index {
                                Capsule().fill(selectionTint.opacity(colorScheme == .dark ? 0.14 : 0.22))
                                    .overlay { Capsule().strokeBorder(selectionTint.opacity(colorScheme == .dark ? 0.16 : 0.20), lineWidth: 1) }
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                }.buttonStyle(.plain).foregroundStyle(BeeStyle.onBackground)
                    .focusable().focused($focused, equals: index)
                    .focusEffectDisabled()
                    .overlay {
                        if focused == index {
                            Capsule().strokeBorder(BeeStyle.onBackground.opacity(0.65), lineWidth: 2).allowsHitTesting(false)
                        }
                    }
                    .accessibilityAddTraits(selection == index ? .isSelected : [])
                    .onKeyPress(keys: [.leftArrow, .rightArrow]) { event in
                        let next = min(max(selection + (event.key == .rightArrow ? 1 : -1), 0), labels.count - 1)
                        selection = next; focused = next
                        return .handled
                    }
            }
        }.padding(4)
            .glassEffect(.clear.interactive(), in: .capsule)
            .accessibilityElement(children: .contain).accessibilityLabel(title)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
    }
    private var selectionTint: Color { colorScheme == .dark ? .white : BeeStyle.honey }
}

/// Keep the native editor, caret, validation and focus ring.
struct BeeTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration.textFieldStyle(.roundedBorder).controlSize(.large)
    }
}

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
        // A system popover avoids macOS popup/segment labels' fixed small font.
        // The controls, focus, material and pointer feedback remain native.
        Group(subviews: options) { children in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if !hiddenLabel { Text(title).beeFont(.body) }
                Button { open = true } label: {
                    HStack(spacing: 10) {
                        if let chosen = children.first(where: { $0.containerValues.hasTag(selection) }) {
                            chosen.beeFont(.body).fixedSize(horizontal: false, vertical: true)
                        } else { Text("Выберите").beeFont(.body) }
                        Image(systemName: "chevron.up.chevron.down").beeFont(.caption).accessibilityHidden(true)
                    }
                }.buttonStyle(BeeControlStyle()).accessibilityHint("Выбрать: " + title)
                    .popover(isPresented: $open) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(title).beeFont(.headline)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(children) { child in
                                        if let tag = child.containerValues.tag(for: Selection.self) {
                                            Button { selection = tag; open = false } label: {
                                                HStack(spacing: 12) {
                                                    child.beeFont(.body).fixedSize(horizontal: false, vertical: true)
                                                    Spacer(minLength: 8)
                                                    Image(systemName: "checkmark").opacity(child.containerValues.hasTag(selection) ? 1 : 0).accessibilityHidden(true)
                                                }.padding(.vertical, 8).padding(.horizontal, 10).contentShape(.rect)
                                            }.buttonStyle(.borderless)
                                                .accessibilityAddTraits(child.containerValues.hasTag(selection) ? .isSelected : [])
                                        }
                                    }
                                }
                            }.frame(maxHeight: 330)
                            Button("Закрыть") { open = false }.keyboardShortcut(.cancelAction)
                        }.padding(18).frame(width: 360 * pow(appearanceStore.preferences.scale, 0.5))
                            .foregroundStyle(.primary).beeAppearance()
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
