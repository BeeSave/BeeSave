import AppKit
import BudgetCore
import Combine
import Security
import Sparkle

enum InstallUpdateState: Equatable {
    case idle, checking, current, noRelease, available(InstallUpdateRelease), incompatible(AppUpdateManifest)
    case checkingFeed, downloading(Double?), extracting(Double?), waiting(String), preparing, installing, cancelling, cancelled, failed(String)
    var isBusy: Bool {
        switch self { case .checking, .checkingFeed, .downloading, .extracting, .preparing, .installing, .cancelling: true; default: false }
    }
}

#if DEBUG && UI_SMOKE
struct AppearanceUpdateTransport: AppUpdateTransport {
    func data(from url: URL, limit: Int) async throws -> Data {
        let prefix = "https://github.com/BeeSave/BeeSave/releases/download/v2.0.0/"
        if url == AppUpdateURLs.latest {
            let assets = ["latest.json", "appcast.xml", "BeeSave-macos-arm64.zip", "BeeSave-macos-arm64.zip.sha256", "BeeSave-macos-arm64.dmg", "BeeSave-macos-arm64.dmg.sha256"].map { ["name": $0, "browser_download_url": prefix + $0] }
            return try JSONSerialization.data(withJSONObject: ["tag_name": "v2.0.0", "draft": false, "prerelease": false, "assets": assets])
        }
        return try JSONSerialization.data(withJSONObject: ["schema_version": 1, "version": "2.0.0", "build": 99, "minimum_macos": "26.0", "architecture": "arm64", "repository": "BeeSave/BeeSave", "tag": "v2.0.0", "asset_url": prefix + "BeeSave-macos-arm64.zip", "sha256": String(repeating: "0", count: 64)])
    }
    func download(from url: URL, to file: URL, limit: Int, progress: @escaping @Sendable (Double?) -> Void) async throws { throw CancellationError() }
}

extension InstallUpdateManager {
    static let appearanceStateTitles = ["Ожидание", "Проверка", "Актуальная", "Нет выпусков", "Доступно", "Несовместимо", "Проверка ленты", "Загрузка 45%", "Загрузка", "Распаковка 70%", "Распаковка", "Ожидание формы", "Подготовка", "Установка", "Отмена", "Отменено", "Ошибка"]
    func previewAppearanceState(_ index: Int) async {
        // An unattached manager cannot prepare or install an application.
        guard model == nil else { return }
        do {
            let result = try await client.checkInstall(version: "1.0.0", build: 1, macOS: "27.0", architecture: "arm64")
            guard case .available(let release) = result else { return }
            let states: [InstallUpdateState] = [.idle, .checking, .current, .noRelease, .available(release), .incompatible(release.manifest), .checkingFeed, .downloading(0.45), .downloading(nil), .extracting(0.7), .extracting(nil), .waiting("Завершите редактирование открытой формы, затем повторите установку. Несохранённые изменения останутся на месте."), .preparing, .installing, .cancelling, .cancelled, .failed("Обновление не установлено. Прежнее приложение и бюджет сохранены. Не удалось проверить подпись загруженного приложения; повторите загрузку.")]
            guard states.indices.contains(index) else { return }; state = states[index]
        } catch { state = .failed(error.localizedDescription) }
    }
}
#endif

@MainActor final class InstallUpdateManager: NSObject, ObservableObject {
    @Published private(set) var state: InstallUpdateState = .idle
    @Published private(set) var recoveryFolder: URL?
    @Published private(set) var budgetVerificationError: String?
    let version: String
    let build: Int
    private weak var model: AppModel?
    private let client: AppUpdateClient
    private var checkTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var cycle = UUID()
    private var selected: InstallUpdateRelease?
    private var driver: InstallUpdateDriver?
    private var sparkle: SPUUpdater?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var safetyRecord: UpdateSafetyRecord?
    private var cancelRequested = false
    private var handedOff = false
    private var pending = [UpdateSafetyRecord]()
    init(client: AppUpdateClient = AppUpdateClient(), version: String? = nil, build: Int? = nil) {
        self.client = client
        self.version = version ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        self.build = build ?? (Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0)
        super.init()
    }
    private var safety: UpdateSafetyStore? { model.map { UpdateSafetyStore(directory: $0.root.appendingPathComponent("Updates.noindex")) } }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.confirmUpdatedBudget = { [weak self] in self?.confirmFirstLaunch() }
        do {
            pending = try safety?.pending() ?? []
            model.updateVerificationPending = pending.contains { ($0.phase == .handedOff || $0.phase == .prepared) && $0.version == version && $0.build == build }
            if !pending.isEmpty { recoveryFolder = safety?.directory }
            if !model.vault.exists || model.db != nil { confirmFirstLaunch() }
        } catch {
            model.updateVerificationPending = true
            let message = "Не удалось проверить запись обновления. Защитные файлы сохранены: " + error.localizedDescription
            budgetVerificationError = message; state = .failed(message)
            recoveryFolder = safety?.directory
        }
    }

    private func confirmFirstLaunch() {
        guard let model, let safety else { return }
        let matches = pending.filter { ($0.phase == .handedOff || $0.phase == .prepared) && $0.version == version && $0.build == build }
        do {
            for record in matches {
                // The actual replacement can have completed after a forced exit
                // before the old process recorded its final handoff.
                var launched = record; launched.phase = .handedOff
                try safety.removeVerified(launched, vault: model.vault, version: version, build: build, application: Bundle.main.bundleURL)
                pending.removeAll { $0.id == record.id }
            }
            model.updateVerificationPending = false
            budgetVerificationError = nil
            if !matches.isEmpty { model.notice = "BeeSave обновлён до версии \(version). Бюджет проверен и сохранён." }
            recoveryFolder = pending.isEmpty ? nil : safety.directory
        } catch {
            // Do not overwrite current data, delete the previous app, or start a
            // background write before this discrepancy has been reviewed.
            model.updateVerificationPending = true
            let message = "Проверка сохранности бюджета не завершена. Исходный бюджет и прежнее приложение доступны в защитной папке. " + error.localizedDescription
            budgetVerificationError = message; state = .failed(message)
            recoveryFolder = safety.directory
        }
    }

    var canKeepCurrentBudget: Bool {
        guard let model, model.updateVerificationPending, let database = model.vault.db else { return false }
        return pending.contains { $0.version == version && $0.build == build && $0.databaseID == database.id && $0.applicationPath == Bundle.main.bundleURL.standardizedFileURL.path && $0.vaultPath == model.vault.url.standardizedFileURL.path }
    }
    func keepCurrentBudget() {
        guard canKeepCurrentBudget, let model, let safety else { return }
        do {
            for index in pending.indices where pending[index].version == version && pending[index].build == build {
                pending[index].phase = .retained; try safety.write(pending[index])
            }
            model.updateVerificationPending = false
            budgetVerificationError = nil
            model.notice = "Вы выбрали текущий бюджет. Защитная папка сохранена; автоматический возврат данных не выполнялся."
        } catch { state = .failed(error.localizedDescription) }
    }

    func check() {
        guard !state.isBusy, sparkle == nil, prepareTask == nil else { return }
        cycle = UUID(); let id = cycle
        checkTask?.cancel(); state = .checking
        let os = ProcessInfo.processInfo.operatingSystemVersion
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.checkInstall(version: version, build: build, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: "arm64")
                try Task.checkCancellation(); guard cycle == id else { return }
                switch result {
                case .current: state = .current
                case .noRelease: state = .noRelease
                case .available(let release): selected = release; state = .available(release)
                case .incompatible(let manifest): state = .incompatible(manifest)
                }
            } catch is CancellationError { if cycle == id { state = .cancelled } }
              catch { if cycle == id { state = .failed(error.localizedDescription) } }
            if cycle == id { checkTask = nil }
        }
    }

    func install() {
        guard case .available(let release) = state, sparkle == nil, let model else { return }
        if let blocker = model.updateBlocker { selected = release; state = .waiting(blocker); return }
        cancelRequested = false; handedOff = false; cycle = UUID(); selected = release
        model.updateFrozen = true; state = .preparing
        prepareTask = Task { [weak self] in
            guard let self else { return }
            defer { prepareTask = nil }
            do {
            try validateInstallationLocation()
            guard !model.updateVerificationPending else { throw BudgetError.storage("Сначала завершите проверку предыдущего обновления.") }
            guard let safety else { throw BudgetError.storage("Защитная папка недоступна.") }
            let oldApp = Bundle.main.bundleURL
            let enumerator = FileManager.default.enumerator(at: oldApp, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
            var oldSize: Int64 = 0
            while let file = enumerator?.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                if values.isSymbolicLink != true { oldSize += Int64(values.fileSize ?? 0) }
            }
            let vaultSize = Int64((try? model.vault.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let free = try model.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            guard let free, free > oldSize * 2 + vaultSize * 2 + Int64(AppUpdateClient.archiveLimit) else { throw BudgetError.storage("Недостаточно места для безопасного обновления и защитной копии. Освободите место на диске.") }
            let record = try safety.prepare(vault: model.vault, version: release.manifest.version, build: release.manifest.build, application: oldApp)
            safetyRecord = record; recoveryFolder = safety.directory
            let previous = safety.previousApplication(for: record)
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: oldApp, to: previous) }.value
            if cancelRequested {
                try safety.cancelPrepared(record); safetyRecord = nil; model.updateFrozen = false; state = .cancelled; return
            }
            var previousCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(previous as CFURL, [], &previousCode) == errSecSuccess, let previousCode,
                  SecStaticCodeCheckValidity(previousCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw BudgetError.corrupt }
            guard model.updateBlocker == nil else { throw BudgetError.storage("Завершите открытые действия и повторите установку.") }
            let delegate = InstallUpdateDriver(owner: self, cycle: cycle)
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: delegate, delegate: delegate)
            driver = delegate; sparkle = updater; state = .checkingFeed
            try updater.start()
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            updater.sendsSystemProfile = false
            updater.checkForUpdates()
            } catch { sparkle = nil; driver = nil; model.updateFrozen = false; state = .failed(error.localizedDescription) }
        }
    }

    private func validateInstallationLocation() throws {
        let app = Bundle.main.bundleURL.standardizedFileURL
        guard !app.path.hasPrefix("/Volumes/"), !app.path.contains("/AppTranslocation/"),
              app.lastPathComponent == "BeeSave.app", Bundle.main.bundleIdentifier == "com.mubudget.app" else {
            throw BudgetError.storage("Для обновления скопируйте BeeSave в папку «Программы», закройте это приложение и откройте установленную копию.")
        }
        let parent = try app.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard parent.volumeIsReadOnly != true else { throw BudgetError.storage("Приложение находится на диске только для чтения. Перенесите BeeSave в папку «Программы».") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw BudgetError.storage("Подпись установленного приложения не прошла проверку. Загрузите официальный DMG BeeSave.")
        }
    }

    fileprivate func active(_ id: UUID) -> Bool { cycle == id && sparkle != nil }
    fileprivate func feed(_ id: UUID) -> String? { active(id) ? selected?.feedURL.absoluteString : nil }
    fileprivate func validate(_ item: SUAppcastItem, cycle id: UUID) throws {
        guard active(id), !cancelRequested, let release = selected,
              item.fileURL == release.archiveURL, item.versionString == String(release.manifest.build),
              item.displayVersionString == release.manifest.version,
              item.minimumSystemVersion == release.manifest.minimumMacOS,
              item.signingValidationStatus == .succeeded,
              !item.isDeltaUpdate, item.deltaUpdates?.isEmpty != false,
              !item.isInformationOnlyUpdate, item.contentLength > 0,
              item.contentLength <= AppUpdateClient.archiveLimit else { throw AppUpdateError.invalidMetadata }
    }
    fileprivate func bestItem(_ appcast: SUAppcast, cycle id: UUID) -> SUAppcastItem? {
        guard appcast.items.count == 1, let item = appcast.items.first, (try? validate(item, cycle: id)) != nil else { return nil }
        return item
    }
    fileprivate func progress(_ value: InstallUpdateState, cycle id: UUID) { if active(id), !cancelRequested { state = value } }
    fileprivate func ready(_ reply: @escaping (SPUUserUpdateChoice) -> Void, cycle id: UUID) {
        guard active(id), !cancelRequested else { reply(.skip); return }
        readyReply = reply
        finishPreparation()
    }

    func finishPreparation() {
        if sparkle == nil, case .waiting = state, let selected {
            state = .available(selected); install(); return
        }
        guard readyReply != nil, prepareTask == nil, !cancelRequested, let model, let safety, let release = selected else { return }
        if let blocker = model.updateBlocker { state = .waiting(blocker); return }
        model.updateFrozen = true
        model.rateTask?.cancel()
        state = .preparing
        prepareTask = Task { [weak self] in
            guard let self else { return }
            defer { prepareTask = nil }
            do {
                try validateInstallationLocation()
                guard let record = safetyRecord, record.phase == .prepared,
                      record.version == release.manifest.version, record.build == release.manifest.build else { throw BudgetError.corrupt }
                try model.vault.acquire()
                if cancelRequested { try safety.cancelPrepared(record); safetyRecord = nil; model.updateFrozen = false; state = .cancelled; return }
                guard model.updateBlocker == nil else { throw BudgetError.storage("Завершите открытые действия и повторите установку.") }
                // Recheck unchanged ciphertext immediately before handing control
                // to Sparkle. No budget or key is sent to its installer service.
                if record.snapshotSHA256 != nil {
                    guard try Data(contentsOf: model.vault.url) == Data(contentsOf: safety.snapshot(for: record)) else { throw BudgetError.corrupt }
                }
                var handed = record; handed.phase = .handedOff
                try safety.write(handed); safetyRecord = handed; handedOff = true
                let reply = readyReply; readyReply = nil
                state = .installing; reply?(.install)
            } catch {
                let reply = readyReply; readyReply = nil; reply?(.skip)
                model.updateFrozen = false
                state = .failed("Обновление не установлено. Прежнее приложение и бюджет сохранены. " + error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard !handedOff else { return }
        cancelRequested = true
        if checkTask != nil { cycle = UUID(); checkTask?.cancel(); checkTask = nil; state = .cancelled; return }
        guard sparkle != nil else { state = .cancelled; return }
        state = .cancelling
        if let readyReply { self.readyReply = nil; readyReply(.skip) }
        else { driver?.cancelCurrentPhase() }
        // During extraction Sparkle has no public cancellation callback. Keep the
        // process alive and answer Skip when it reaches its ready callback.
    }
    func dismiss() { if !handedOff, sparkle != nil || checkTask != nil || prepareTask != nil { cancel() } }
    fileprivate func finished(cycle id: UUID) {
        guard active(id), !handedOff else { return }
        sparkle = nil; driver = nil; readyReply = nil
        if prepareTask == nil {
            model?.updateFrozen = false
            if cancelRequested {
                do { if let safetyRecord, let safety { try safety.cancelPrepared(safetyRecord); self.safetyRecord = nil }; state = .cancelled }
                catch { state = .failed("Обновление отменено, защитная папка сохранена. " + error.localizedDescription) }
            }
        }
    }
    fileprivate func failed(_ error: Error, cycle id: UUID) {
        guard active(id), !handedOff else { return }
        if !cancelRequested { state = .failed("Обновление не установлено. Прежняя версия и бюджет сохранены. " + error.localizedDescription) }
    }
    func canTerminate() -> Bool {
        if handedOff { return model?.updateBlocker == nil }
        if sparkle != nil || prepareTask != nil {
            cancel(); model?.error = "Отмена обновления ещё завершается. После её окончания можно закрыть BeeSave."; return false
        }
        if let blocker = model?.updateBlocker { model?.error = blocker; return false }
        checkTask?.cancel()
        return true
    }
}

/// One adapter per cycle prevents late callbacks from controlling a newer run.
@MainActor private final class InstallUpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    weak var owner: InstallUpdateManager?
    let cycle: UUID
    private var cancellation: (() -> Void)?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    init(owner: InstallUpdateManager, cycle: UUID) { self.owner = owner; self.cycle = cycle }
    func cancelCurrentPhase() { let action = cancellation; cancellation = nil; action?() }
    func feedURLString(for updater: SPUUpdater) -> String? { owner?.feed(cycle) }
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] { [] }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? { owner?.bestItem(appcast, cycle: cycle) }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let owner else { throw AppUpdateError.invalidMetadata }; try owner.validate(item, cycle: cycle)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { owner?.failed(error, cycle: cycle) }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        do { guard let owner else { reply(.skip); return }; try owner.validate(appcastItem, cycle: cycle); cancellation = nil; reply(.install) }
        catch { owner?.failed(error, cycle: cycle); reply(.skip) }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { owner?.failed(error, cycle: cycle); acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { owner?.failed(error, cycle: cycle); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { self.cancellation = cancellation; received = 0; expected = 0; owner?.progress(.downloading(nil), cycle: cycle) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) { received += length; owner?.progress(.downloading(expected > 0 ? min(Double(received) / Double(expected), 1) : nil), cycle: cycle) }
    func showDownloadDidStartExtractingUpdate() { cancellation = nil; owner?.progress(.extracting(nil), cycle: cycle) }
    func showExtractionReceivedProgress(_ progress: Double) { owner?.progress(.extracting(progress), cycle: cycle) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { cancellation = nil; owner?.ready(reply, cycle: cycle) ?? reply(.skip) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { owner?.progress(.installing, cycle: cycle) }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { cancellation = nil; owner?.finished(cycle: cycle) }
}
