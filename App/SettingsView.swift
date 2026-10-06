import SwiftUI
import BudgetCore

private enum SettingsEditor: String, Identifiable { case password, rate; var id: String { rawValue } }
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editor: SettingsEditor?
    var body: some View {
        Group { if let db = model.db {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) { Text("Настройки").font(.title2.bold()).padding(.bottom, 12); ForEach(SettingsTask.allCases) { item in Button { model.settingsTask = item } label: { Text(item.rawValue).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(model.settingsTask == item ? BeeStyle.onBackground.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain) }; Spacer() }.padding(18).frame(width: 195).background(BeeStyle.chrome)
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    Text(model.settingsTask.rawValue).font(.title2.bold())
                    content(db: db)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24) }
            }
        } else { EmptyState(title: "Бюджет закрыт", detail: "Войдите в основном окне, чтобы открыть настройки.", icon: "lock").beeCard().padding(30) } }.beeWindow()
            #if DEBUG && UI_SMOKE
            .preferredColorScheme(model.previewAppearance)
            #endif
            .sheet(item: $editor) { item in switch item { case .password: PasswordSettingsEditor(); case .rate: ManualRateEditor() } }
            .onChange(of: model.db == nil) { if model.db == nil { editor = nil } }
    }
    @ViewBuilder private func content(db: Database) -> some View {
        switch model.settingsTask {
        case .general:
            VStack(alignment: .leading, spacing: 16) {
                CurrencyPicker(title: "Базовая валюта", selection: Binding(get: { model.db?.settings.baseCurrency ?? "RUB" }, set: { currency in model.perform { $0.settings.baseCurrency = currency } }))
                Text("Валюта новых счетов и сводки по умолчанию. Валюты существующих счетов, планов и сохранённые снимки сохраняются.").font(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard()
            Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · Обновления доступны в меню BeeSave.").font(.caption).foregroundStyle(BeeStyle.backgroundMuted)
        case .access:
            VStack(alignment: .leading, spacing: 16) {
                Label("Вход по паролю", systemImage: "lock")
                Button("Сменить пароль…") { editor = .password }
                Divider(); FormField(title: "Автоблокировка") { Picker("Автоблокировка", selection: Binding(get: { model.db?.settings.lockMinutes ?? 5 }, set: { minutes in model.perform { $0.settings.lockMinutes = minutes } })) { Text("Выключена").tag(0); ForEach([1, 5, 10, 15, 30], id: \.self) { Text("Через \($0) мин").tag($0) } }.labelsHidden() }
                Text("При блокировке Mac и сне данные скрываются. Незавершённые формы закрываются.").font(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard()
        case .rates:
            VStack(alignment: .leading, spacing: 14) {
                Text("Последняя проверка: " + (db.settings.lastRateCheck?.formatted(date: .numeric, time: .shortened) ?? "ещё не выполнялась")).font(.caption).foregroundStyle(BeeStyle.muted)
                HStack { Button("Обновить курсы") { model.refreshRates() }.disabled(model.rateBusy); if model.rateBusy { ProgressView().controlSize(.small); Button("Отмена") { model.rateTask?.cancel() } } }
                Button("Добавить ручной курс…") { editor = .rate }
                Text("Справочные курсы не меняют сохранённые снимки операций. Для исправления снимка откройте операцию.").font(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard()
            VStack(alignment: .leading, spacing: 12) { if db.rates.isEmpty { Text("Курсов пока нет").foregroundStyle(BeeStyle.muted) }; ForEach(db.rates.sorted { $0.date > $1.date }) { rate in Text(rate.label + (rate.stale ? " · устарел" : "")).font(.caption).textSelection(.enabled); Divider() } }.beeCard()
        case .backups:
            VStack(alignment: .leading, spacing: 14) {
                Text("Последняя успешная копия: " + (db.settings.lastBackup?.formatted(date: .numeric, time: .shortened) ?? "ещё нет")).font(.headline)
                if let error = model.backupError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(BeeStyle.negative) }
                Text(model.backupFolder.path).font(.caption).textSelection(.enabled).foregroundStyle(BeeStyle.muted)
                Button("Скопировать путь", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.backupFolder.path, forType: .string) }
                Button("Изменить папку автокопий…") { model.changeBackupFolder() }
                Button("Сохранить полную копию…") { model.manualBackup() }.buttonStyle(BeePrimaryStyle())
                Text("Хранятся 30 дневных и 10 служебных копий. Ручные копии не удаляются. Для переноса нужен ключ восстановления.").font(.caption).foregroundStyle(BeeStyle.muted)
                Divider(); Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }
            }.beeCard()
        case .reminders:
            VStack(alignment: .leading, spacing: 14) {
                Text("Финансовый календарь доступен без системных уведомлений.").font(.headline)
                if db.financeData.reminders.systemEnabled { Button("Выключить системные уведомления") { model.perform { db in var book = db.financeData; book.reminders.systemEnabled = false; db.finances = book } } }
                else { Button("Включить системные уведомления…") { Task { await FinancialNotifications.enable(model: model) } } }
                Text("Системные напоминания содержат нейтральный текст. Названия счетов, суммы и условия видны после разблокировки. Планируются ближайшие 45 дней, до 60 напоминаний; окно пополняется при работе с бюджетом.").font(.caption).foregroundStyle(BeeStyle.muted)
                if let status = model.financialNotificationStatus {
                    Text(status.message).font(.caption)
                    if let through = status.scheduledThrough { Text("Проверено до: " + through.formatted(date: .numeric, time: .shortened) + " · в очереди: \(status.pendingCount)").font(.caption).foregroundStyle(BeeStyle.muted) }
                    if let error = status.error { Text(error).font(.caption).foregroundStyle(BeeStyle.negative) }
                }
                Button("Проверить расписание") { model.refreshFinancialForecasts() }.disabled(model.financialBusy)
                Button("Открыть календарь") { model.section = .financialCalendar }
            }.beeCard()
        case .transfer:
            VStack(alignment: .leading, spacing: 16) { Text("CSV для таблиц и обмена").font(.headline); Button("Импортировать CSV…") { model.sheet = SheetRoute(kind: .importCSV) }; Button("Экспортировать операции…") { model.exportCSV() }; Text("CSV хранится открытым текстом. Полная зашифрованная копия переносит все настройки и историю.").font(.caption).foregroundStyle(BeeStyle.muted) }.beeCard()
        }
    }
}

struct PasswordSettingsEditor: View {
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
            FormField(title: "Новый пароль", hint: "Не менее 12 символов") { SecureField("Новый пароль", text: $newPassword).textFieldStyle(.roundedBorder).focused($passwordFocused) }
            FormField(title: "Повторите новый пароль") { SecureField("Повтор", text: $repeated).textFieldStyle(.roundedBorder) }
            Divider(); Text("Подтвердите изменение").font(.headline)
            Toggle("Использовать ключ восстановления", isOn: $recoveryAuth).toggleStyle(.checkbox)
            FormField(title: recoveryAuth ? "Ключ восстановления" : "Текущий пароль приложения") { SecureField("Подтверждение", text: $current).textFieldStyle(.roundedBorder) }
        }.onAppear { guard !loaded else { return }; original = value; loaded = true; passwordFocused = true }.onDisappear { current = ""; newPassword = ""; repeated = "" }
    }
}

struct ManualRateEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var base = "USD"
    @State private var quote = "RUB"
    @State private var value = ""
    @State private var day = Day.today.rawValue
    @FocusState private var focused: Bool
    var body: some View {
        EditorFrame(title: "Ручной справочный курс", canSave: base != quote, isDirty: !value.isEmpty || base != "USD" || quote != "RUB" || day != Day.today.rawValue, height: 480, onError: { _ in focused = true }, save: {
            let rate = FXRate(base: base, quote: quote, rate: value.replacingOccurrences(of: ",", with: "."), date: try Day(day)); try Ledger.validateRate(rate); try model.commit { $0.rates.append(rate) }
        }) { HStack { CurrencyPicker(title: "Из валюты", selection: $base); CurrencyPicker(title: "В валюту", selection: $quote) }; FormField(title: "1 \(base) = X \(quote)") { TextField("Курс", text: $value).textFieldStyle(.roundedBorder).focused($focused) }; DayField(title: "Дата действия", value: $day); Text("Курс добавится в кеш. Исторические снимки сохраняются.").font(.caption).foregroundStyle(BeeStyle.muted) }.onAppear { focused = true }
    }
}
