#if DEBUG && UI_SMOKE
import AppKit
import BudgetCore

extension AppModel {
    /// Measures the real fixture window, including a flush of its pending layout and drawing.
    func measureFixturePresentation(_ target: SectionID) {
        guard previewScenario == .financialVolume, !financialBusy, sheet == nil else { return }
        let began = ProcessInfo.processInfo.systemUptime
        historyAccount = nil; section = target
        finishFixtureMeasurement("Открытие «\(target.rawValue)»", began: began, threshold: 2)
    }
    func measureFixturePayment() {
        guard previewScenario == .financialVolume, !financialBusy,
              let db, let contract = db.financeData.contracts.first(where: { $0.kind == .termLoan }),
              let source = db.accounts.first(where: { $0.kind == .deposit }) else { return }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            try commit { database in
                try FinancialLedger.payDebt(contractID: contract.id, from: source.id, amount: 3_000_000, interestCharge: 2_000_000, date: .today, in: &database)
            }
            let saved = ProcessInfo.processInfo.systemUptime - began
            finishFixtureMeasurement("Сохранение платежа и UI", began: began, threshold: 1, saved: saved)
        } catch { self.error = error.localizedDescription }
    }
    private func finishFixtureMeasurement(_ label: String, began: TimeInterval, threshold: Double, saved: TimeInterval? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            guard let self else { return }
            NSApp.mainWindow?.contentView?.layoutSubtreeIfNeeded()
            NSApp.mainWindow?.contentView?.displayIfNeeded()
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let detail = saved.map { " Запись: \(String(format: "%.3f", $0)) с; показ: \(String(format: "%.3f", elapsed - $0)) с." } ?? ""
            self.notice = "\(label): \(String(format: "%.3f", elapsed)) с · порог \(threshold) с · \(elapsed <= threshold ? "PASS" : "FAIL").\(detail) 100 000 операций / 100 счетов / 100 договоров."
        }
    }
}
#endif
