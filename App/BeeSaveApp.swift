import SwiftUI
import BudgetCore
import BudgetPresentation

@main struct BeeSaveApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdateManager(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
        macOS: ProcessInfo.processInfo.operatingSystemVersionStringForUpdates,
        architecture: "arm64")
    var body: some Scene {
        WindowGroup("BeeSave") { RootView().environmentObject(model).frame(minWidth: 1000, minHeight: 700) }
            .defaultSize(width: 1260, height: 840)
            .commands {
                AppUpdateCommands(updater: updater)
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
        Window("Обновление BeeSave", id: "app-update") {
            AppUpdateView(updater: updater)
        }.windowResizability(.contentSize)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group { if model.db != nil { HomeView() } else { AccessView() } }.beeWindow()
        #if DEBUG && UI_SMOKE
        .preferredColorScheme(model.previewAppearance)
        #endif
        .sheet(item: $model.sheet) { route in
            switch route.kind {
            case .account: AccountEditor(id: route.entityID)
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
            ToolbarItem { Menu("Тестовые состояния") { ForEach(PreviewScenario.allCases, id: \.self) { state in Button(state.title) { model.loadPreview(state) } }; Divider(); Button("Светлая тема") { model.previewAppearance = .light }; Button("Тёмная тема") { model.previewAppearance = .dark }; Button("Системная тема") { model.previewAppearance = nil }; Divider(); Button("Минимальное окно 1000 × 700") { NSApp.keyWindow?.setContentSize(NSSize(width: 1000, height: 700)) }; Button("Обычное окно 1260 × 840") { NSApp.keyWindow?.setContentSize(NSSize(width: 1260, height: 840)) } } }
            #endif
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
private extension ProcessInfo {
    var operatingSystemVersionStringForUpdates: String {
        let version = operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
