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
    static let background = LinearGradient(colors: [color(0x0B7076), color(0x03525A), color(0x013E46)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let chrome = color(0x03434C), surface = color(0xFFF8E9, 0x0B4E57)
    static let text = color(0x173F42, 0xF5EDDA), muted = color(0x506963, 0xB8D5CC)
    static let onBackground = color(0xF5EDDA), backgroundMuted = color(0xD5E7DD)
    static let honey = color(0xF7C756), honeyText = color(0x173F42)
    static let selected = color(0xE4EADC, 0x24616A), line = color(0x739186, 0x779B94)
    static let positive = color(0x23675D, 0x96D8B9), warning = color(0x77510B, 0xF7D78D)
    static let negative = color(0xA23E31, 0xFFB8A6), expense = color(0xA97216, 0xF7C756)
}

struct BeePrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(BeeStyle.honeyText).background(BeeStyle.honey, in: RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct BeeSurface: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View { content.padding(padding).foregroundStyle(BeeStyle.text).background(BeeStyle.surface, in: RoundedRectangle(cornerRadius: 14)) }
}
extension View {
    func beeCard(padding: CGFloat = 20) -> some View { modifier(BeeSurface(padding: padding)) }
    func beeWindow() -> some View { foregroundStyle(BeeStyle.onBackground).background(BeeStyle.background).tint(BeeStyle.honey) }
}

struct FormField<Content: View>: View {
    var title: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.medium)); content()
            if let hint { Text(hint).font(.caption).foregroundStyle(BeeStyle.muted) }
        }
    }
}

struct SectionHeading<Actions: View>: View {
    var title: String
    @ViewBuilder var actions: () -> Actions
    var body: some View { HStack(alignment: .center, spacing: 16) { Text(title).font(.system(size: 28, weight: .semibold)); Spacer(); actions() } }
}

struct PartialValue: View {
    var value: Valuation
    var currency: String
    var large = false
    var onMissingOperations: (([UUID]) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BeeFormat.money(value.known, currency: currency)).font(large ? .system(size: 32, weight: .semibold) : .title3.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
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
    var value: Valuation
    var onMissingOperations: (([UUID]) -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @State private var details = false
    var body: some View {
        Button { details = true } label: { Label("Частично · " + value.partialDescription, systemImage: "exclamationmark.triangle") }.buttonStyle(.plain).font(.caption).foregroundStyle(BeeStyle.warning)
            .popover(isPresented: $details) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Неполный итог").font(.headline)
                    if !value.missing.isEmpty { Text("Без курса: \(value.missing.count). Валюты: \(value.currencies.sorted().joined(separator: ", ")).") }
                    if !value.missingConditions.isEmpty { Text("Есть неизвестные условия, налог или состав долга. Уточните договоры и банковские суммы."); Button("Открыть финансовый календарь") { details = false; model.section = .financialCalendar } }
                    let missing = Set(value.missing); let operations = model.db?.operations.filter { missing.contains($0.id) } ?? []
                    if !operations.isEmpty {
                        Text("Для пересчёта нужен снимок курса в самой операции.").font(.caption).foregroundStyle(BeeStyle.muted)
                        Button("Открыть операции без курса") { details = false; let ids = operations.map(\.id); if let onMissingOperations { onMissingOperations(ids) } else { model.showOperations(ids, title: "Операции без курса") } }
                    }
                    if !value.missing.isEmpty { SettingsLink { Text(operations.isEmpty ? "Добавить справочный курс" : "Открыть курсы и инструкции") }.simultaneousGesture(TapGesture().onEnded { details = false; model.settingsTask = .rates }) }
                    Button("Закрыть") { details = false }.keyboardShortcut(.cancelAction)
                }.padding(20).frame(width: 330).foregroundStyle(BeeStyle.text).background(BeeStyle.surface)
            }
    }
}
