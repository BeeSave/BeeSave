import SwiftUI
import BudgetCore

@main struct BeeSaveApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("BeeSave") { RootView().environmentObject(model).frame(minWidth: 1000, minHeight: 700) }
            .defaultSize(width: 1260, height: 840)
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Новый расход") { model.newOperation(.expense) }.keyboardShortcut("n").disabled(model.db == nil)
                    Button("Новый доход") { model.newOperation(.income) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.db == nil)
                    Divider(); Button("Импорт CSV…") { model.sheet = SheetRoute(kind: .importCSV) }.disabled(model.db == nil)
                    Button("Экспорт всех операций…") { model.exportCSV() }.disabled(model.db == nil)
                    Divider(); Button("Сохранить полную копию…") { model.manualBackup() }.disabled(model.db == nil)
                    Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }
                }
                CommandGroup(after: .appSettings) { Button("Заблокировать") { model.lock() }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(model.db == nil) }
            }
        Settings { SettingsView().environmentObject(model).frame(width: 700, height: 680) }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group { if model.db != nil { HomeView() } else { AccessView() } }
        .sheet(item: $model.sheet) { route in
            switch route.kind {
            case .account: AccountEditor(id: route.entityID)
            case .operation: OperationEditor(id: route.entityID, kind: route.operationKind)
            case .reconciliation: ReconcileEditor(accountID: route.entityID)
            case .category: CategoryEditor(id: route.entityID)
            case .project: ProjectEditor(id: route.entityID)
            case .budget: BudgetEditor(id: route.entityID)
            case .report: ReportEditor(id: route.entityID)
            case .layout: LayoutEditor()
            case .importCSV: ImportView()
            case .restore: RestoreView()
            }
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
struct AccessView: View {
    @EnvironmentObject var model: AppModel
    @State private var currency = "RUB"; @State private var password = ""; @State private var repeatPassword = ""; @State private var passwordOn = true; @State private var touchID = false; @State private var recovery = ""; @State private var recoveryCheck = ""; @State private var restoringAccess = false; @State private var acknowledged = false; @State private var setupError = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "wallet.bifold.fill").font(.system(size: 48)).foregroundStyle(.teal)
            Text("BeeSave").font(.largeTitle.bold()); Text("Ваш домашний бюджет. На вашем Mac.").font(.title3).foregroundStyle(.secondary)
            if let error = model.startupError { Text(error).foregroundStyle(.red); Button("Повторить открытие") { do { try model.vault.acquire(); model.bootstrap = try model.vault.inspect(); model.startupError = nil } catch { model.startupError = error.localizedDescription } } }
            if model.vault.exists {
                Text("Финансовые данные скрыты до успешного входа.")
                if restoringAccess { TextField("Ключ восстановления", text: $recoveryCheck).textFieldStyle(.roundedBorder); Button("Войти с ключом") { model.unlock(recovery: recoveryCheck); recoveryCheck = "" }.buttonStyle(.borderedProminent) }
                else {
                    if model.bootstrap?.password != nil { SecureField("Пароль приложения", text: $password).textFieldStyle(.roundedBorder).onSubmit { model.unlock(password: password); password = "" }; Button("Открыть бюджет") { model.unlock(password: password); password = "" }.buttonStyle(.borderedProminent) }
                    if model.bootstrap?.touchID == true { Button("Войти с Touch ID", systemImage: "touchid") { model.unlock(biometric: true) } }
                    if model.bootstrap?.requiresAuthentication == false { Button("Открыть через локальный Keychain") { model.resumeSession() } }
                }
                Button(restoringAccess ? "Вернуться к обычному входу" : "Использовать ключ восстановления") { restoringAccess.toggle() }
                if let retry = model.retryAt, retry > Date() { Text("Повторный ввод доступен через 30 секунд.").foregroundStyle(.orange) }
            } else {
                Text("Без регистрации и сервера. База и полные копии зашифрованы. Интернет нужен только для справочных валютных курсов.")
                CurrencyPicker(title: "Базовая валюта", selection: $currency)
                Toggle("Пароль приложения", isOn: $passwordOn)
                if passwordOn { SecureField("Не менее 12 символов", text: $password); SecureField("Повторите пароль", text: $repeatPassword) }
                Toggle("Touch ID", isOn: $touchID).disabled(!LocalKeys.biometricAvailable())
                if !LocalKeys.keychainEntitled() { Text("Эта тестовая сборка поддерживает вход паролем. Для Touch ID и входа без пароля нужна подписанная сборка с правами Keychain.").font(.caption).foregroundStyle(.secondary) }
                else if !LocalKeys.biometricAvailable() { Text("Touch ID не доступен на этом Mac. Вход паролем работает самостоятельно.").font(.caption).foregroundStyle(.secondary) }
                if !passwordOn && !touchID { Text("Шифрование сохраняется. Любой пользователь вашей разблокированной сессии macOS сможет открыть приложение.").foregroundStyle(.orange) }
                Text("Ключ восстановления").font(.headline)
                Text("Сохраните ключ вне этого Mac. Он нужен для переноса копии и восстановления доступа. Если утрачены все способы входа и ключ, данные восстановить невозможно.")
                Text(recovery).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Toggle("Я сохранил(а) ключ в безопасном месте", isOn: $acknowledged)
                TextField("Введите сохранённый ключ повторно", text: $recoveryCheck)
                if !setupError.isEmpty { Text(setupError).foregroundStyle(.red) }
                Button("Создать локальный бюджет") { do { guard !passwordOn || password == repeatPassword else { throw BudgetError.invalid("Пароли не совпали.") }; try model.setup(currency: currency, password: passwordOn ? password : "", touchID: touchID, recovery: recovery, confirmed: recoveryCheck); password = ""; repeatPassword = ""; recovery = ""; recoveryCheck = "" } catch { setupError = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(!acknowledged || model.busy)
            }
            Divider(); Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }
        }.padding(40).frame(maxWidth: 660).frame(maxWidth: .infinity) }.task { if recovery.isEmpty && !model.vault.exists { recovery = (try? VaultCrypto.recoveryString(VaultCrypto.random())) ?? "" } }
    }
}
