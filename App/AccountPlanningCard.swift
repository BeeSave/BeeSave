import SwiftUI
import BudgetCore
import BudgetPresentation

struct AccountPlanningCard: View {
    @EnvironmentObject var model: AppModel; var account: Account; var db: Database
    var body: some View { VStack(alignment:.leading,spacing:14) {
        HStack(alignment:.top) { Image(systemName:account.kind.icon).beeFont(.title2).foregroundStyle(BeeStyle.positive); VStack(alignment:.leading,spacing:4) { Text(account.name).beeFont(.headline).fixedSize(horizontal:false,vertical:true); Text(account.kind.title).beeFont(.caption).foregroundStyle(BeeStyle.muted) }; Spacer(); Menu { if !account.archived && account.kind == .ordinary { Button("Расход") { model.newOperation(.expense,account:account.id) }; Button("Доход") { model.newOperation(.income,account:account.id) }; Button("Перевод") { model.newOperation(.transfer,account:account.id) } }; Button("Изменить") { model.sheet = SheetRoute(kind:.account,entityID:account.id) }; Button("Сверить остаток") { model.sheet = SheetRoute(kind:.reconciliation,entityID:account.id) }; Button(account.archived ? "Вернуть из архива" : "Архивировать") { model.perform { db in var copy = account; copy.archived.toggle(); try Ledger.saveAccount(copy,in:&db) } } } label: { Image(systemName:"ellipsis") } }
        if let balance = try? db.balance(account.id) {
        Text(BeeFormat.money(balance,currency:account.currency)).beeFont(.title2.bold()).monospacedDigit().fixedSize(horizontal:false,vertical:true).foregroundStyle(balance < 0 ? BeeStyle.negative : .primary)
        if account.kind.isDebt { Text("Долг и собственные средства учитываются отдельно от кредитного лимита").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
        if account.currency != db.settings.baseCurrency { if let rate = try? Reports.resolvedRate(from:account.currency,to:db.settings.baseCurrency,rates:db.rates,on:.today),let value = try? Money.convert(balance,from:account.currency,to:db.settings.baseCurrency,rate:rate.value) { Text("Оценка: " + BeeFormat.money(value,currency:db.settings.baseCurrency) + (rate.date.map { " · курс " + $0.rawValue } ?? "")).beeFont(.caption).foregroundStyle(BeeStyle.muted) } else { Text("Нет курса для оценки в " + db.settings.baseCurrency).beeFont(.caption).foregroundStyle(BeeStyle.warning) } }
        } else { Text("Остаток не рассчитан: проверьте данные счёта").foregroundStyle(BeeStyle.warning) }
        if let contract = db.contract(for:account.id),let end = contract.end { Text("Срок: " + CalendarDays.label(end,full:true)).beeFont(.caption).foregroundStyle(BeeStyle.muted) }
        Button("Открыть счёт",systemImage:"arrow.right") { model.openHistory(account.id) }.buttonStyle(BeeRowStyle())
    }.frame(maxWidth:.infinity,alignment:.leading).beeCard().accessibilityElement(children:.contain) }
}
