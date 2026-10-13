import SwiftUI
import BudgetCore
import BudgetPresentation

struct UpcomingPaymentsCard: View {
    @EnvironmentObject var model: AppModel; @State private var days = 30; @State private var all = false; @State private var from = Day.today; @State private var through = Day.today.adding(30)
    private var rows: [PlannedOccurrence] { model.planningRows.filter { row in guard let db = model.db else { return false }; return !row.income && row.purpose != .living && PlanningEngine.affectsPersonal(row,db:db) && (row.date < .today || (row.date >= (days == -1 ? from : .today) && row.date <= (days == -1 ? through : .today.adding(days)))) }.sorted { $0.date < $1.date } }
    private func total(_ items: [PlannedOccurrence]) -> (Int64,Int) {
        guard let db = model.db else { return (0,0) }; var sum: Int64 = 0,missing = 0
        for row in items { if row.incomplete == true { missing += 1 }; guard let amount = row.remaining,let value = try? PlanningEngine.converted(amount,currency:row.currency,to:db.settings.baseCurrency,db:db,date:row.date),let next = try? Money.add(sum,value) else { missing += 1; continue }; sum = next }; return (sum,missing)
    }
    var body: some View { if let db = model.db { VStack(alignment:.leading,spacing:14) {
        HStack { Text("Предстоящие выплаты").beeFont(.headline); Spacer(); BeePicker("Период выплат",selection:$days) { Text("7 дней").tag(7); Text("30 дней").tag(30); Text("3 месяца").tag(90); Text("Свой период").tag(-1) }.labelsHidden().frame(minWidth:120,maxWidth:180) }
        if days == -1 { HStack { PlanningDateField(title:"С",day:$from); PlanningDateField(title:"По",day:$through) } }
        let value = total(rows)
        HStack(alignment:.firstTextBaseline) { Text(BeeFormat.money(value.0,currency:db.settings.baseCurrency)).beeFont(.title2.bold()); Text("\(rows.count) выплат").beeFont(.caption).foregroundStyle(BeeStyle.muted); Spacer() }
        let overdue = rows.filter { $0.date < .today }
        if !overdue.isEmpty { let sum = total(overdue); Text("Просрочено: " + BeeFormat.money(sum.0,currency:db.settings.baseCurrency) + " · \(overdue.count) выплат" + (sum.1 > 0 ? " · неполная оценка" : "")).beeFont(.caption).foregroundStyle(BeeStyle.negative) }
        if let nearest = rows.first(where:{ $0.date >= .today }) { Text("Ближайшая: " + CalendarDays.label(nearest.date,full:true) + " · " + nearest.title).beeFont(.caption).foregroundStyle(BeeStyle.muted) }
        if value.1 > 0 { Label("Неполный итог: \(value.1) выплат требуют суммы или курса",systemImage:"exclamationmark.triangle").beeFont(.caption).foregroundStyle(BeeStyle.warning) }
        if let p = model.planningProjection,let last = p.points.last(where:{ $0.event.date <= (days == -1 ? through : .today.adding(days)) }) { Text((p.complete ? "После выплат и плановых поступлений: " : "Неполный прогноз остатка: ") + BeeFormat.money(last.balance,currency:p.currency)).beeFont(.caption).foregroundStyle(last.belowReserve ? BeeStyle.negative : BeeStyle.muted) }
        if rows.isEmpty { Text(model.planningBusy ? "Пересчёт плана…" : "В этом периоде нет запланированных выплат").foregroundStyle(BeeStyle.muted) }
        ForEach(Array(all ? rows : Array(rows.prefix(5)))) { row in Button { model.openPlanningSource(row) } label: { HStack(alignment:.top,spacing:12) {
            VStack(alignment:.leading,spacing:3) { Text(row.date < .today ? "Просрочено" : row.date == .today ? "Сегодня" : CalendarDays.label(row.date)).foregroundStyle(row.date < .today ? BeeStyle.negative : BeeStyle.muted); Text(row.title).beeFont(.subheadline).fixedSize(horizontal:false,vertical:true); Text(row.source == "finance" ? "По договору" : row.source == "project" ? "Проектный план" : row.source == "tax" ? "Налоговый расчёт" : row.certainty.title).beeFont(.caption).foregroundStyle(BeeStyle.muted); if let accountID = row.accountID,let account = db.accounts.first(where:{ $0.id == accountID }) { Text(account.name).beeFont(.caption).foregroundStyle(BeeStyle.muted) }; if let id = row.projectID,let project = db.projects.first(where:{ $0.id == id }) { Text(project.name).beeFont(.caption).foregroundStyle(BeeStyle.muted) } }
            Spacer(); Text(row.remaining.map { BeeFormat.money($0,currency:row.currency) } ?? "Уточните сумму").monospacedDigit(); Image(systemName:"chevron.right").foregroundStyle(BeeStyle.muted)
        } }.buttonStyle(BeeRowStyle()) }
        HStack { if rows.count > 5 { Button(all ? "Свернуть" : "Все выплаты (\(rows.count))") { all.toggle() } }; Spacer(); Button("Календарь") { model.section = .financialCalendar }; Button("Запланировать") { model.sheet = SheetRoute(kind:.planFlow) } }
        Text("Неоплаченные суммы; фактический остаток не списывается автоматически.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    }.beeCard() } }
}
struct UpcomingAttentionCard: View {
    @EnvironmentObject var model: AppModel; @State private var all = false
    var body: some View { VStack(alignment:.leading,spacing:14) {
        HStack { Text("Предстоящие события").beeFont(.headline); Spacer(); Button("Настроить",systemImage:"slider.horizontal.3") { model.sheet = SheetRoute(kind:.eventSettings) } }
        if model.planningAttention.isEmpty { Text(model.planningBusy ? "Проверяем сроки…" : "Событий, требующих действия, пока нет").foregroundStyle(BeeStyle.muted) }
        ForEach(Array(all ? model.planningAttention : Array(model.planningAttention.prefix(5)))) { event in VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.top) { Image(systemName:event.type == "deposit" ? "clock.arrow.circlepath" : event.priority == 0 ? "exclamationmark.triangle" : "calendar").foregroundStyle(event.priority == 0 ? BeeStyle.warning : BeeStyle.positive); VStack(alignment:.leading,spacing:4) { Text(event.title).beeFont(.headline); Text(event.reason).beeFont(.caption).foregroundStyle(BeeStyle.muted) }; Spacer(); Text(CalendarDays.label(event.date)).beeFont(.caption) }
            HStack { Button(event.action) { open(event) }.buttonStyle(BeeRowStyle()); Spacer(); Menu("Позже") { Button("Напомнить завтра") { update(event,until:.today.adding(1)) }; Button("Через неделю") { update(event,until:.today.adding(7)) }; Button("Скрыть это событие") { update(event,until:nil) }; Button("Не показывать этот источник") { guard var s = model.db?.planningData.eventSettings else { return }; s.sourceExclusions.append(event.sourceID.uuidString); model.changePlanning(.settings(s)) } } }
        }.padding(.vertical,6) }
        if model.planningAttention.count > 5 { Button(all ? "Свернуть" : "Все события (\(model.planningAttention.count))") { all.toggle() } }
    }.beeCard() }
    private func open(_ event: PlanningAttentionEvent) {
        if let row = event.occurrence { model.openPlanningSource(row) }
        else if event.type == "deposit",let contract = model.db?.financeData.contracts.first(where:{ $0.id == event.sourceID }) { model.openHistory(contract.accountID) }
        else { model.section = .planning }
    }
    private func update(_ event: PlanningAttentionEvent,until:Day?) { guard var settings = model.db?.planningData.eventSettings else { return }; if let until { settings.snoozed[event.id] = until } else { settings.hiddenKeys.append(event.id) }; model.changePlanning(.settings(settings)) }
}
