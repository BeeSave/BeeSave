import SwiftUI
import AppKit
import BudgetCore
import BudgetPresentation

struct AppUpdateCommands: Commands {
    @ObservedObject var updater: InstallUpdateManager
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Проверить обновление") { openWindow(id: "app-update"); updater.check() }
                .disabled(updater.state.isBusy)
        }
    }
}

struct AppUpdateView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @Environment(\.beeAppearance) private var appearance
    @ObservedObject var updater: InstallUpdateManager
    @State private var keepCurrent = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Label("Обновление BeeSave", systemImage: "arrow.down.circle").beeFont(.title2.bold())
            Text("Установлена версия \(updater.version), сборка \(updater.build)").foregroundStyle(BeeStyle.muted)
            Group {
                switch updater.state {
                case .idle: Text("Проверьте наличие новой версии в GitHub.")
                case .checking, .checkingFeed: ProgressView("Проверяем обновление…")
                case .current: Label("У вас актуальная версия BeeSave.", systemImage: "checkmark.circle")
                case .noRelease: Text("Опубликованных стабильных выпусков пока нет.")
                case .available(let release):
                    Text("Доступна версия \(release.manifest.version), сборка \(release.manifest.build).")
                    Text("BeeSave скачает и проверит обновление, установит его и перезапустится. Бюджет, настройки и резервные копии сохранятся. На время обновления новые записи будут приостановлены.").foregroundStyle(BeeStyle.muted)
                    Button("Обновить и перезапустить") { updater.install() }.buttonStyle(BeePrimaryStyle())
                case .incompatible(let manifest): Text("Версия \(manifest.version) требует macOS \(manifest.minimumMacOS) и процессор \(manifest.architecture). Этот Mac не поддерживается.")
                case .downloading(let progress):
                    if let progress { ProgressView("Скачиваем обновление…", value: progress) }
                    else { ProgressView("Скачиваем обновление…") }
                case .extracting(let progress):
                    if let progress { ProgressView("Проверяем и подготавливаем приложение…", value: progress) }
                    else { ProgressView("Проверяем и подготавливаем приложение…") }
                case .waiting(let message):
                    Label("Обновление готово к установке", systemImage: "checkmark.shield")
                    Text(message)
                    Button("Установить и перезапустить") { updater.finishPreparation() }.buttonStyle(BeePrimaryStyle())
                case .preparing: ProgressView("Сохраняем защитную копию перед перезапуском…")
                case .installing: ProgressView("Устанавливаем обновление. BeeSave перезапустится…")
                case .cancelling: ProgressView("Завершаем отмену обновления…")
                case .cancelled: Text("Обновление отменено. Установка при закрытии BeeSave не запланирована.")
                case .failed(let message):
                    if message != updater.budgetVerificationError { Text(message).foregroundStyle(BeeStyle.negative) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let message = updater.budgetVerificationError {
                Text(message).foregroundStyle(BeeStyle.negative)
            }
            if let folder = updater.recoveryFolder {
                Button("Показать защитную папку") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            if updater.canKeepCurrentBudget {
                Button("Продолжить с текущим бюджетом…") { keepCurrent = true }
            }
            Spacer(minLength: 0)
            Divider()
            Text("Проверка выполняется по вашей команде. Финансовые данные в GitHub не передаются.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            HStack {
                switch updater.state {
                case .installing, .cancelling: EmptyView()
                case .checking, .checkingFeed, .downloading, .extracting, .preparing, .waiting: Button("Отмена") { updater.cancel() }
                default: Button("Проверить ещё раз") { updater.check() }
                }
                Spacer()
                Link("Что нового", destination: URL(string: "https://github.com/BeeSave/BeeSave/releases/latest")!)
            }
        }.padding(24) }.frame(width: min(740, 550 * appearance.scale), height: min(740, 440 * appearance.scale)).foregroundStyle(BeeStyle.text).background(BeeStyle.surface).tint(BeeStyle.controlAccent).beeAppearance()
        .onDisappear { updater.dismiss() }
        .confirmationDialog("Продолжить с текущим бюджетом?", isPresented: $keepCurrent) {
            Button("Продолжить") { updater.keepCurrentBudget() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Проверка снимка не завершена. Текущие записи останутся на месте; прежнее приложение и защитная копия сохранятся для ручного возврата.") }
    }
}
