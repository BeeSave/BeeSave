import SwiftUI
import BudgetCore

private enum SettingsEditor: String, Identifiable { case password, rate; var id: String { rawValue } }
struct SettingsView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @State private var editor: SettingsEditor?
    private var selectedTask: SettingsTask { model.db == nil ? .appearance : model.settingsTask }
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Настройки").beeFont(.title2.bold()).padding(.bottom, 12)
                    ForEach(SettingsTask.allCases) { item in
                        Button { model.settingsTask = item } label: {
                            Text(item.rawValue).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .foregroundStyle(selectedTask == item ? BeeStyle.honeyText : BeeStyle.onBackground)
                                .background(selectedTask == item ? BeeStyle.honey : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay { if selectedTask == item { RoundedRectangle(cornerRadius: 8).strokeBorder(BeeStyle.honeyText, lineWidth: 1).allowsHitTesting(false) } }
                        }.buttonStyle(BeeRowStyle()).disabled(model.db == nil && item != .appearance)
                            .accessibilityAddTraits(selectedTask == item ? .isSelected : [])
                    }
                }.padding(18)
            }.frame(width: min(300, 205 * pow(appearanceStore.preferences.scale, 0.7))).background(BeeStyle.chrome)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.db == nil ? "Внешний вид" : model.settingsTask.rawValue).beeFont(.title2.bold())
                    if model.db == nil || model.settingsTask == .appearance { AppearanceSettingsView() }
                    else if let db = model.db { content(db: db) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
        }.beeWindow()
            #if DEBUG && UI_SMOKE
            .preferredColorScheme(appearanceStore.preferences.theme == .beeSave ? model.previewAppearance : appearanceStore.colorScheme)
            #endif
            .sheet(item: $editor) { item in switch item { case .password: PasswordSettingsEditor(); case .rate: ManualRateEditor() } }
            .onChange(of: model.db == nil) { if model.db == nil { editor = nil } }
    }
    @ViewBuilder private func content(db: Database) -> some View {
        switch model.settingsTask {
        case .appearance: AppearanceSettingsView()
        case .general:
            VStack(alignment: .leading, spacing: 16) {
                CurrencyPicker(title: "Базовая валюта", selection: Binding(get: { model.db?.settings.baseCurrency ?? "RUB" }, set: { currency in model.perform { $0.settings.baseCurrency = currency } }))
                Text("Валюта новых счетов и сводки по умолчанию. Валюты существующих счетов, планов и сохранённые снимки сохраняются.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard()
            Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · Обновления доступны в меню BeeSave.").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted)
        case .access:
            VStack(alignment: .leading, spacing: 16) {
                Label("Вход по паролю", systemImage: "lock")
                Button("Сменить пароль…") { editor = .password }
                Divider(); FormField(title: "Автоблокировка") { BeePicker("Автоблокировка", selection: Binding(get: { model.db?.settings.lockMinutes ?? 5 }, set: { minutes in model.perform { $0.settings.lockMinutes = minutes } })) { Text("Выключена").tag(0); ForEach([1, 5, 10, 15, 30], id: \.self) { Text("Через \($0) мин").tag($0) } }.labelsHidden() }
                Text("При блокировке Mac и сне данные скрываются. Незавершённые формы закрываются.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard()
        case .rates:
            VStack(alignment: .leading, spacing: 14) {
                Text("Последняя проверка: " + (db.settings.lastRateCheck?.formatted(date: .numeric, time: .shortened) ?? "ещё не выполнялась")).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                HStack { Button("Обновить курсы") { model.refreshRates() }.disabled(model.rateBusy); if model.rateBusy { ProgressView().controlSize(.small); Button("Отмена") { model.rateTask?.cancel() } } }
                Button("Добавить ручной курс…") { editor = .rate }
                Text("Справочные курсы не меняют сохранённые снимки операций. Для исправления снимка откройте операцию.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard()
            VStack(alignment: .leading, spacing: 12) { if db.rates.isEmpty { Text("Курсов пока нет").foregroundStyle(BeeStyle.muted) }; ForEach(db.rates.sorted { $0.date > $1.date }) { rate in Text(rate.label + (rate.stale ? " · устарел" : "")).beeFont(.caption).textSelection(.enabled); Divider() } }.beeCard()
        case .backups:
            VStack(alignment: .leading, spacing: 14) {
                Text("Последняя успешная копия: " + (db.settings.lastBackup?.formatted(date: .numeric, time: .shortened) ?? "ещё нет")).beeFont(.headline)
                if let error = model.backupError { Label(error, systemImage: "exclamationmark.triangle").beeFont(.caption).foregroundStyle(BeeStyle.negative) }
                Text(model.backupFolder.path).beeFont(.caption).textSelection(.enabled).foregroundStyle(BeeStyle.muted)
                Button("Скопировать путь", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.backupFolder.path, forType: .string) }
                Button("Изменить папку автокопий…") { model.changeBackupFolder() }
                Button("Сохранить полную копию…") { model.manualBackup() }.buttonStyle(BeePrimaryStyle())
                Text("Хранятся 30 дневных и 10 служебных копий. Ручные копии не удаляются. Для переноса нужен ключ восстановления.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                Divider(); Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }
            }.beeCard()
        case .reminders:
            VStack(alignment: .leading, spacing: 14) {
                Text("Финансовый календарь доступен без системных уведомлений.").beeFont(.headline)
                if db.financeData.reminders.systemEnabled { Button("Выключить системные уведомления") { model.perform { db in var book = db.financeData; book.reminders.systemEnabled = false; db.finances = book } } }
                else { Button("Включить системные уведомления…") { Task { await FinancialNotifications.enable(model: model) } } }
                Text("Системные напоминания содержат нейтральный текст. Названия счетов, суммы и условия видны после разблокировки. Планируются ближайшие 45 дней, до 60 напоминаний; окно пополняется при работе с бюджетом.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                if let status = model.financialNotificationStatus {
                    Text(status.message).beeFont(.caption)
                    if let through = status.scheduledThrough { Text("Проверено до: " + through.formatted(date: .numeric, time: .shortened) + " · в очереди: \(status.pendingCount)").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                    if let error = status.error { Text(error).beeFont(.caption).foregroundStyle(BeeStyle.negative) }
                }
                Button("Проверить расписание") { model.refreshFinancialForecasts() }.disabled(model.financialBusy)
                Button("Открыть системные настройки") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Открыть календарь") { model.section = .financialCalendar }
                #if DEBUG && UI_SMOKE && NOTIFICATION_QA
                Divider()
                Text("Проверка macOS · отдельный вымышленный бюджет").beeFont(.caption)
                Button("Тест: одно событие через две минуты") { model.prepareNotificationFixture(count: 1) }
                Button("Тест: плановый платёж через две минуты") { model.prepareNotificationFixture(count: 1, scheduled: true) }
                Button("Тест: два плановых платежа") { model.prepareNotificationFixture(count: 2, scheduled: true) }
                Button("Тест: очередь из 65 событий") { model.prepareNotificationFixture(count: 65) }
                Button("Тест: проверить очередь и нейтральный текст") { Task { await model.inspectNotificationFixture() } }
                #endif
            }.beeCard()
        case .transfer:
            VStack(alignment: .leading, spacing: 16) { Text("CSV для таблиц и обмена").beeFont(.headline); Button("Импортировать CSV…") { model.sheet = SheetRoute(kind: .importCSV) }; Button("Экспортировать операции…") { model.exportCSV() }; Text("CSV хранится открытым текстом. Полная зашифрованная копия переносит настройки бюджета и историю. Оформление сохраняется отдельно на этом Mac.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }.beeCard()
        }
    }
}

struct PasswordSettingsEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @FocusState private var passwordFocused: Bool
    @State private var current = ""
    @State private var recoveryAuth = false
    @State private var newPassword = ""
    @State private var repeated = ""
    @State private var original: [String] = []
    @State private var loaded = false
    private var value: [String] { [current, String(recoveryAuth), newPassword, repeated] }
    var body: some View {
        EditorFrame(title: "Сменить пароль", canSave: !current.isEmpty && newPassword.count >= 12 && newPassword == repeated, isDirty: loaded && value != original, height: 550, saveAsync: {
            guard newPassword == repeated else { throw BudgetError.invalid("Пароли не совпали.") }; try await model.changePassword(current: current, useRecovery: recoveryAuth, newPassword: newPassword)
        }, save: {}) {
            FormField(title: "Новый пароль", hint: "Не менее 12 символов") { SecureField("Новый пароль", text: $newPassword).textFieldStyle(BeeTextFieldStyle()).focused($passwordFocused) }
            FormField(title: "Повторите новый пароль") { SecureField("Повтор", text: $repeated).textFieldStyle(BeeTextFieldStyle()) }
            Divider(); Text("Подтвердите изменение").beeFont(.headline)
            Toggle("Использовать ключ восстановления", isOn: $recoveryAuth).toggleStyle(.checkbox)
            FormField(title: recoveryAuth ? "Ключ восстановления" : "Текущий пароль приложения") { SecureField("Подтверждение", text: $current).textFieldStyle(BeeTextFieldStyle()) }
        }.onAppear { guard !loaded else { return }; original = value; loaded = true; passwordFocused = true }.onDisappear { current = ""; newPassword = ""; repeated = "" }
    }
}

struct ManualRateEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @State private var base = "USD"
    @State private var quote = "RUB"
    @State private var value = ""
    @State private var day = Day.today.rawValue
    @FocusState private var focused: Bool
    var body: some View {
        EditorFrame(title: "Ручной справочный курс", canSave: base != quote, isDirty: !value.isEmpty || base != "USD" || quote != "RUB" || day != Day.today.rawValue, height: 480, onError: { _ in focused = true }, save: {
            let rate = FXRate(base: base, quote: quote, rate: value.replacingOccurrences(of: ",", with: "."), date: try Day(day)); try Ledger.validateRate(rate); try model.commit { $0.rates.append(rate) }
        }) { HStack { CurrencyPicker(title: "Из валюты", selection: $base); CurrencyPicker(title: "В валюту", selection: $quote) }; FormField(title: "1 \(base) = X \(quote)") { TextField("Курс", text: $value).textFieldStyle(BeeTextFieldStyle()).focused($focused) }; DayField(title: "Дата действия", value: $day); Text("Курс добавится в кеш. Исторические снимки сохраняются.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }.onAppear { focused = true }
    }
}
