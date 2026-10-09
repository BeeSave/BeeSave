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

/// Delegate artwork, keyboard focus and pointer feedback to macOS.
struct BeeControlStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label.beeFont(.body) }
            .buttonStyle(.bordered).controlSize(.large).tint(BeeStyle.controlAccent)
    }
}

struct BeePrimaryStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label.beeFont(.subheadline.weight(.semibold)) }
            .buttonStyle(.glassProminent).controlSize(.large).tint(BeeStyle.honey)
    }
}

struct BeeRowStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label.frame(minWidth: 28, minHeight: 28) }
            .buttonStyle(.borderless)
    }
}

/// Native lists inherit the user's macOS selection accent, independently of
/// SwiftUI's tint. Native buttons let navigation use the app's chosen palette
/// consistently, while retaining system focus, hover and glass rendering.
struct BeeSidebar<Item: Hashable, Row: View>: View {
    var items: [Item]
    @Binding var selection: Item
    var name: String
    var enabled: (Item) -> Bool = { _ in true }
    @ViewBuilder var row: (Item) -> Row
    @Environment(\.beeAppearance) private var appearance
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var navigationFocused: Bool
    var body: some View {
        ScrollView {
          VStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { select(item) } label: {
                    row(item)
                        .frame(maxWidth: .infinity, minHeight: 30 * appearance.scale, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(selection == item && controlActiveState != .inactive ? BeeStyle.honeyText : BeeStyle.onBackground)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(BeeSidebarButtonStyle(selected: selection == item))
                .disabled(!enabled(item))
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
          }.padding(.horizontal, 10).padding(.top, 28)
        }
            .background(BeeStyle.background)
            .accessibilityLabel(name)
            .focusable()
            .focused($navigationFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { event in
                let available = items.filter(enabled)
                guard !available.isEmpty else { return .ignored }
                let current = available.firstIndex(of: selection) ?? 0
                let next = min(max(current + (event.key == .downArrow ? 1 : -1), 0), available.count - 1)
                select(available[next])
                return .handled
            }
    }
    private func select(_ item: Item) {
        selection = item
        // Keep keyboard focus on the stable navigation container when the
        // selected native button changes style and replaces its render tree.
        DispatchQueue.main.async { navigationFocused = true }
    }
}

private struct BeeSidebarButtonStyle: PrimitiveButtonStyle {
    var selected: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if selected {
            Button(action: configuration.trigger) { configuration.label }
                .buttonStyle(.glassProminent).controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: 12)).tint(BeeStyle.honey)
        } else {
            Button(action: configuration.trigger) { configuration.label.padding(.horizontal, 16) }
                .buttonStyle(.borderless).controlSize(.large)
        }
    }
}

struct BeeSurface: ViewModifier {
    var padding: CGFloat = 20
    @Environment(\.beeAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.padding(padding).foregroundStyle(BeeStyle.text)
            .background(BeeStyle.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(BeeStyle.line.opacity(contrast == .increased ? 1 : 0.18), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
extension View {
    func beeCard(padding: CGFloat = 20) -> some View { modifier(BeeSurface(padding: padding)) }
    func beeWindow() -> some View { modifier(BeeWindowModifier()) }
    /// Extend the same content palette beneath the native glass sidebar.
    /// Apply once, to the detail column of a navigation split view.
    func beeNavigationContent() -> some View {
        foregroundStyle(BeeStyle.onBackground)
            .background { BeeStyle.background.backgroundExtensionEffect() }
            .beeAppearance()
    }
    @ViewBuilder func beeWhen<Transformed: View>(_ condition: Bool, transform: (Self) -> Transformed) -> some View {
        if condition { transform(self) } else { self }
    }
}

private struct BeeWindowModifier: ViewModifier {
    @ObservedObject private var store = AppearanceStore.shared
    func body(content: Content) -> some View {
        content.foregroundStyle(BeeStyle.onBackground).background(BeeStyle.background)
            .beeAppearance()
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

private struct BeeToolbarActionsKey: EnvironmentKey { static let defaultValue = false }
private struct BeeSectionActionsKey: FocusedValueKey { typealias Value = AnyView }
#if DEBUG && UI_SMOKE
private struct BeeQAActionsKey: FocusedValueKey { typealias Value = AnyView }
#endif
extension FocusedValues {
    var beeSectionActions: AnyView? {
        get { self[BeeSectionActionsKey.self] }
        set { self[BeeSectionActionsKey.self] = newValue }
    }
    #if DEBUG && UI_SMOKE
    var beeQAActions: AnyView? {
        get { self[BeeQAActionsKey.self] }
        set { self[BeeQAActionsKey.self] = newValue }
    }
    #endif
}
struct BeeSectionCommands: Commands {
    @FocusedValue(\.beeSectionActions) private var actions
    #if DEBUG && UI_SMOKE
    @FocusedValue(\.beeQAActions) private var qaActions
    #endif
    var body: some Commands {
        CommandMenu("Раздел") { if let actions { actions } }
        #if DEBUG && UI_SMOKE
        CommandMenu("QA") { if let qaActions { qaActions } }
        #endif
    }
}
extension EnvironmentValues {
    var beeToolbarActions: Bool {
        get { self[BeeToolbarActionsKey.self] }
        set { self[BeeToolbarActionsKey.self] = newValue }
    }
}

struct SectionHeading<Actions: View>: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    @ViewBuilder var actions: () -> Actions
    @Environment(\.beeToolbarActions) private var toolbarActions
    @ViewBuilder var body: some View {
        if toolbarActions {
            Color.clear.frame(height: 0).accessibilityHidden(true)
                .navigationTitle(title)
                .toolbar { ToolbarItemGroup(placement: .primaryAction) { actions() } }
                .focusedSceneValue(\.beeSectionActions, AnyView(actions()))
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { Text(title).beeFont(.title2.weight(.semibold)); Spacer(); actions() }
                VStack(alignment: .leading, spacing: 12) { Text(title).beeFont(.title2.weight(.semibold)); WrappingLayout(spacing: 10) { actions() } }
            }
        }
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
                    if !value.missingConditions.isEmpty { Text("Есть неизвестные условия, налог или состав долга. Уточните договоры и банковские суммы."); Button("Открыть календарь") { details = false; model.section = .financialCalendar } }
                    let missing = Set(value.missing); let operations = model.db?.operations.filter { missing.contains($0.id) } ?? []
                    if !operations.isEmpty {
                        Text("Для пересчёта нужен снимок курса в самой операции.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                        Button("Открыть операции без курса") { details = false; let ids = operations.map(\.id); if let onMissingOperations { onMissingOperations(ids) } else { model.showOperations(ids, title: "Операции без курса") } }
                    }
                    if !value.missing.isEmpty { SettingsLink { Text(operations.isEmpty ? "Добавить справочный курс" : "Открыть курсы и инструкции") }.simultaneousGesture(TapGesture().onEnded { details = false; model.settingsTask = .rates }) }
                    Button("Закрыть") { details = false }.keyboardShortcut(.cancelAction)
                }.padding(20).frame(width: 330).foregroundStyle(.primary)
            }
    }
}
