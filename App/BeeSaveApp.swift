import SwiftUI
import BudgetCore
import BudgetPresentation

@main struct BeeSaveApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = InstallUpdateManager()
    var body: some Scene {
        WindowGroup("BeeSave") {
            RootView().environmentObject(model).beeAppearance().frame(minWidth: 1000, minHeight: 700)
                .onAppear { updater.attach(model); applicationDelegate.updater = updater; applicationDelegate.model = model }
        }
            .defaultSize(width: 1260, height: 840)
            .commands {
                AppUpdateCommands(updater: updater)
                CommandGroup(after: .newItem) {
                    Button("Новый расход") { model.newOperation(.expense) }.keyboardShortcut("n").disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Button("Новый доход") { model.newOperation(.income) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Divider(); Button("Импорт CSV…") { model.sheet = SheetRoute(kind: .importCSV) }.disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Button("Экспорт всех операций…") { model.exportCSV() }.disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Divider(); Button("Сохранить полную копию…") { model.manualBackup() }.disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }.disabled(model.updateFrozen || model.updateVerificationPending)
                }
                CommandGroup(after: .appSettings) { Button("Заблокировать") { model.lock() }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(model.db == nil) }
            }
        Settings { SettingsView().environmentObject(model).frame(minWidth: 760, idealWidth: 860, minHeight: 680, idealHeight: 760).disabled(model.updateFrozen) }
        Window("Обновление BeeSave", id: "app-update") {
            AppUpdateView(updater: updater).beeAppearance()
        }.windowResizability(.contentSize)
        #if DEBUG && UI_SMOKE
        Window("Проверка экранов", id: "appearance-screens") {
            AppearanceScreenPreview().environmentObject(model).beeAppearance()
        }
        #endif
    }
}

struct RootView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    #if DEBUG && UI_SMOKE
    @State private var showBankBrands = false
    @Environment(\.openWindow) private var openWindow
    #endif
    var body: some View {
        Group { if model.db != nil { HomeView() } else { AccessView() } }.beeWindow()
        .background(BudgetWindowMarker())
        .disabled(model.updateFrozen)
        #if DEBUG && UI_SMOKE
        .preferredColorScheme(appearanceStore.preferences.theme == .beeSave ? (model.previewAppearance ?? appearanceStore.colorScheme) : appearanceStore.colorScheme)
        .sheet(isPresented: $showBankBrands) { BankBrandPreview().environmentObject(model).preferredColorScheme(appearanceStore.preferences.theme == .beeSave ? (model.previewAppearance ?? appearanceStore.colorScheme) : appearanceStore.colorScheme) }
        #endif
        .sheet(item: $model.sheet) { route in
            switch route.kind {
            case .account: AccountEditor(id: route.entityID)
            case .bank: BankEditor()
            case .financialPayment: FinancialGroupEditor(groupID: route.entityID)
            case .scheduledPayment: ScheduledPaymentEditor(id: route.entityID)
            case .scheduledDetail: ScheduledPaymentDetail(id: route.entityID)
            case .operation: OperationEditor(id: route.entityID, kind: route.operationKind, accountContext: route.accountContext)
            case .reconciliation: ReconcileEditor(accountID: route.entityID)
            case .category: CategoryEditor(id: route.entityID, initialKind: route.operationKind)
            case .project: ProjectEditor(id: route.entityID)
            case .budget: BudgetEditor(id: route.entityID, initialKind: route.budgetKind)
            case .report: ReportEditor(id: route.entityID)
            case .reportView: ReportViewer(id: route.entityID)
            case .layout: LayoutEditor()
            case .importCSV: ImportView()
            case .restore: RestoreView()
            }
        }
        .toolbar {
            #if DEBUG && UI_SMOKE
            ToolbarItem { Menu("Оформление QA") {
                Button("Проверка экранов…") { openWindow(id: "appearance-screens") }
                ForEach(AppearanceTheme.allCases) { theme in
                    ForEach([100, 110, 125, 140, 160], id: \.self) { percent in
                        Button(theme.title + " · \(percent)%") { appearanceStore.update { $0.theme = theme; $0.textPercent = percent } }
                    }
                }
                Button("Окно 1440 × 900") { BudgetWindows.preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow)?.setContentSize(NSSize(width: 1440, height: 900)) }
            } }
            ToolbarItem { Menu("Тестовые состояния") { ForEach(PreviewScenario.allCases, id: \.self) { state in Button(state.title) { model.loadPreview(state) } }; Divider(); Button("Замер · Главная") { model.measureFixturePresentation(.dashboard) }; Button("Замер · Счета") { model.measureFixturePresentation(.accounts) }; Button("Замер · Календарь") { model.measureFixturePresentation(.financialCalendar) }; Button("Замер · Платёж") { model.measureFixturePayment() }; Divider(); Button("Логотипы банков…") { showBankBrands = true }; Button("Светлая тема") { model.previewAppearance = .light }; Button("Тёмная тема") { model.previewAppearance = .dark }; Button("Системная тема") { model.previewAppearance = nil }; Divider(); Button("Минимальное окно 1000 × 700") { BudgetWindows.preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow)?.setContentSize(NSSize(width: 1000, height: 700)) }; Button("Обычное окно 1260 × 840") { BudgetWindows.preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow)?.setContentSize(NSSize(width: 1260, height: 840)) } } }
            #endif
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

#if DEBUG && UI_SMOKE
/// Uses the actual views with an unattached updater and disposable fixtures.
/// No installer, credential submission, or production storage is involved.
private struct AppearanceScreenPreview: View {
    @StateObject private var updater = InstallUpdateManager(client: AppUpdateClient(transport: AppearanceUpdateTransport()))
    @State private var screen = "Вход"
    @State private var updateState = 0
    private let screens = ["Вход", "Создание · 1", "Создание · 2", "Создание · 3", "Обновление"]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BeePicker("Экран QA", selection: $screen) { ForEach(screens, id: \.self) { Text($0).tag($0) } }
                if screen == "Обновление" {
                    BeePicker("Состояние QA", selection: $updateState) {
                        ForEach(Array(InstallUpdateManager.appearanceStateTitles.enumerated()), id: \.offset) { index, title in Text(title).tag(index) }
                    }
                }
                Menu("Оформление QA") {
                    ForEach(AppearanceTheme.allCases) { theme in
                        ForEach([100, 160], id: \.self) { percent in
                            Button(theme.title + " · \(percent)%") { AppearanceStore.shared.update { $0.theme = theme; $0.textPercent = percent } }
                        }
                    }
                }
            }.padding(12)
            Divider()
            ScrollView {
                Group {
                    switch screen {
                    case "Создание · 1": SetupWizard(qaStep: 0)
                    case "Создание · 2": SetupWizard(qaStep: 1)
                    case "Создание · 3": SetupWizard(qaStep: 2)
                    case "Обновление": AppUpdateView(updater: updater)
                    default: LoginView()
                    }
                }.id(screen).frame(maxWidth: .infinity)
            }
        }.frame(width: 1000, height: 700).beeWindow()
        .task(id: updateState) { await updater.previewAppearanceState(updateState) }
    }
}
#endif
