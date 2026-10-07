import SwiftUI
import BudgetCore
import BudgetPresentation

struct ExpensesView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            BeePicker("Расходы", selection: $model.showScheduledExpenses) { Text("Фактические").tag(false); Text("Запланированные").tag(true) }.beePickerStyle(.segmented).padding(.horizontal, 24).padding(.top, 18)
            if model.showScheduledExpenses { ScheduledPaymentsView() } else { OperationsView(kind: .expense) }
        }
    }
}
struct ScheduledPaymentsView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var status = "Предстоящие"
    @State private var from = ""; @State private var through = ""
    private func rows(_ db: Database, now: Date) -> [ScheduledPayment] {
        (db.financeData.scheduledPayments ?? []).filter { p in
            let state = try? ScheduledPayments.state(p, db: db, now: now)
            let first = try? Day(from), last = try? Day(through)
            return (status == "Все" || status == "Архив" && p.archived || !p.archived && (status == "Предстоящие" ? state != .paid && state != .cancelled : state?.title == status)) && (search.isEmpty || [p.title, p.comment, p.planName ?? "", p.contractReference, p.payee].contains { $0.localizedCaseInsensitiveContains(search) }) && (first == nil || p.dueOn >= first!) && (last == nil || p.dueOn <= last!)
        }.sorted { $0.dueOn == $1.dueOn ? $0.id.uuidString < $1.id.uuidString : $0.dueOn < $1.dueOn }
    }
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { clock in
            if let db = model.db { ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Запланированные расходы") { Button("Запланировать расход", systemImage: "plus") { model.sheet = SheetRoute(kind: .scheduledPayment) }.buttonStyle(BeePrimaryStyle()) }
                Text("Предстоящие оплаты по договорам и рассрочке. Деньги списываются после подтверждения фактического расхода.").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted)
                HStack { TextField("Название, комментарий или договор", text: $search).textFieldStyle(BeeTextFieldStyle()); BeePicker("Состояние", selection: $status) { Text("Предстоящие").tag("Предстоящие"); ForEach(ScheduledPaymentState.allCases, id: \.self) { Text($0.title).tag($0.title) }; Text("Все").tag("Все"); Text("Архив").tag("Архив") }.frame(width: 220) }
                DisclosureGroup("Период оплаты") { HStack { DayField(title: "С даты", value: $from); DayField(title: "По дату", value: $through); Button("Сбросить") { from = ""; through = "" } } }.beeCard()
                let selected = rows(db, now: clock.date)
                ScheduledTotals(payments: selected)
                ForEach(selected) { ScheduledPaymentCard(payment: $0, now: clock.date) }
                if selected.isEmpty { EmptyState(title: "Нет запланированных платежей", detail: "Создайте разовую оплату или график рассрочки.").beeCard() }
            }.padding(24) } }
        }
    }
}
struct ScheduledTotals: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var payments: [ScheduledPayment]
    private func totals(_ db: Database) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for p in payments where !p.cancelled { result[p.currency] = try Money.add(result[p.currency] ?? 0, ScheduledPayments.remaining(p, db: db)) }
        return result.filter { $0.value > 0 }
    }
    var body: some View { if let db = model.db {
        if let values = try? totals(db), !values.isEmpty { HStack { Text("Осталось по выбранным планам").beeFont(.headline); Spacer(); ForEach(values.keys.sorted(), id: \.self) { Text(BeeFormat.money(values[$0]!, currency: $0)).monospacedDigit() } }.beeCard() }
        else if (try? totals(db)) == nil { Text("Итог слишком велик для расчёта. Уточните выборку.").foregroundStyle(BeeStyle.warning).beeCard() }
    } }
}
struct ScheduledPaymentCard: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var payment: ScheduledPayment
    var now = Date()
    var body: some View { if let db = model.db {
        Button { model.sheet = SheetRoute(kind: .scheduledDetail, entityID: payment.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) { Text(payment.title).beeFont(.headline); Spacer(); Text(BeeFormat.money((try? ScheduledPayments.remaining(payment, db: db)) ?? payment.amount, currency: payment.currency)).monospacedDigit() }
                Text(payment.comment).beeFont(.callout).foregroundStyle(BeeStyle.muted).lineLimit(3)
                HStack { Text(CalendarDays.label(payment.dueOn)); Text((try? ScheduledPayments.state(payment, db: db, now: now).title) ?? "Проверьте оплату"); if let name = payment.planName { Text(name).lineLimit(1) } }.beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).beeCard()
        }.buttonStyle(BeeRowStyle()).accessibilityLabel(payment.title + ", " + payment.comment + ", " + payment.dueOn.rawValue)
    } }
}
private enum ScheduledAction: String, Identifiable { case edit, pay; var id: String { rawValue } }
struct ScheduledPaymentDetail: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var id: UUID?
    @State private var action: ScheduledAction?
    var body: some View {
        if let db = model.db, let p = db.financeData.scheduledPayments?.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(p.title).beeFont(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }
                ScrollView { VStack(alignment: .leading, spacing: 14) {
                    Text(p.comment).textSelection(.enabled)
                    Text("Оплатить до: " + CalendarDays.label(p.dueOn) + " · " + p.timeZoneID)
                    Text((try? ScheduledPayments.state(p, db: db).title) ?? "Проверьте оплату").beeFont(.headline)
                    Text("План: " + BeeFormat.money(p.amount, currency: p.currency)); Text("Оплачено: " + BeeFormat.money((try? ScheduledPayments.paid(p, db: db)) ?? 0, currency: p.currency)); Text("Осталось: " + BeeFormat.money((try? ScheduledPayments.remaining(p, db: db)) ?? p.amount, currency: p.currency)).beeFont(.title3)
                    if let paid = try? ScheduledPayments.paid(p, db: db), paid > p.amount || p.originalAmount != nil { Text("Исходный план: " + BeeFormat.money(p.originalAmount ?? p.amount, currency: p.currency)); if let difference = try? Money.add(paid, -(p.originalAmount ?? p.amount)) { Text("Разница факта и исходного плана: " + BeeFormat.money(difference, currency: p.currency)).foregroundStyle(BeeStyle.warning) } }
                    if !p.payee.isEmpty { Text("Получатель: " + p.payee) }; if !p.contractReference.isEmpty { Text("Договор: " + p.contractReference) }
                    Divider(); Text("Напоминания").beeFont(.headline)
                    if p.cancelled || p.archived || (try? ScheduledPayments.remaining(p, db: db)) == 0 { Text("Платёж закрыт: будущие системные напоминания по нему не планируются.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                    ForEach(p.reminders) { r in Text((r.enabled ? "" : "Выключено · ") + (r.date.map { CalendarDays.label($0) } ?? "За \(r.daysBefore ?? 0) дн.") + String(format: " · %02d:%02d", r.hour, r.minute)).beeFont(.callout) }
                    if !db.financeData.reminders.systemEnabled { Button("Включить системные уведомления…") { Task { await FinancialNotifications.enable(model: model) } } }
                    if let status = model.financialNotificationStatus { Text(status.message).beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                    ForEach(p.dateHistory.indices, id: \.self) { i in Text("Перенос: " + p.dateHistory[i].from.rawValue + " → " + p.dateHistory[i].to.rawValue).beeFont(.caption) }
                    if !p.allocations.isEmpty { Divider(); Text("Связанные расходы").beeFont(.headline) }
                    ForEach(p.allocations, id: \.operationID) { a in
                        if let o = db.operations.first(where: { $0.id == a.operationID }) { HStack { VStack(alignment: .leading) { Text(CalendarDays.label(o.date) + " · " + BeeFormat.money(a.amount, currency: p.currency)); Text(o.comment).beeFont(.caption).foregroundStyle(BeeStyle.muted) }; Spacer(); Button("Снять связь") { if confirmDeletion("Связь с расходом", consequence: "Расход останется в истории. Остаток плана пересчитается.") { model.perform { ScheduledPayments.unlink(p.id, operationID: o.id, in: &$0) } } } } }
                    }
                    if !p.allocations.isEmpty { Button("Открыть фактические расходы") { let ids = p.allocations.map(\.operationID); dismiss(); DispatchQueue.main.async { model.showOperations(ids, title: p.title) } } }
                }.frame(maxWidth: .infinity, alignment: .leading) }
                Divider(); HStack {
                    Button("Удалить", role: .destructive) { if confirmDeletion(p.title, consequence: "План и его напоминания удалятся; реальные расходы сохранятся.") { model.perform { ScheduledPayments.delete(p.id, in: &$0) }; dismiss() } }
                    Button(p.cancelled ? "Вернуть в план" : "Отменить платёж") { if p.cancelled || confirmDeletion(p.title, consequence: "Будущие напоминания выключатся; реальные расходы сохранятся.") { var copy = p; copy.cancelled.toggle(); model.perform { try ScheduledPayments.save(copy, in: &$0) } } }
                    if p.cancelled || (try? ScheduledPayments.remaining(p, db: db)) == 0 { Button(p.archived ? "Из архива" : "В архив") { var copy = p; copy.archived.toggle(); model.perform { try ScheduledPayments.save(copy, in: &$0) } } }
                    Spacer(); Button("Изменить / перенести") { action = .edit }; Button("Оплатить") { action = .pay }.buttonStyle(BeePrimaryStyle()).disabled(p.cancelled || p.archived || (try? ScheduledPayments.remaining(p, db: db)) == 0)
                }
            }.padding(24).frame(width: 740, height: 620).beeWindow().sheet(item: $action) { item in switch item { case .edit: ScheduledPaymentEditor(id: p.id); case .pay: ScheduledPaymentPayEditor(id: p.id) } }
        } else { EmptyState(title: "Платёж недоступен", detail: "Он удалён или относится к другой базе.").padding(24) }
    }
}
struct ScheduledPaymentEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var id: UUID?
    @State private var payment = ScheduledPayment(title: "", comment: "", amount: 0, currency: "RUB", dueOn: Day.today.adding(30))
    @State private var amount = ""; @State private var date = Day.today.adding(30).rawValue
    @State private var count = 1; @State private var weekly = false
    @State private var preview: [ScheduledPayment] = []; @State private var rowErrors: [UUID: String] = [:]
    @State private var loaded = false; @State private var original = ""; @State private var previewError = ""
    @FocusState private var nameFocused: Bool
    private var fingerprint: String { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return String(decoding: (try? encoder.encode(payment)) ?? Data(), as: UTF8.self) + amount + date + String(count) + String(weekly) }
    private var hasPaid: Bool { !payment.allocations.isEmpty }
    private var fullyPaid: Bool { guard let db = model.db else { return false }; return hasPaid && (try? ScheduledPayments.remaining(payment, db: db)) == 0 }
    private var valid: Bool { !Ledger.normalized(payment.title).isEmpty && !Ledger.normalized(payment.comment).isEmpty && rowErrors.isEmpty && (id != nil || count == 1 || !preview.isEmpty) }
    var body: some View {
        EditorFrame(title: id == nil ? "Запланировать расход" : "Изменить плановый платёж", canSave: valid, isDirty: loaded && (fingerprint != original || !preview.isEmpty), width: 700, height: 650, tintColor: BeeStyle.text, save: save) {
            FormField(title: "Название расхода / платежа · обязательно") { TextField("Например, оплата ремонта", text: $payment.title).textFieldStyle(BeeTextFieldStyle()).focused($nameFocused) }
            FormField(title: "Комментарий · обязательно") { TextField("За что и по какому договору нужно оплатить", text: $payment.comment, axis: .vertical).lineLimit(3...5).textFieldStyle(BeeTextFieldStyle()) }
            HStack { CurrencyPicker(title: "Валюта обязательства", selection: $payment.currency).disabled(hasPaid); FormField(title: count > 1 ? "Общая сумма" : "Сумма") { TextField("0", text: $amount).textFieldStyle(BeeTextFieldStyle()).disabled(fullyPaid) } }
            DayField(title: count > 1 ? "Первый платёж" : "Оплатить до", value: $date).disabled(fullyPaid)
            if id == nil { Stepper("Количество платежей: \(count)", value: $count, in: 1...600); if count > 1 { BeePicker("Шаг графика", selection: $weekly) { Text("Ежемесячно").tag(false); Text("Еженедельно").tag(true) }; Text("После подготовки можно изменить дату, сумму, название и комментарий каждой позиции.").beeFont(.caption).foregroundStyle(BeeStyle.muted) } }
            if let db = model.db {
                if id == nil && count == 1 {
                    let plans = Dictionary((db.financeData.scheduledPayments ?? []).compactMap { p in p.planID.map { ($0, p.planName ?? p.title) } }, uniquingKeysWith: { first, _ in first })
                    BeePicker("Добавить в существующий план", selection: $payment.planID) { Text("Отдельный платёж").tag(nil as UUID?); ForEach(plans.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { key in Text(plans[key]!).tag(Optional(key)) } }.onChange(of: payment.planID) { _, next in payment.planName = next.flatMap { plans[$0] } }
                }
                BeePicker("Предполагаемый счёт", selection: $payment.accountID) { Text("Выбрать при оплате").tag(nil as UUID?); ForEach(db.accounts.filter { !$0.archived || $0.id == payment.accountID }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
                DisclosureGroup("Категория, проект и договор") {
                    VStack(alignment: .leading, spacing: 12) {
                        BeePicker("Категория", selection: $payment.categoryID) { Text("Без категории").tag(nil as UUID?); ForEach(db.categories.filter { $0.kind == .expense && (!$0.archived || $0.id == payment.categoryID) }) { Text(db.categoryPath($0.id)).tag(Optional($0.id)) } }
                        BeePicker("Проект", selection: $payment.projectID) { Text("Без проекта").tag(nil as UUID?); ForEach(db.projects.filter { !$0.archived || $0.id == payment.projectID }) { Text($0.name).tag(Optional($0.id)) } }
                        TextField("Получатель · необязательно", text: $payment.payee).textFieldStyle(BeeTextFieldStyle()); TextField("Название / номер договора · необязательно", text: $payment.contractReference).textFieldStyle(BeeTextFieldStyle())
                        FormField(title: "Часовой пояс срока и напоминаний") { TextField("Europe/Moscow, Europe/London или America/New_York", text: $payment.timeZoneID).textFieldStyle(BeeTextFieldStyle()) }
                    }.padding(.top, 10)
                }
            }
            ScheduledReminderFields(reminders: $payment.reminders, dueOn: (try? Day(date)) ?? payment.dueOn)
            if id == nil && count > 1 {
                Button("Подготовить график") { do { preview = try ScheduledPayments.installments(template: template(), count: count, weekly: weekly); rowErrors = [:]; previewError = "" } catch { previewError = error.localizedDescription } }
                if !previewError.isEmpty { Text(previewError).foregroundStyle(BeeStyle.negative) }
                ForEach(preview.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Название платежа · обязательно", text: $preview[i].title).textFieldStyle(BeeTextFieldStyle())
                        TextField("Комментарий · обязательно", text: $preview[i].comment, axis: .vertical).lineLimit(2...4).textFieldStyle(BeeTextFieldStyle())
                        HStack { DayField(title: "Дата", value: Binding(get: { preview[i].dueOn.rawValue }, set: { if let day = try? Day($0) { preview[i].dueOn = day } })); FormField(title: "Сумма · \(payment.currency)") { TextField("0", text: Binding(get: { Money.string(preview[i].amount, currency: preview[i].currency) }, set: { value in do { preview[i].amount = try Money.parse(value, currency: preview[i].currency); rowErrors[preview[i].id] = nil } catch { rowErrors[preview[i].id] = error.localizedDescription } })).textFieldStyle(BeeTextFieldStyle()) } }
                        if let error = rowErrors[preview[i].id] { Text(error).beeFont(.caption).foregroundStyle(BeeStyle.negative) }
                    }.beeCard()
                }
            }
            Text("До подтверждения оплаты этот план не изменяет остатки и фактические расходы. Системные напоминания включаются отдельно в настройках.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear { guard !loaded else { return }; if let p = model.db?.financeData.scheduledPayments?.first(where: { $0.id == id }) { payment = p; amount = Money.string(p.amount, currency: p.currency); date = p.dueOn.rawValue } else { payment.currency = model.db?.settings.baseCurrency ?? "RUB" }; original = fingerprint; loaded = true; nameFocused = true }
        .onChange(of: fingerprint) { _, _ in preview = []; rowErrors = [:] }
    }
    private func template() throws -> ScheduledPayment { var p = payment; p.amount = try Money.parse(amount, currency: p.currency); p.dueOn = try Day(date); return p }
    private func save() throws {
        let p = try template(); let rows = id == nil && count > 1 ? preview : [p]
        guard !rows.isEmpty, rows.allSatisfy({ !Ledger.normalized($0.title).isEmpty && !Ledger.normalized($0.comment).isEmpty }) else { throw BudgetError.invalid("Название и комментарий обязательны для каждой позиции.") }
        if count > 1 { guard try rows.reduce(Int64(0), { try Money.add($0, $1.amount) }) == p.amount else { throw BudgetError.invalid("Суммы графика должны совпадать с общей суммой.") } }
        try model.commit { try ScheduledPayments.save(rows, in: &$0) }
    }
}
struct ScheduledReminderFields: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @Binding var reminders: [ScheduledPaymentReminder]
    var dueOn: Day
    var body: some View {
        DisclosureGroup("Напоминания · \(reminders.filter(\.enabled).count)") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach($reminders) { $r in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Toggle("Напоминание", isOn: $r.enabled).toggleStyle(.checkbox); Spacer(); Button("Удалить") { reminders.removeAll { $0.id == r.id } } }
                        BeePicker("Когда напомнить", selection: Binding(get: { r.date != nil }, set: { absolute in var copy = r; copy.date = absolute ? dueOn : nil; copy.daysBefore = absolute ? nil : 1; r = copy })) { Text("До срока оплаты").tag(false); Text("В определённую дату").tag(true) }.beePickerStyle(.segmented)
                        if r.date != nil { DayField(title: "Дата напоминания", value: Binding(get: { (r.date ?? dueOn).rawValue }, set: { if let d = try? Day($0) { r.date = d } })) }
                        else { Stepper("За \(r.daysBefore ?? 0) дней", value: Binding(get: { r.daysBefore ?? 0 }, set: { r.daysBefore = $0 }), in: 0...36600) }
                        HStack { Stepper("Час: \(r.hour)", value: $r.hour, in: 0...23); Stepper("Минута: \(r.minute)", value: $r.minute, in: 0...59) }
                    }.padding(12).background(BeeStyle.chrome.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                Button("Добавить напоминание", systemImage: "plus") { reminders.append(ScheduledPaymentReminder()) }.disabled(reminders.count >= 60)
                Text("Относительные даты сдвигаются вместе со сроком оплаты. Отдельные даты остаются прежними; проверьте их при переносе.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.padding(.top, 12)
        }
    }
}
struct ScheduledPaymentPayEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var id: UUID
    @State private var existing = false; @State private var operationID: UUID?; @State private var accountID: UUID?
    @State private var amount = ""; @State private var received = ""; @State private var date = Day.today.rawValue
    @State private var closeRemainder = false; @State private var loaded = false
    var body: some View {
        if let db = model.db, let p = db.financeData.scheduledPayments?.first(where: { $0.id == id }) {
            let operation = db.operations.first { $0.id == operationID }
            let source = db.accounts.first { $0.id == (existing ? operation?.accountID : accountID) }
            EditorFrame(title: "Подтвердить оплату", saveTitle: existing ? "Связать расход" : "Сохранить расход", canSave: source != nil && (!existing || operation != nil), width: 640, height: 610, tintColor: BeeStyle.text, save: {
                guard let source else { throw BudgetError.invalid("Выберите счёт или существующий расход.") }
                let paid = try Money.parse(amount, currency: source.currency)
                let converted = source.currency == p.currency ? nil : try Money.parse(received, currency: p.currency)
                try model.commit { candidate in
                    if existing { guard let operationID else { throw BudgetError.invalid("Выберите расход.") }; try ScheduledPayments.link(id, operationID: operationID, sourceAmount: paid, paymentAmount: converted, closeRemainder: closeRemainder, in: &candidate) }
                    else { _ = try ScheduledPayments.pay(id, from: source.id, amount: paid, paymentAmount: converted, date: Day(date), closeRemainder: closeRemainder, in: &candidate) }
                }
            }) {
                Text(p.title).beeFont(.headline); Text(p.comment).foregroundStyle(BeeStyle.muted)
                Text("Осталось: " + BeeFormat.money((try? ScheduledPayments.remaining(p, db: db)) ?? p.amount, currency: p.currency))
                Toggle("Связать существующий расход", isOn: $existing).toggleStyle(.checkbox)
                if existing { BeePicker("Расход", selection: $operationID) { Text("Выберите расход").tag(nil as UUID?); ForEach(db.operations.filter { $0.kind == .expense }.sorted { $0.date > $1.date }) { o in Text(o.date.rawValue + " · " + Money.display(o.amount, currency: (try? db.account(o.accountID).currency) ?? p.currency) + " · " + o.comment).tag(Optional(o.id)) } } }
                else { BeePicker("Счёт списания", selection: $accountID) { Text("Выберите счёт").tag(nil as UUID?); ForEach(db.accounts.filter { !$0.archived }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }; DayField(title: "Дата фактической оплаты", value: $date) }
                FormField(title: "Сумма оплаты / доля расхода · \(source?.currency ?? p.currency)") { TextField("0", text: $amount).textFieldStyle(BeeTextFieldStyle()) }
                if let source, source.currency != p.currency { FormField(title: "Фактически погашено обязательство · \(p.currency)", hint: "Обе суммы обязательны. Курс сохраняется по фактической оплате.") { TextField("0", text: $received).textFieldStyle(BeeTextFieldStyle()) } }
                Toggle("Закрыть платёж этой оплатой и уточнить плановую сумму", isOn: $closeRemainder).toggleStyle(.checkbox)
                Text("Для частичной оплаты оставьте закрытие выключенным. Остаток сохранится в плане вместе с напоминаниями.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.onAppear { guard !loaded else { return }; accountID = p.accountID ?? db.accounts.first(where: { !$0.archived && $0.currency == p.currency })?.id; if db.accounts.first(where: { $0.id == accountID })?.currency == p.currency { amount = Money.string((try? ScheduledPayments.remaining(p, db: db)) ?? p.amount, currency: p.currency) }; loaded = true }
            .onChange(of: operationID) { _, next in if let o = db.operations.first(where: { $0.id == next }), let a = try? db.account(o.accountID) { let used = (db.financeData.scheduledPayments ?? []).flatMap(\.allocations).filter { $0.operationID == o.id }.reduce(0) { $0 + $1.sourceAmount }; amount = Money.string(max(0, o.amount - used), currency: a.currency); received = "" } }
            .onChange(of: accountID) { old, next in if old != nil || db.accounts.first(where: { $0.id == next })?.currency != p.currency { amount = ""; received = "" } }
        }
    }
}
struct ScheduledDashboardSummary: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var body: some View { if let db = model.db {
        let payments = (db.financeData.scheduledPayments ?? []).filter { !$0.cancelled && !$0.archived && ((try? ScheduledPayments.remaining($0, db: db)) ?? 0) > 0 }.sorted { $0.dueOn < $1.dueOn }
        if !payments.isEmpty { VStack(alignment: .leading, spacing: 12) { HStack { Text("Предстоящие расходы").beeFont(.headline); Spacer(); Button("Все планы") { model.section = .expenses; model.showScheduledExpenses = true } }; ForEach(Array(payments.prefix(3))) { p in Button { model.sheet = SheetRoute(kind: .scheduledDetail, entityID: p.id) } label: { HStack { Text(CalendarDays.label(p.dueOn)); Text(p.title).lineLimit(1); Spacer(); Text(BeeFormat.money((try? ScheduledPayments.remaining(p, db: db)) ?? p.amount, currency: p.currency)) } }.buttonStyle(BeeRowStyle()) }; Text("Плановые суммы учитываются отдельно от фактических расходов и кредитного долга.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }.beeCard() }
    } }
}
