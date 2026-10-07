import SwiftUI
import BudgetCore
import BudgetPresentation

enum FinancialAccountSection: String, CaseIterable, Identifiable {
    case money = "Деньги", deposit = "Депозиты", credit = "Кредитные карты и кредиты", mortgage = "Ипотека"
    var id: Self { self }
    func includes(_ kind: AccountKind) -> Bool {
        switch self { case .money: kind == .ordinary; case .deposit: kind == .deposit; case .credit: kind == .revolvingCredit || kind == .termLoan; case .mortgage: kind == .mortgage }
    }
}

struct FinancialAccountRow: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var account: Account
    var db: Database
    var body: some View {
        let balance = (try? db.balance(account.id)) ?? 0
        HStack(alignment: .top, spacing: 14) {
            BankMark(bankID: account.bankID, fallback: account.archived ? "archivebox" : account.kind.icon).frame(width: 34).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Button(account.name) { model.openHistory(account.id) }.buttonStyle(BeeRowStyle()).beeFont(.headline)
                Text(account.kind.title + " · " + account.currency + (account.archived ? " · архив" : "")).beeFont(.caption).foregroundStyle(BeeStyle.muted)
                if let bank = db.financialBankName(account.bankID) { Text(bank).beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                ForEach(summary, id: \.self) { Text($0).beeFont(.caption).foregroundStyle(BeeStyle.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Text((account.kind.isDebt && balance < 0 ? "Долг: " : "") + BeeFormat.money(account.kind.isDebt && balance < 0 ? -balance : balance, currency: account.currency)).beeFont(.title3).monospacedDigit().foregroundStyle(balance < 0 ? BeeStyle.negative : BeeStyle.text)
                Button("История", systemImage: "chevron.right") { model.openHistory(account.id) }
            }
            Menu {
                Button("Изменить") { model.sheet = SheetRoute(kind: .account, entityID: account.id) }
                Button("Сверить остаток") { model.sheet = SheetRoute(kind: .reconciliation, entityID: account.id) }.disabled(account.archived)
                Button(account.archived ? "Вернуть из архива" : "Архивировать") {
                    if account.archived || confirmDeletion(account.name, consequence: "История и остаток сохранятся. Новые операции будут недоступны.") { model.perform { db in var copy = account; copy.archived.toggle(); try Ledger.saveAccount(copy, in: &db) } }
                }
                Button("Удалить", role: .destructive) { if confirmDeletion(account.name, consequence: "Удаляется пустой счёт без ссылок. Для счёта с историей используйте архив.") { model.perform { try Ledger.deleteAccount(account.id, in: &$0) } } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
        }.padding(.vertical, 14).tint(BeeStyle.text)
    }
    private var summary: [String] {
        guard let contract = db.contract(for: account.id) else { return [] }
        var lines: [String] = []
        let terms = contract.terms(on: .today)
        if account.kind == .deposit {
            lines.append("Ставка: " + rate(terms) + " · окончание: " + (contract.end.map { CalendarDays.label($0) } ?? "Уточнить"))
        }
        if model.financialBusy { return lines + ["Пересчёт графика…"] }
        if let debt = model.financialDebts[account.id] {
            if account.kind == .revolvingCredit {
                lines.append("Лимит: " + money(debt.limit) + " · доступно: " + money(debt.available))
            } else { lines.append("Основной долг: " + money(debt.amount(.principal)) + (debt.amount(.unallocated) > 0 ? " · состав уточнить" : "")) }
        }
        let rows = (model.financialEvents[contract.id] ?? []).filter { !$0.isFulfilled }.sorted { $0.date < $1.date }
        if account.kind == .deposit {
            let interest = rows.filter { $0.kind == .depositInterest }
            if !interest.isEmpty {
                let total = try? interest.reduce(Int64(0)) { total, row in guard let amount = row.remaining, row.accuracy != .incomplete else { throw BudgetError.invalid("Неполный прогноз") }; return try Money.add(total, amount) }
                lines.append("Ожидаемые проценты до налога: " + money(total))
            }
        } else {
            if let payment = rows.first(where: { $0.kind == .loanPayment || $0.kind == .minimumPayment }) { lines.append((payment.date < .today ? "Просроченный платёж: " : "Ближайший платёж: ") + money(payment.remaining) + " · " + CalendarDays.label(payment.date)) }
            if let grace = rows.first(where: { $0.kind == .gracePayment }) { lines.append("Для льготы: " + money(grace.remaining) + " · до " + CalendarDays.label(grace.date)) }
        }
        if let error = model.financialErrors[contract.id] { lines.append(error) }
        return lines
    }
    private func money(_ amount: Int64?) -> String { amount.map { BeeFormat.money($0, currency: account.currency) } ?? "Уточнить" }
    private func rate(_ terms: FinancialTerms?) -> String { guard let terms, let rate = try? terms.rate() else { return "Уточнить" }; return NSDecimalNumber(decimal: rate * 100).stringValue + "%" + (terms.scenarioRate ? " · сценарий" : "") }
}
