import SwiftUI
import AppKit
import BudgetCore
import BudgetPresentation

typealias BeeFormat = DisplayFormat

enum BeeStyle {
    static func color(_ light: UInt32, _ dark: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? (dark ?? light) : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    private static func role(_ keyPath: KeyPath<AppearancePalette, AppearanceColor>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let palette = AppearanceStore.shared.preferences.palette(systemDark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let value = palette[keyPath: keyPath]
            return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
    }
    static var background: LinearGradient { LinearGradient(colors: (0...32).map { step in
        Color(nsColor: NSColor(name: nil) { appearance in
            let palette = AppearanceStore.shared.preferences.palette(systemDark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let value = palette.backgroundStart.mixed(with: palette.backgroundEnd, fraction: Double(step) / 32)
            return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
    }, startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var chrome: Color { role(\.chrome) }; static var surface: Color { role(\.surface) }
    static var text: Color { role(\.text) }; static var muted: Color { role(\.muted) }
    static var onBackground: Color { role(\.onBackground) }; static var backgroundMuted: Color { role(\.backgroundMuted) }
    static var honey: Color { role(\.accent) }; static var honeyText: Color { role(\.accentText) }
    static var selected: Color { role(\.selected) }; static var line: Color { role(\.line) }
    static var backgroundLine: Color { role(\.backgroundLine) }
    static var positive: Color { role(\.positive) }; static var warning: Color { role(\.warning) }
    static var negative: Color { role(\.negative) }; static var expense: Color { role(\.expense) }
    static var controlAccent: Color { role(\.controlAccent) }
}

struct BeePrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        BeePrimaryBody(label: configuration.label, pressed: configuration.isPressed, enabled: enabled)
    }
}

private struct BeePrimaryBody<Label: View>: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var label: Label; var pressed: Bool; var enabled: Bool
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        label.beeFont(.headline).padding(.horizontal, 14).padding(.vertical, 9).frame(minWidth: 28, minHeight: 28)
            .foregroundStyle(BeeStyle.honeyText).background(BeeStyle.honey, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(BeeStyle.honeyText, lineWidth: 1) }
            .overlay { RoundedRectangle(cornerRadius: 9).fill(BeeStyle.honeyText.opacity(pressed ? 0.16 : hover && enabled ? 0.07 : 0)).allowsHitTesting(false) }
            .opacity(enabled ? 1 : 0.55).onHover { hover = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hover)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
    }
}

struct BeeRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { BeeRowBody(label: configuration.label, pressed: configuration.isPressed) }
}
private struct BeeRowBody<Label: View>: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var label: Label; var pressed: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        label.frame(minWidth: 28, minHeight: 28).contentShape(RoundedRectangle(cornerRadius: 8))
            .background(Color.primary.opacity(enabled && (hover || pressed) ? (pressed ? 0.16 : 0.08) : 0), in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.55).onHover { hover = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hover)
    }
}

struct BeeSurface: ViewModifier {
    var padding: CGFloat = 20
    @Environment(\.beeAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.padding(padding).foregroundStyle(BeeStyle.text).tint(BeeStyle.controlAccent)
            .background { RoundedRectangle(cornerRadius: 14).fill(BeeStyle.surface)
                .shadow(color: .black.opacity(0.13), radius: 12, x: 0, y: 5)
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1) }
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(BeeStyle.line, lineWidth: contrast == .increased ? 2 : 1).allowsHitTesting(false) }
    }
}
extension View {
    func beeCard(padding: CGFloat = 20) -> some View { modifier(BeeSurface(padding: padding)) }
    func beeWindow() -> some View { modifier(BeeWindowModifier()) }
}

private struct BeeWindowModifier: ViewModifier {
    @ObservedObject private var store = AppearanceStore.shared
    func body(content: Content) -> some View {
        content.foregroundStyle(BeeStyle.onBackground).background(BeeStyle.background)
            .tint(BeeStyle.honey).buttonStyle(BeeRowStyle()).beeAppearance()
    }
}

struct FormField<Content: View>: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).beeFont(.subheadline.weight(.medium)); content()
            if let hint { Text(hint).beeFont(.caption).foregroundStyle(BeeStyle.muted) }
        }
    }
}

struct SectionHeading<Actions: View>: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { Text(title).beeFont(.system(size: 28, weight: .semibold)).fixedSize(); Spacer(); actions().fixedSize() }
            VStack(alignment: .leading, spacing: 14) { Text(title).beeFont(.system(size: 28, weight: .semibold)); WrappingLayout(spacing: 10) { actions() } }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct PartialValue: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var value: Valuation
    var currency: String
    var large = false
    var onMissingOperations: (([UUID]) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BeeFormat.money(value.known, currency: currency)).beeFont(large ? .system(size: 32, weight: .semibold) : .title3.weight(.medium)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            if value.partial { PartialStatus(value: value, onMissingOperations: onMissingOperations) }
        }.foregroundStyle(value.known < 0 ? BeeStyle.negative : BeeStyle.text)
    }
}

struct WrappingLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { arrangement(proposal.width ?? 600, subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(bounds.width, subviews)
        for (index, point) in result.points.enumerated() { subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil)) }
    }
    private func arrangement(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, used: CGFloat = 0; var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); rowHeight = max(rowHeight, size.height); used = max(used, x + size.width); x += size.width + spacing
        }
        return (CGSize(width: used, height: y + rowHeight), points)
    }
}

struct PartialStatus: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var value: Valuation
    var onMissingOperations: (([UUID]) -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @State private var details = false
    var body: some View {
        Button { details = true } label: { Label("Частично · " + value.partialDescription, systemImage: "exclamationmark.triangle") }.buttonStyle(BeeRowStyle()).beeFont(.caption).foregroundStyle(BeeStyle.warning)
            .popover(isPresented: $details) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Неполный итог").beeFont(.headline)
                    if !value.missing.isEmpty { Text("Без курса: \(value.missing.count). Валюты: \(value.currencies.sorted().joined(separator: ", ")).") }
                    if !value.missingConditions.isEmpty { Text("Есть неизвестные условия, налог или состав долга. Уточните договоры и банковские суммы."); Button("Открыть финансовый календарь") { details = false; model.section = .financialCalendar } }
                    let missing = Set(value.missing); let operations = model.db?.operations.filter { missing.contains($0.id) } ?? []
                    if !operations.isEmpty {
                        Text("Для пересчёта нужен снимок курса в самой операции.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                        Button("Открыть операции без курса") { details = false; let ids = operations.map(\.id); if let onMissingOperations { onMissingOperations(ids) } else { model.showOperations(ids, title: "Операции без курса") } }
                    }
                    if !value.missing.isEmpty { SettingsLink { Text(operations.isEmpty ? "Добавить справочный курс" : "Открыть курсы и инструкции") }.simultaneousGesture(TapGesture().onEnded { details = false; model.settingsTask = .rates }) }
                    Button("Закрыть") { details = false }.keyboardShortcut(.cancelAction)
                }.padding(20).frame(width: 330).foregroundStyle(BeeStyle.text).background(BeeStyle.surface)
            }
    }
}
