import SwiftUI
import BudgetPresentation

struct AppearanceSettingsView: View {
    @ObservedObject private var store = AppearanceStore.shared
    @State private var editing = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Размер текста", systemImage: "textformat.size").beeFont(.headline)
                BeePicker("Размер текста", selection: Binding(get: { store.preferences.textPercent }, set: { percent in store.update { $0.textPercent = percent } })) {
                    ForEach(AppearancePreferences.scales, id: \.self) { Text("\($0)%").tag($0) }
                }.beePickerStyle(.menu).beeFont(.body).accessibilityIdentifier("appearance.textScale")
                Text("Меню, суммы, таблицы и формы увеличиваются вместе. Изменения видны сразу.")
                    .beeFont(.caption).foregroundStyle(BeeStyle.muted)
                Text("Так будет выглядеть ваш бюджет").beeFont(.body)
            }.frame(maxWidth: .infinity, alignment: .leading).beeCard()
            VStack(alignment: .leading, spacing: 14) {
                Label("Цветовая тема", systemImage: "paintpalette").beeFont(.headline)
                ForEach(AppearanceTheme.allCases) { theme in
                    let palette = theme == .custom ? store.preferences.custom : .preset(theme, systemDark: colorScheme == .dark)
                    Button { store.update { $0.theme = theme } } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: -5) {
                                ForEach([palette.backgroundStart, palette.surface, palette.accent].indices, id: \.self) { index in
                                    Circle().fill([palette.backgroundStart, palette.surface, palette.accent][index].swiftUIColor)
                                        .frame(width: 24, height: 24).overlay(Circle().strokeBorder(BeeStyle.line, lineWidth: 1))
                                }
                            }.accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(theme.title).beeFont(.headline)
                                Text(theme.detail).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: store.preferences.theme == theme ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(BeeStyle.text).accessibilityHidden(true)
                        }.padding(12).background(store.preferences.theme == theme ? BeeStyle.selected : BeeStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(BeeStyle.line, lineWidth: store.preferences.theme == theme ? 2 : 1) }
                    }.buttonStyle(BeeRowStyle()).accessibilityLabel(theme.title + ". " + theme.detail)
                        .accessibilityAddTraits(store.preferences.theme == theme ? .isSelected : [])
                        .accessibilityIdentifier("appearance.theme." + theme.rawValue)
                }
                Button("Настроить свою палитру…", systemImage: "slider.horizontal.3") { editing = true }
                    .accessibilityIdentifier("appearance.editCustom")
            }.frame(maxWidth: .infinity, alignment: .leading).beeCard()
            Text("Оформление сохраняется на этом Mac и действует во всех окнах, включая экран входа. В финансовую резервную копию оно не входит.")
                .beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted)
            Button("Сбросить оформление", systemImage: "arrow.counterclockwise") { store.reset() }
                .accessibilityIdentifier("appearance.reset")
        }.sheet(isPresented: $editing) { AppearancePaletteEditor(initial: store.preferences.custom) }
    }
}

extension AppearanceColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

private enum PaletteField: String, CaseIterable, Identifiable {
    case backgroundStart = "Фон · начало", backgroundEnd = "Фон · конец", chrome = "Основа под навигацией", surface = "Карточки"
    case text = "Основной текст", muted = "Вторичный текст", accent = "Акцент", accentText = "Текст на акценте"
    case onBackground = "Текст на фоне содержимого", backgroundMuted = "Подписи на фоне содержимого"
    var id: String { rawValue }
    var path: WritableKeyPath<AppearancePalette, AppearanceColor> {
        switch self {
        case .backgroundStart: \.backgroundStart; case .backgroundEnd: \.backgroundEnd
        case .chrome: \.chrome; case .surface: \.surface; case .text: \.text; case .muted: \.muted
        case .accent: \.accent; case .accentText: \.accentText; case .onBackground: \.onBackground; case .backgroundMuted: \.backgroundMuted
        }
    }
}

struct AppearancePaletteEditor: View {
    let initial: AppearancePalette
    @ObservedObject private var store = AppearanceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var raw: [PaletteField: String]
    @State private var dark: Bool
    @State private var closing = false
    init(initial: AppearancePalette) {
        self.initial = initial
        _raw = State(initialValue: Dictionary(uniqueKeysWithValues: PaletteField.allCases.map { ($0, initial[keyPath: $0.path].hexString) }))
        _dark = State(initialValue: initial.dark)
    }
    private var candidate: AppearancePalette {
        var palette = initial; palette.dark = dark
        for field in PaletteField.allCases { if let color = AppearanceColor(hexString: raw[field] ?? "") { palette[keyPath: field.path] = color } }
        return palette
    }
    private var issues: [String] {
        let invalid = PaletteField.allCases.filter { AppearanceColor(hexString: raw[$0] ?? "") == nil }.map { $0.rawValue + ": введите цвет #RRGGBB" }
        return invalid + candidate.validationIssues
    }
    private var dirty: Bool { dark != initial.dark || PaletteField.allCases.contains { raw[$0] != initial[keyPath: $0.path].hexString } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Своя палитра").beeFont(.title2.bold()); Spacer() }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Menu("Начать с готовой темы") {
                        Button("BeeSave · светлая") { use(.preset(.beeSave)) }
                        Button("BeeSave · тёмная") { use(.preset(.beeSave, systemDark: true)) }
                        Button("Полночь") { use(.preset(.midnight)) }
                        Button("Сепия") { use(.preset(.sepia)) }
                        Button("Вернуть сохранённую палитру") { use(initial) }
                    }
                    BeePicker("Основа системных элементов", selection: $dark) { Text("Светлая").tag(false); Text("Тёмная").tag(true) }.beePickerStyle(.menu)
                    PalettePreview(palette: candidate)
                    Text("Палитра задаёт содержимое и акценты. Материал навигации и его текст адаптирует macOS. Цвета меняются в предпросмотре. Применение станет доступно, когда текст и элементы будут достаточно контрастными.")
                        .beeFont(.caption).foregroundStyle(BeeStyle.muted)
                    ForEach(PaletteField.allCases) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(field.rawValue).beeFont(.subheadline.weight(.medium))
                            HStack(spacing: 12) {
                                BeeColorWell(title: field.rawValue, selection: Binding(get: { candidate[keyPath: field.path].swiftUIColor }, set: { color in
                                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                                    func byte(_ component: CGFloat) -> UInt32 { UInt32((min(1, max(0, component)) * 255).rounded()) }
                                    let hex = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
                                    raw[field] = AppearanceColor(hex).hexString
                                }))
                                TextField("#RRGGBB", text: Binding(get: { raw[field] ?? "" }, set: { raw[field] = $0 }))
                                    .textFieldStyle(BeeTextFieldStyle()).beeFont(.body.monospaced()).accessibilityLabel(field.rawValue + ", HEX")
                            }
                        }
                    }
                    if !issues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Проверьте читаемость", systemImage: "exclamationmark.triangle").beeFont(.headline)
                            ForEach(issues, id: \.self) { Text($0).beeFont(.caption) }
                            Button("Вернуться к читаемой основе") { use(.preset(dark ? .midnight : .sepia)) }
                        }.foregroundStyle(BeeStyle.negative).accessibilityIdentifier("appearance.validation")
                    } else { Label("Все сочетания читаемы", systemImage: "checkmark.shield").beeFont(.caption).foregroundStyle(BeeStyle.positive) }
                }.padding(24)
            }
            Divider()
            HStack { Button("Отмена", action: close).keyboardShortcut(.cancelAction); Spacer()
                Button("Применить", action: apply).buttonStyle(BeePrimaryStyle()).disabled(!issues.isEmpty).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("appearance.applyCustom")
            }.padding(20)
        }.beeSheet(width: 640, height: 650).foregroundStyle(BeeStyle.text).background(BeeStyle.surface)
            .tint(BeeStyle.text).beeAppearance().interactiveDismissDisabled(dirty)
            .modifier(UpdateFormGuard(active: true))
            .confirmationDialog("Применить изменения палитры?", isPresented: $closing) {
                Button("Применить", action: apply).disabled(!issues.isEmpty)
                Button("Отказаться от изменений", role: .destructive) { dismiss() }
                Button("Продолжить редактирование", role: .cancel) {}
            }
    }
    private func use(_ palette: AppearancePalette) { dark = palette.dark; raw = Dictionary(uniqueKeysWithValues: PaletteField.allCases.map { ($0, palette[keyPath: $0.path].hexString) }) }
    private func close() { if dirty { closing = true } else { dismiss() } }
    private func apply() { guard issues.isEmpty else { return }; let palette = candidate; store.update { $0.custom = palette; $0.theme = .custom }; dismiss() }
}

private struct PalettePreview: View {
    var palette: AppearancePalette
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Предпросмотр").beeFont(.caption).foregroundStyle(palette.onBackground.swiftUIColor)
            HStack { Label("Главная", systemImage: "square.grid.2x2"); Spacer(); Image(systemName: "checkmark") }
                .beeFont(.subheadline).padding(12).foregroundStyle(palette.accentText.swiftUIColor).background(palette.accent.swiftUIColor, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 12) {
                Text("Всего на счетах").beeFont(.headline).foregroundStyle(palette.text.swiftUIColor)
                Text("128 450 ₽").beeFont(.title2.bold()).monospacedDigit().foregroundStyle(palette.text.swiftUIColor)
                Text("Текущие остатки · вымышленный пример").beeFont(.caption).foregroundStyle(palette.muted.swiftUIColor)
                HStack { Label("Доход", systemImage: "arrow.down.left").foregroundStyle(palette.positive.swiftUIColor); Label("Внимание", systemImage: "exclamationmark.triangle").foregroundStyle(palette.warning.swiftUIColor) }.beeFont(.caption)
                Label("Ошибка", systemImage: "xmark.circle").beeFont(.caption).foregroundStyle(palette.negative.swiftUIColor)
                Text("Добавить расход").beeFont(.subheadline.weight(.semibold)).padding(10).foregroundStyle(palette.accentText.swiftUIColor).background(palette.accent.swiftUIColor, in: RoundedRectangle(cornerRadius: 8))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(palette.surface.swiftUIColor, in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(palette.line.swiftUIColor.opacity(0.18)) }
        }.padding(18).background(LinearGradient(colors: [palette.backgroundStart.swiftUIColor, palette.backgroundEnd.swiftUIColor], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
    }
}
