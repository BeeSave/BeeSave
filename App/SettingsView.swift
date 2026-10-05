import SwiftUI
import BudgetCore

private enum SettingsEditor: String, Identifiable { case access, password, rate; var id: String { rawValue } }
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
            .sheet(item: $editor) { item in switch item { case .access: AccessSettingsEditor(); case .password: AccessSettingsEditor(changePassword: true); case .rate: ManualRateEditor() } }
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
                Label(model.bootstrap?.password != nil ? "Вход паролем включён" : "Вход паролем выключен", systemImage: "lock")
                Label(model.bootstrap?.touchID == true ? "Touch ID включён" : "Touch ID выключен", systemImage: "touchid")
                Button("Сменить пароль…") { editor = .password }
                Button("Настроить способы входа…") { editor = .access }
                Divider(); FormField(title: "Автоблокировка") { Picker("Автоблокировка", selection: Binding(get: { model.db?.settings.lockMinutes ?? 5 }, set: { minutes in model.perform { $0.settings.lockMinutes = minutes } })) { Text("Выключена").tag(0); ForEach([1, 5, 10, 15, 30], id: \.self) { Text("Через \($0) мин").tag($0) } }.labelsHidden() }
                Text("При блокировке Mac и сне данные скрываются. Незавершённые формы закрываются.").font(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard()
            DisclosureGroup("Диагностика") { Text(LocalKeys.keychainEntitled() ? "Права Keychain доступны." : "Для Touch ID и входа без пароля требуется подписанная сборка с правами Keychain.").font(.caption); Text(LocalKeys.biometricAvailable() ? "Touch ID доступен." : "Touch ID недоступен на этом Mac.").font(.caption) }
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
        case .transfer:
            VStack(alignment: .leading, spacing: 16) { Text("CSV для таблиц и обмена").font(.headline); Button("Импортировать CSV…") { model.sheet = SheetRoute(kind: .importCSV) }; Button("Экспортировать операции…") { model.exportCSV() }; Text("CSV хранится открытым текстом. Полная зашифрованная копия переносит все настройки и историю.").font(.caption).foregroundStyle(BeeStyle.muted) }.beeCard()
        }
    }
}

struct AccessSettingsEditor: View {
    @EnvironmentObject var model: AppModel
    var changePassword = false
    @FocusState private var passwordFocused: Bool
    @State private var current = ""
    @State private var recoveryAuth = false
    @State private var passwordOn = true
    @State private var touchID = false
    @State private var newPassword = ""
    @State private var repeated = ""
    @State private var openSessionConfirmed = false
    @State private var original: [String] = []
    @State private var loaded = false
    private var value: [String] { [current, String(recoveryAuth), String(passwordOn), String(touchID), newPassword, repeated, String(openSessionConfirmed)] }
    var body: some View {
        EditorFrame(title: changePassword ? "Сменить пароль" : "Способы входа", canSave: (passwordOn || touchID || openSessionConfirmed) && newPassword == repeated, isDirty: loaded && value != original, height: 600, saveAsync: {
            guard newPassword == repeated else { throw BudgetError.invalid("Пароли не совпали.") }; try await model.changeAccess(current: current, useRecovery: recoveryAuth, passwordEnabled: passwordOn, newPassword: newPassword, touchID: touchID)
        }, save: {}) {
            Toggle("Вход паролем приложения", isOn: $passwordOn).toggleStyle(.checkbox)
            Toggle("Touch ID", isOn: $touchID).toggleStyle(.checkbox).disabled(!LocalKeys.biometricAvailable())
            if !passwordOn && !touchID { Text("Бюджет будет доступен в вашей разблокированной сессии macOS.").font(.caption).foregroundStyle(BeeStyle.warning); Toggle("Подтверждаю вход без дополнительной проверки", isOn: $openSessionConfirmed).toggleStyle(.checkbox).disabled(!LocalKeys.keychainEntitled()) }
            if passwordOn { FormField(title: "Новый пароль", hint: "Не менее 12 символов. Оставьте пустым, чтобы сохранить текущий.") { SecureField("Новый пароль", text: $newPassword).textFieldStyle(.roundedBorder).focused($passwordFocused) }; FormField(title: "Повторите новый пароль") { SecureField("Повтор", text: $repeated).textFieldStyle(.roundedBorder) } }
            Divider(); Text("Подтвердите изменение").font(.headline)
            Toggle("Использовать ключ восстановления", isOn: $recoveryAuth).toggleStyle(.checkbox)
            FormField(title: recoveryAuth ? "Ключ восстановления" : "Текущий пароль приложения", hint: recoveryAuth ? nil : "При включённом Touch ID можно оставить пустым и подтвердить биометрией.") { SecureField("Подтверждение", text: $current).textFieldStyle(.roundedBorder) }
        }.onAppear { guard !loaded else { return }; passwordOn = changePassword || model.bootstrap?.password != nil; touchID = model.bootstrap?.touchID ?? false; original = value; loaded = true; passwordFocused = changePassword }.onDisappear { current = ""; newPassword = ""; repeated = "" }
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
