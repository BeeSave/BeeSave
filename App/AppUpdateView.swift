import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BudgetCore

struct AppUpdateCommands: Commands {
    @ObservedObject var updater: AppUpdateManager
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Проверить обновление") {
                openWindow(id: "app-update")
                updater.check()
            }.disabled(updater.state.isBusy)
        }
    }
}

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdateManager
    @State private var savedArchive: URL?
    @State private var saveError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Обновление BeeSave", systemImage: "arrow.down.circle").font(.title2.bold())
            Text("Установлена версия \(updater.version), сборка \(updater.build)").foregroundStyle(BeeStyle.muted)
            Group {
                switch updater.state {
                case .idle: Text("Проверьте наличие новой версии в GitHub.")
                case .checking: ProgressView("Проверяем обновления…")
                case .current: Label("У вас актуальная версия BeeSave.", systemImage: "checkmark.circle")
                case .noRelease: Text("Опубликованных стабильных выпусков пока нет.")
                case .available(let manifest):
                    Text("Доступна версия \(manifest.version), сборка \(manifest.build).")
                    Text("Архив будет скачан из BeeSave/BeeSave и проверен перед сохранением.").foregroundStyle(BeeStyle.muted)
                    Button("Скачать обновление") { savedArchive = nil; saveError = nil; updater.download() }.buttonStyle(BeePrimaryStyle())
                case .incompatible(let manifest):
                    Text("Версия \(manifest.version) требует macOS \(manifest.minimumMacOS) и процессор \(manifest.architecture). Этот Mac не поддерживается.")
                case .downloading(_, let progress):
                    if let progress { ProgressView("Скачиваем обновление…", value: progress) }
                    else { ProgressView("Скачиваем обновление…") }
                case .downloaded(let manifest, let archive):
                    Label("Архив версии \(manifest.version) проверен.", systemImage: "checkmark.shield")
                    Text("Сохраните архив, распакуйте его, завершите BeeSave и замените прежнее приложение в Finder. Затем откройте новую версию. База и резервные копии останутся на месте.")
                    Text("Этот выпуск имеет локальную подпись и устанавливается вручную.").font(.caption).foregroundStyle(BeeStyle.muted)
                    if let savedArchive {
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedArchive]) }
                    } else {
                        Button("Сохранить архив…") { save(archive) }.buttonStyle(BeePrimaryStyle())
                    }
                case .cancelled: Text("Проверка или загрузка отменена.")
                case .failed(let message): Text(message).foregroundStyle(BeeStyle.negative)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let saveError { Text(saveError).foregroundStyle(BeeStyle.negative) }
            Spacer(minLength: 0)
            Divider()
            Text("Проверка выполняется по вашей команде. Финансовые данные в GitHub не передаются.").font(.caption).foregroundStyle(BeeStyle.muted)
            HStack {
                if updater.state.isBusy { Button("Отмена") { updater.cancel() } }
                else { Button("Проверить ещё раз") { savedArchive = nil; saveError = nil; updater.check() } }
                Spacer()
                Link("Что нового", destination: URL(string: "https://github.com/BeeSave/BeeSave/releases/latest")!)
            }
        }.padding(24).frame(width: 550, height: 440).foregroundStyle(BeeStyle.text).background(BeeStyle.surface).tint(BeeStyle.honey)
        .onDisappear { updater.dismiss() }
    }
    private func save(_ archive: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = archive.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try Data(contentsOf: archive, options: .mappedIfSafe).write(to: destination, options: .atomic)
            savedArchive = destination; saveError = nil
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { saveError = "Архив не сохранён. Проверьте свободное место и выберите доступную папку." }
    }
}
