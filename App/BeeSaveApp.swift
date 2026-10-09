import SwiftUI
import BudgetCore
import BudgetPresentation

@main struct BeeSaveApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = InstallUpdateManager()
    var body: some Scene {
        Window("Вход в BeeSave", id: "access") {
            RootView(role: .access).environmentObject(model).beeAppearance()
                .onAppear { updater.attach(model); applicationDelegate.updater = updater; applicationDelegate.model = model }
        }
            .defaultSize(width: 420, height: 320)
            .defaultPosition(.center)
            .defaultLaunchBehavior(.presented)
            .windowResizability(.contentSize)
            .windowManagerRole(.associated)
            .restorationBehavior(.disabled)
            .commands {
                AppUpdateCommands(updater: updater)
                BeeSectionCommands()
                CommandGroup(after: .newItem) {
                    Button("Новый расход") { model.newOperation(.expense) }.keyboardShortcut("n").disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Button("Новый доход") { model.newOperation(.income) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Divider(); Button("Импорт CSV…") { model.sheet = SheetRoute(kind: .importCSV) }.disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Button("Экспорт всех операций…") { model.exportCSV() }.disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Divider(); Button("Сохранить полную копию…") { model.manualBackup() }.disabled(model.db == nil || model.updateFrozen || model.updateVerificationPending)
                    Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }.disabled(model.updateFrozen || model.updateVerificationPending)
                }
                CommandGroup(after: .windowSize) {
                    Button("Стандартный размер") { BudgetWindows.standardSize() }.disabled(model.db == nil)
                }
                CommandGroup(after: .appSettings) { Button("Заблокировать") { model.lock() }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(model.db == nil) }
            }
        Window("BeeSave", id: "workspace") {
            RootView(role: .workspace).environmentObject(model).beeAppearance()
                .windowFullScreenBehavior(.enabled)
                .windowResizeBehavior(.enabled)
        }.defaultSize(width: 1440, height: 900)
            .windowManagerRole(.principal)
            .defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
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
    var role: BudgetWindowRole = .workspace
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private var active: Bool { role == .workspace ? model.db != nil : model.db == nil }
    #if DEBUG && UI_SMOKE
    @State private var showBankBrands = false
    #endif
    var body: some View {
        Group {
            if role == .workspace { if model.db != nil { HomeView() } else { Color.clear } }
            else if model.db == nil { AccessView() }
            else { ProgressView().frame(width: 420, height: 320) }
        }.beeWindow().beeNotices()
        .background(BudgetWindowMarker(role: role))
        .onAppear { synchronizeWindows() }
        .onChange(of: model.db != nil) { synchronizeWindows() }
        .disabled(model.updateFrozen)
        #if DEBUG && UI_SMOKE
        .preferredColorScheme(appearanceStore.preferences.theme == .beeSave ? (model.previewAppearance ?? appearanceStore.colorScheme) : appearanceStore.colorScheme)
        .sheet(isPresented: $showBankBrands) { BankBrandPreview().environmentObject(model).preferredColorScheme(appearanceStore.preferences.theme == .beeSave ? (model.previewAppearance ?? appearanceStore.colorScheme) : appearanceStore.colorScheme) }
        #endif
        .sheet(item: Binding(get: { active ? model.sheet : nil }, set: { model.sheet = $0 })) { route in
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
        #if DEBUG && UI_SMOKE
        .focusedSceneValue(\.beeQAActions, AnyView(qaActions))
        #endif
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { active && role == .workspace && model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    #if DEBUG && UI_SMOKE
    private var qaActions: some View {
        Group {
            Menu("Оформление QA") {
                Button("Проверка экранов…") { openWindow(id: "appearance-screens") }
                ForEach(AppearanceTheme.allCases) { theme in
                    ForEach([100, 110, 125, 140, 160], id: \.self) { percent in
                        Button(theme.title + " · \(percent)%") { appearanceStore.update { $0.theme = theme; $0.textPercent = percent } }
                    }
                }
                Button("Окно 1440 × 900") { BudgetWindows.preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow)?.setContentSize(NSSize(width: 1440, height: 900)) }
            }
            Menu("Тестовые состояния") { ForEach(PreviewScenario.allCases, id: \.self) { state in Button(state.title) { model.loadPreview(state) } }; Divider(); Button("Замер · Главная") { model.measureFixturePresentation(.dashboard) }; Button("Замер · Счета") { model.measureFixturePresentation(.accounts) }; Button("Замер · Календарь") { model.measureFixturePresentation(.financialCalendar) }; Button("Замер · Платёж") { model.measureFixturePayment() }; Divider(); Button("Логотипы банков…") { showBankBrands = true }; Button("Светлая тема") { model.previewAppearance = .light; appearanceStore.previewColorScheme = .light }; Button("Тёмная тема") { model.previewAppearance = .dark; appearanceStore.previewColorScheme = .dark }; Button("Системная тема") { model.previewAppearance = nil; appearanceStore.previewColorScheme = nil }; Divider(); Button("Минимальное окно 1000 × 700") { BudgetWindows.preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow)?.setContentSize(NSSize(width: 1000, height: 700)) }; Button("Обычное окно 1260 × 840") { BudgetWindows.preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow)?.setContentSize(NSSize(width: 1260, height: 840)) } }
            Divider()
            Menu("Валюты QA") {
                Button("Согласованная Главная · 017") { model.prepareHome017QA() }
                Button("Снижение прозрачности · Вкл") { model.previewReduceTransparency = true }
                Button("Снижение прозрачности · Выкл") { model.previewReduceTransparency = false }
                Button("Длинные суммы и старые курсы") { model.prepareDashboardCurrencyQA(overflow: false) }
                Button("Ошибка расчёта остатков") { model.prepareDashboardCurrencyQA(overflow: true) }
            }
            Button("Активировать тестовое окно") { NSApp.activate(ignoringOtherApps: true); BudgetWindows.bringForward() }
            Menu("Формы QA") {
                Button("Счёт · QA") { model.sheet = SheetRoute(kind: .account) }
                Button("Расход · QA") { model.sheet = SheetRoute(kind: .operation, operationKind: .expense) }
                Button("Доход · QA") { model.sheet = SheetRoute(kind: .operation, operationKind: .income) }
                Button("Перевод · QA") { model.sheet = SheetRoute(kind: .operation, operationKind: .transfer) }
                Button("Категория · QA") { model.sheet = SheetRoute(kind: .category) }
                Button("Проект · QA") { model.sheet = SheetRoute(kind: .project) }
                Button("Бюджет · QA") { model.sheet = SheetRoute(kind: .budget) }
                Button("Отчёт · QA") { model.sheet = SheetRoute(kind: .report) }
                Button("Раскладка · QA") { model.sheet = SheetRoute(kind: .layout) }
                Button("Импорт · QA") { model.sheet = SheetRoute(kind: .importCSV) }
                Button("Восстановление · QA") { model.sheet = SheetRoute(kind: .restore) }
                Button("Плановый платёж · QA") { model.sheet = SheetRoute(kind: .scheduledPayment) }
            }
            Button("Своя светлая · 100%") { appearanceStore.update { $0.custom = .preset(.beeSave, systemDark: false); $0.theme = .custom; $0.textPercent = 100 } }
            Button("Своя тёмная · 160%") { appearanceStore.update { $0.custom = .preset(.beeSave, systemDark: true); $0.theme = .custom; $0.textPercent = 160 } }
            Button("Краткое сообщение") { model.showNotice("Курсы обновлены", kind: .success) }
            Button("Другое сообщение") { model.showNotice("Отчёт сохранён", kind: .success) }
            Button("Предупреждение") { model.showNotice("Не удалось обновить курсы. Сохранённые курсы доступны в настройках.", kind: .warning) }
            Button("Ошибка открытия · QA") {
                guard model.root.lastPathComponent.hasPrefix("BeeSaveSmoke-"), model.db != nil else { return }
                do {
                    let original = try Data(contentsOf: model.vault.url)
                    model.lock()
                    do {
                        try Data("Invalid fictional QA vault".utf8).write(to: model.vault.url, options: .atomic)
                        _ = try model.vault.inspect()
                        model.startupError = "QA: повреждённый файл ошибочно принят."
                    } catch { model.startupError = error.localizedDescription }
                    try original.write(to: model.vault.url, options: .atomic)
                    guard try Data(contentsOf: model.vault.url) == original else {
                        throw BudgetError.storage("QA: исходный тестовый файл не восстановлен.")
                    }
                } catch { model.startupError = error.localizedDescription }
            }
            Button("Геометрия окна") {
                if let window = BudgetWindows.preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow) {
                    let size = window.contentRect(forFrameRect: window.frame).size
                    let screen = window.screen?.frame ?? .zero
                    model.showNotice("Окно: \(Int(size.width)) × \(Int(size.height)) pt · рамка \(Int(window.frame.minX)), \(Int(window.frame.minY)), \(Int(window.frame.width)), \(Int(window.frame.height)) · экран \(Int(screen.width)) × \(Int(screen.height)) · экранов \(NSScreen.screens.count)", kind: .information)
                }
            }
            Button("Проверка старой геометрии") {
                guard model.root.lastPathComponent.hasPrefix("BeeSaveSmoke-"),
                      let window = BudgetWindows.preferred(ordered: NSApp.orderedWindows + NSApp.windows, key: NSApp.keyWindow) else { return }
                let legacy = "QA.WindowGroup.RootView"
                window.setContentSize(NSSize(width: 1120, height: 760))
                window.saveFrame(usingName: legacy)
                window.setContentSize(NSSize(width: 1440, height: 900))
                UserDefaults.standard.removeObject(forKey: "BeeSave.workspace.frame.v2")
                BudgetWindows.configure(window, role: .workspace)
                let size = window.contentRect(forFrameRect: window.frame).size
                NSWindow.removeFrame(usingName: legacy)
                model.showNotice("Перенос старого окна: \(Int(size.width)) × \(Int(size.height)) pt · \(abs(size.width - 1120) < 1 && abs(size.height - 760) < 1 ? "PASS" : "FAIL")", kind: .information)
            }
        }
    }
    #endif
    private func synchronizeWindows() {
        BudgetWindows.reopen = { openWindow(id: model.db == nil ? "access" : "workspace") }
        if model.db != nil {
            if role == .access { openWindow(id: "workspace") }
            else { dismissWindow(id: "access"); BudgetWindows.workspacePresented() }
        } else {
            if role == .workspace { openWindow(id: "access"); dismissWindow(id: "workspace") }
        }
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
                Picker("Экран QA", selection: $screen) { ForEach(screens, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                if screen == "Обновление" {
                    Picker("Состояние QA", selection: $updateState) {
                        ForEach(Array(InstallUpdateManager.appearanceStateTitles.enumerated()), id: \.offset) { index, title in Text(title).tag(index) }
                    }.pickerStyle(.menu)
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
