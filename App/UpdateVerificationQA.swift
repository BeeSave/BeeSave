#if DEBUG && UI_SMOKE && UPDATE_QA
import Foundation
import BudgetCore

extension AppModel {
    /// Only the isolated preview target can synthesize a first launch after update.
    func prepareUpdateMigrationQA() {
        do {
            try vault.transaction { $0.version = 1 }
            let safety = UpdateSafetyStore(directory: root.appendingPathComponent("Updates.noindex"))
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
            let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String)!
            var record = try safety.prepare(vault: vault, version: version, build: build, application: Bundle.main.bundleURL)
            record.phase = .handedOff; try safety.write(record)
            lock()
            notice = "Тест обновления · вымышленная база схемы 1"
        } catch { startupError = error.localizedDescription }
    }
}
#endif
