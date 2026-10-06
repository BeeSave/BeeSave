import SwiftUI
import BudgetCore
import BudgetPresentation

@main struct BeeSaveApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = InstallUpdateManager()
    var body: some Scene {
        WindowGroup("BeeSave") {
            RootView().environmentObject(model).frame(minWidth: 1000, minHeight: 700)
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
        Settings { SettingsView().environmentObject(model).frame(width: 700, height: 680).disabled(model.updateFrozen) }
        Window("Обновление BeeSave", id: "app-update") {
            AppUpdateView(updater: updater)
        }.windowResizability(.contentSize)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    #if DEBUG && UI_SMOKE
    @State private var showBankBrands = false
    #endif
    var body: some View {
        Group { if model.db != nil { HomeView() } else { AccessView() } }.beeWindow()
        .disabled(model.updateFrozen)
        #if DEBUG && UI_SMOKE
        .preferredColorScheme(model.previewAppearance)
        .sheet(isPresented: $showBankBrands) { BankBrandPreview().environmentObject(model).preferredColorScheme(model.previewAppearance) }
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
            ToolbarItem { Menu("Тестовые состояния") { ForEach(PreviewScenario.allCases, id: \.self) { state in Button(state.title) { model.loadPreview(state) } }; Divider(); Button("Замер · Главная") { model.measureFixturePresentation(.dashboard) }; Button("Замер · Счета") { model.measureFixturePresentation(.accounts) }; Button("Замер · Календарь") { model.measureFixturePresentation(.financialCalendar) }; Button("Замер · Платёж") { model.measureFixturePayment() }; Divider(); Button("Логотипы банков…") { showBankBrands = true }; Button("Светлая тема") { model.previewAppearance = .light }; Button("Тёмная тема") { model.previewAppearance = .dark }; Button("Системная тема") { model.previewAppearance = nil }; Divider(); Button("Минимальное окно 1000 × 700") { NSApp.keyWindow?.setContentSize(NSSize(width: 1000, height: 700)) }; Button("Обычное окно 1260 × 840") { NSApp.keyWindow?.setContentSize(NSSize(width: 1260, height: 840)) } } }
            #endif
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
