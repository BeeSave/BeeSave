import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BudgetCore
import BudgetPresentation

struct FinanceChoice<T: Hashable & CaseIterable>: View where T.AllCases: RandomAccessCollection {
    var title: String
    @Binding var value: T
    var titleOf: (T) -> String
    var body: some View { FormField(title: title) { BeePicker(title, selection: $value) { ForEach(Array(T.allCases), id: \.self) { Text(titleOf($0)).tag($0) } }.labelsHidden() } }
}
struct FinanceMoneyField: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    @Binding var value: Int64
    var currency: String
    @Binding var errors: [String: String]
    @State private var raw = ""
    @State private var loaded = false
    var body: some View {
        FormField(title: title + " · " + currency) { TextField("0", text: $raw).textFieldStyle(BeeTextFieldStyle()) }
            .onAppear { raw = Money.string(value, currency: currency); loaded = true }
            .onChange(of: raw) { _, text in guard loaded else { return }; do { let amount = try Money.parse(text, currency: currency); guard amount >= 0 else { throw BudgetError.invalid(title + ": сумма не может быть отрицательной.") }; value = amount; errors[title] = nil } catch { errors[title] = title + ": " + error.localizedDescription } }
            .onChange(of: currency) { raw = Money.string(value, currency: currency) }
            .onDisappear { errors[title] = nil }
    }
}
struct FinanceDateField: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    var optional = true
    @Binding var value: Day?
    @Binding var errors: [String: String]
    @State private var raw = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if value == nil {
                FormField(title: title + (optional ? " · необязательно" : "")) {
                    HStack { Text("Не задана").foregroundStyle(BeeStyle.muted); Spacer(); Button("Указать дату") { value = .today; raw = Day.today.rawValue } }
                }
            } else {
                DayField(title: title, value: $raw)
                if optional { Button("Убрать дату") { value = nil; raw = "" } }
            }
        }.onAppear { raw = value?.rawValue ?? "" }.onChange(of: raw) { _, text in do { value = text.isEmpty ? nil : try Day(text); errors[title] = nil } catch { errors[title] = title + ": " + error.localizedDescription } }.onDisappear { errors[title] = nil }
    }
}
private func optionalText(_ binding: Binding<String?>) -> Binding<String> { Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0.replacingOccurrences(of: ",", with: ".") }) }
private func optionalMoney(_ binding: Binding<Int64?>) -> Binding<Int64> { Binding(get: { binding.wrappedValue ?? 0 }, set: { binding.wrappedValue = $0 == 0 ? nil : $0 }) }

struct FinancialContractFields: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Binding var contract: FinancialContract
    var currency: String
    @Binding var errors: [String: String]
    @State private var showCalendarEditor = false
    @State private var selected = 0
    @State private var advanced = false
    @State private var start = ""
    var body: some View {
        Divider(); Text("Условия договора").beeFont(.headline)
        FinanceChoice(title: "Рынок", value: $contract.market, titleOf: { $0.title }).onChange(of: contract.market) { _, market in
            if ["Europe/Moscow", "Europe/London", "America/New_York"].contains(contract.timeZoneID) { contract.timeZoneID = market == .gb ? "Europe/London" : market == .us ? "America/New_York" : "Europe/Moscow" }
        }
        DayField(title: "Начало договора", value: $start).onAppear { start = contract.start.rawValue }.onChange(of: start) { _, text in do { contract.start = try Day(text); errors["start"] = nil } catch { errors["start"] = error.localizedDescription } }
        FinanceDateField(title: "Окончание договора", optional: contract.kind == .revolvingCredit, value: $contract.end, errors: $errors)
        FinanceDateField(title: "Первая выплата", value: $contract.firstPayment, errors: $errors)
        Stepper("День месяца: \(contract.paymentDay ?? FinanceMath.day(contract.firstPayment ?? contract.start))", value: Binding(get: { contract.paymentDay ?? FinanceMath.day(contract.firstPayment ?? contract.start) }, set: { contract.paymentDay = $0 }), in: 1...31)
        FinanceChoice(title: contract.kind == .deposit ? "Выплата процентов" : "Периодичность платежей", value: $contract.frequency, titleOf: { $0.title })
        if contract.frequency == .everyNDays { Stepper("Каждые \(contract.everyNDays) дней", value: $contract.everyNDays, in: 1...366) }
        if contract.frequency == .twiceMonthly { Stepper("Вторая дата месяца: \(contract.secondPaymentDay)", value: $contract.secondPaymentDay, in: 1...31) }
        FormField(title: "Счёт оплаты") { accountPicker($contract.paymentAccountID) }
        FormField(title: "Версия условий") { BeePicker("Версия", selection: $selected) { ForEach(contract.terms.indices, id: \.self) { Text("С " + contract.terms[$0].effectiveFrom.rawValue).tag($0) } }.labelsHidden() }
        Button("Добавить изменение условий") { var copy = contract.terms[min(selected, contract.terms.count - 1)]; copy.id = UUID(); copy.effectiveFrom = .today; contract.terms.append(copy); selected = contract.terms.count - 1 }
        FinancialTermFields(terms: $contract.terms[min(selected, contract.terms.count - 1)], kind: contract.kind, currency: currency, payoutFrequency: contract.frequency, errors: $errors).id(contract.terms[min(selected, contract.terms.count - 1)].id)
        if let periods = contract.previousPeriods, !periods.isEmpty { DisclosureGroup("Предыдущие сроки · \(periods.count)") { ForEach(periods) { period in VStack(alignment: .leading, spacing: 4) { Text(period.start.rawValue + " — " + (period.end?.rawValue ?? "Без окончания")); ForEach(period.terms) { Text("С " + $0.effectiveFrom.rawValue + ": " + ($0.annualPercent.map { $0 + "%" } ?? "Ставка неизвестна") + " · " + $0.basis.title).beeFont(.caption) } } } } }
        DisclosureGroup("Календарь и напоминания", isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Название продукта", text: $contract.productName).textFieldStyle(BeeTextFieldStyle())
                TextField("Примечание", text: $contract.note, axis: .vertical).textFieldStyle(BeeTextFieldStyle())
                FinanceChoice(title: "Перенос нерабочего дня", value: $contract.businessDayRule, titleOf: { $0.title })
                FormField(title: "Календарь банка") { BeePicker("Календарь", selection: $contract.calendarID) { Text("Только выходные; праздники неизвестны").tag(nil as UUID?); ForEach(model.db?.financeData.calendars ?? []) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() }
                Button(contract.calendarID == nil ? "Создать календарь банка…" : "Изменить календарь банка…") { showCalendarEditor = true }.sheet(isPresented: $showCalendarEditor) { FinancialBankCalendarEditor(id: contract.calendarID) { contract.calendarID = $0 } }
                TextField("Часовой пояс, например Europe/London", text: $contract.timeZoneID).textFieldStyle(BeeTextFieldStyle())
                Toggle("Есть предельный час зачисления платежа", isOn: Binding(get: { contract.cutoffHour != nil }, set: { contract.cutoffHour = $0 ? 17 : nil }))
                if contract.cutoffHour != nil {
                    Stepper("Зачисление до \(contract.cutoffHour ?? 17):00 · время банка", value: Binding(get: { contract.cutoffHour ?? 17 }, set: { contract.cutoffHour = $0 }), in: 0...23)
                    BeePicker("Начисление после предельного часа", selection: $contract.lateCreditPosting) {
                        Text("Уточнить по договору").tag(nil as LateCreditPosting?)
                        ForEach(LateCreditPosting.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                }
                Stepper("Горизонт прогноза: \(contract.forecastMonths) мес.", value: $contract.forecastMonths, in: 1...1200)
                Toggle("Напоминания по договору", isOn: $contract.reminders.enabled)
                Toggle("Напоминать о процентах депозита", isOn: $contract.reminders.interestEnabled)
                ReminderOffsetsField(title: "До платежа, дней", values: $contract.reminders.paymentOffsets, errors: $errors)
                ReminderOffsetsField(title: "До окончания, дней", values: $contract.reminders.maturityOffsets, errors: $errors)
                Stepper("Час напоминания: \(contract.reminders.hour)", value: $contract.reminders.hour, in: 0...23)
                Stepper("Минута: \(contract.reminders.minute)", value: $contract.reminders.minute, in: 0...59)
            }.padding(.top, 10)
        }
        Text("Прогноз не создаёт операции. Подтверждайте выплаты по фактическим суммам банка.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
    }
    @ViewBuilder private func accountPicker(_ binding: Binding<UUID?>) -> some View { BeePicker("Счёт", selection: binding) { Text("Не выбран").tag(nil as UUID?); ForEach(model.db?.accounts.filter { !$0.archived && $0.id != contract.accountID } ?? []) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() }
}
struct ReminderOffsetsField: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String; @Binding var values: [Int]; @Binding var errors: [String: String]; @State private var raw = ""
    var body: some View { FormField(title: title) { TextField("7, 3, 1, 0", text: $raw).textFieldStyle(BeeTextFieldStyle()) }.onAppear { raw = values.map(String.init).joined(separator: ", ") }.onChange(of: raw) { _, text in let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; let numbers = parts.compactMap(Int.init); if numbers.count == parts.count && numbers.allSatisfy({ (0...3650).contains($0) }) { values = Array(Set(numbers)).sorted(by: >); errors[title] = nil } else { errors[title] = title + ": введите целые дни от 0 до 3650." } } }
}
struct FinancialTermFields: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Binding var terms: FinancialTerms
    var kind: AccountKind; var currency: String
    var payoutFrequency: PaymentFrequency = .monthly
    @Binding var errors: [String: String]
    @State private var effective = ""
    @State private var advanced = false
    var body: some View {
        DayField(title: "Эти условия действуют с", value: $effective).onAppear { effective = terms.effectiveFrom.rawValue }.onChange(of: effective) { _, text in do { terms.effectiveFrom = try Day(text); errors["termsDate"] = nil } catch { errors["termsDate"] = error.localizedDescription } }
        FormField(title: "Процентная ставка, %", hint: "Пустое поле означает неизвестную ставку; 0 — беспроцентный договор.") { TextField("Например, 12", text: optionalText($terms.annualPercent)).textFieldStyle(BeeTextFieldStyle()) }
        FinanceChoice(title: "Вид ставки", value: $terms.rateKind, titleOf: { $0.title })
        FinanceChoice(title: "База начисления", value: $terms.basis, titleOf: { $0.title })
        if kind == .deposit { depositFields }
        if kind == .revolvingCredit { creditFields }
        if kind == .termLoan || kind == .mortgage { loanFields }
        DisclosureGroup("Точные правила расчёта", isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: 12) {
                FinanceChoice(title: "Округление", value: $terms.rounding, titleOf: { $0.title })
                FinanceChoice(title: "Когда округлять", value: $terms.roundingPoint, titleOf: { $0 == .daily ? "Каждый день" : "На выплате" })
                FinanceChoice(title: "Остаток для начисления", value: $terms.balanceBasis, titleOf: { switch $0 { case .openingDay: "На начало дня"; case .closingDay: "На конец дня"; case .minimumPeriod: "Минимальный за период" } })
                Toggle("Включать первый день периода", isOn: $terms.includeFirstDay); Toggle("Включать последний день периода", isOn: $terms.includeLastDay)
                TextField("Индекс, например SOFR / SONIA", text: $terms.indexName).textFieldStyle(BeeTextFieldStyle())
                TextField("Значение индекса, %", text: optionalText($terms.indexPercent)).textFieldStyle(BeeTextFieldStyle())
                TextField("Маржа, %", text: optionalText($terms.marginPercent)).textFieldStyle(BeeTextFieldStyle())
                TextField("Минимальная ставка, %", text: optionalText($terms.floorPercent)).textFieldStyle(BeeTextFieldStyle())
                TextField("Максимальная ставка, %", text: optionalText($terms.capPercent)).textFieldStyle(BeeTextFieldStyle())
                FinanceDateField(title: "Пересмотр ставки", value: $terms.resetOn, errors: $errors)
                Toggle("Ставка задана для сценария", isOn: $terms.scenarioRate)
                TextField("Справочный показатель: APY / AER / APR / ПСК", text: $terms.comparisonRateLabel).textFieldStyle(BeeTextFieldStyle())
                TextField("Справочное значение, %", text: optionalText($terms.comparisonRate)).textFieldStyle(BeeTextFieldStyle())
                TextField("Источник условий", text: $terms.source).textFieldStyle(BeeTextFieldStyle())
            }.padding(.top, 10)
        }
    }
    @ViewBuilder private var depositFields: some View {
        Toggle("Капитализировать проценты", isOn: $terms.deposit.capitalize)
        Toggle("Отдельные периоды начисления и капитализации", isOn: Binding(get: { terms.deposit.accrualFrequency != nil || terms.deposit.capitalizationFrequency != nil }, set: { enabled in terms.deposit.accrualFrequency = enabled ? .monthly : nil; terms.deposit.capitalizationFrequency = enabled ? .monthly : nil; if !enabled { terms.deposit.roundOnlyAtFinalPayout = nil } }))
        if terms.deposit.accrualFrequency != nil {
            FinanceChoice(title: "Период начисления", value: Binding(get: { terms.deposit.accrualFrequency ?? .monthly }, set: { terms.deposit.accrualFrequency = $0 }), titleOf: { $0.title })
            if terms.deposit.capitalize { FinanceChoice(title: "Период капитализации", value: Binding(get: { terms.deposit.capitalizationFrequency ?? .monthly }, set: { terms.deposit.capitalizationFrequency = $0 }), titleOf: { $0.title }) }
            Toggle("Округлять только финальную выплату", isOn: Binding(get: { terms.deposit.roundOnlyAtFinalPayout == true }, set: { terms.deposit.roundOnlyAtFinalPayout = $0 })).disabled(payoutFrequency != .maturity)
            if payoutFrequency != .maturity { Text("Для округления только в конце выберите выплату процентов «В конце срока».").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
        }
        FormField(title: "Счёт внешней выплаты процентов") { BeePicker("Счёт", selection: $terms.deposit.payoutAccountID) { Text(terms.deposit.capitalize ? "Оставить на депозите" : "Указать при подтверждении").tag(nil as UUID?); ForEach(model.db?.accounts.filter { !$0.archived && $0.kind == .ordinary } ?? []) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() }
        Toggle("Разрешено пополнение", isOn: $terms.deposit.allowTopUp); Toggle("Разрешено частичное снятие", isOn: $terms.deposit.allowWithdrawal)
        FinanceMoneyField(title: "Неснижаемый остаток", value: $terms.deposit.minimumBalance, currency: currency, errors: $errors)
        Toggle("Условия налога известны", isOn: $terms.deposit.taxKnown)
        if terms.deposit.taxKnown {
            TextField("Удержание налога, %", text: optionalText($terms.deposit.taxPercent)).textFieldStyle(BeeTextFieldStyle())
            Toggle("Оплачивать налог отдельно от процентов", isOn: Binding(get: { terms.deposit.separateTaxFrequency != nil }, set: { terms.deposit.separateTaxFrequency = $0 ? .yearly : nil }))
            if terms.deposit.separateTaxFrequency != nil {
                FinanceChoice(title: "Период оплаты налога", value: Binding(get: { terms.deposit.separateTaxFrequency ?? .yearly }, set: { terms.deposit.separateTaxFrequency = $0 }), titleOf: { $0.title })
                BeePicker("Счёт оплаты налога", selection: $terms.deposit.taxPaymentAccountID) { Text("Указать при подтверждении").tag(nil as UUID?); ForEach(model.db?.accounts.filter { !$0.archived && $0.kind == .ordinary } ?? []) { Text($0.name).tag(Optional($0.id)) } }
            }
        }
        FinanceDateField(title: "Решение о продлении до", value: $terms.deposit.renewalDecisionOn, errors: $errors)
        TextField("Ставка при досрочном закрытии, %", text: optionalText($terms.deposit.earlyAnnualPercent)).textFieldStyle(BeeTextFieldStyle())
    }
    @ViewBuilder private var creditFields: some View {
        FinanceMoneyField(title: "Кредитный лимит", value: $terms.credit.limit, currency: currency, errors: $errors)
        Toggle("Проценты и комиссии используют лимит", isOn: $terms.credit.chargesUseLimit)
        Stepper("Закрытие выписки: \(terms.credit.closingDay)-е число", value: $terms.credit.closingDay, in: 1...31)
        Stepper("Оплата через \(terms.credit.dueDays) дней после выписки", value: $terms.credit.dueDays, in: 0...366)
        FinanceChoice(title: "Льготный период", value: $terms.credit.grace, titleOf: { $0.title })
        Stepper("Льгота: \(terms.credit.graceDays) дней", value: $terms.credit.graceDays, in: 0...3650)
        FinanceDateField(title: "Льгота / промо до", value: $terms.credit.graceEnd, errors: $errors)
        FinanceChoice(title: "Минимальный платёж", value: $terms.credit.minimumMode, titleOf: { switch $0 { case .fixed: "Фиксированная сумма"; case .percent: "Процент долга"; case .percentPlusCharges: "Процент тела + начисления"; case .manual: "По выписке вручную" } })
        TextField("Минимальный платёж, %", text: $terms.credit.minimumPercent).textFieldStyle(BeeTextFieldStyle())
        FinanceMoneyField(title: "Минимальная сумма платежа", value: $terms.credit.minimumFloor, currency: currency, errors: $errors)
        FinanceMoneyField(title: "Фиксированный минимальный платёж", value: $terms.credit.minimumFixed, currency: currency, errors: $errors)
        FinanceChoice(title: "Начислять после потери льготы", value: $terms.credit.accrualAfterGrace, titleOf: { switch $0 { case .afterDeadline: "После крайней даты"; case .fromTransaction: "С даты покупки"; case .fromCycle: "С начала цикла" } })
        Toggle("Льгота требует своевременного минимального платежа", isOn: $terms.credit.requiresMinimumForGrace)
        Toggle("Перенос долга влияет на льготу новых покупок", isOn: $terms.credit.carriedDebtLosesGrace)
        FinanceChoice(title: "Распределение между выписками", value: Binding(get: { terms.credit.statementPaymentOrder ?? .manual }, set: { terms.credit.statementPaymentOrder = $0 }), titleOf: { $0.title })
        if terms.credit.carriedDebtLosesGrace {
            Toggle("Известно условие восстановления льготы", isOn: Binding(get: { terms.credit.graceRestoreStatements != nil }, set: { terms.credit.graceRestoreStatements = $0 ? 1 : nil }))
            if terms.credit.graceRestoreStatements != nil {
                Stepper("Полностью оплаченных выписок подряд: \(terms.credit.graceRestoreStatements ?? 1)", value: Binding(get: { terms.credit.graceRestoreStatements ?? 1 }, set: { terms.credit.graceRestoreStatements = $0 }), in: 1...120)
            }
        }
        TextField("Штрафная ставка, % · необязательно", text: optionalText($terms.credit.penaltyAnnualPercent)).textFieldStyle(BeeTextFieldStyle())
        if terms.credit.penaltyAnnualPercent != nil {
            BeePicker("Штрафная ставка заменяет обычную до", selection: $terms.credit.penaltyUntilMinimumPaid) {
                Text("Условие неизвестно").tag(nil as Bool?)
                Text("Погашения просроченного минимума").tag(Optional(true))
                Text("Указанной даты").tag(Optional(false))
            }
            if terms.credit.penaltyUntilMinimumPaid == false { FinanceDateField(title: "Последний день штрафной ставки", value: $terms.credit.penaltyEnd, errors: $errors) }
        }
        repaymentFields
        Toggle("Отдельное правило для суммы сверх минимума", isOn: Binding(get: { terms.credit.excessRepaymentOrder != nil }, set: { terms.credit.excessRepaymentOrder = $0 ? .highestRate : nil }))
        if terms.credit.excessRepaymentOrder != nil { FinanceChoice(title: "Сверх минимального платежа", value: Binding(get: { terms.credit.excessRepaymentOrder ?? .highestRate }, set: { terms.credit.excessRepaymentOrder = $0 }), titleOf: { $0.title }) }
        ForEach(terms.credit.buckets.indices, id: \.self) { index in
            VStack(alignment: .leading) { Text(terms.credit.buckets[index].kind.title).beeFont(.subheadline.bold()); TextField("Отдельная ставка, %", text: optionalText($terms.credit.buckets[index].annualPercent)).textFieldStyle(BeeTextFieldStyle()); Toggle("Применяется льгота", isOn: $terms.credit.buckets[index].eligibleForGrace) }
        }
        FinanceMoneyField(title: "Комиссия за просрочку", value: $terms.credit.lateFee, currency: currency, errors: $errors)
    }
    @ViewBuilder private var repaymentFields: some View { FinanceChoice(title: "Распределение погашения", value: $terms.credit.repaymentOrder, titleOf: { $0.title }) }
    @ViewBuilder private var loanFields: some View {
        FinanceChoice(title: "Схема погашения", value: $terms.loan.method, titleOf: { $0.title })
        FinanceMoneyField(title: "Платёж банка (0 — рассчитать)", value: optionalMoney($terms.loan.paymentOverride), currency: currency, errors: $errors)
        FinanceMoneyField(title: "Комиссия за платёж", value: $terms.loan.paymentFee, currency: currency, errors: $errors)
        FinanceMoneyField(title: "Взнос escrow", value: $terms.loan.escrowPayment, currency: currency, errors: $errors)
        FormField(title: "Счёт escrow") { BeePicker("Счёт", selection: $terms.loan.escrowAccountID) { Text("Не выбран").tag(nil as UUID?); ForEach(model.db?.accounts.filter { !$0.archived } ?? []) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden() }
        FinanceDateField(title: "Кредитные каникулы до", value: $terms.loan.holidayEnd, errors: $errors)
        Toggle("Начислять проценты во время каникул", isOn: $terms.loan.accrueDuringHoliday)
        Toggle("Капитализировать проценты во время каникул", isOn: $terms.loan.capitalizeDuringHoliday)
        FinanceDateField(title: "Период interest-only до", value: $terms.loan.interestOnlyEnd, errors: $errors)
        FinanceDateField(title: "Окончание фиксированной ставки", value: $terms.loan.fixedDealEnd, errors: $errors)
        TextField("Комиссия досрочного погашения, %", text: optionalText($terms.loan.prepaymentFeePercent)).textFieldStyle(BeeTextFieldStyle())
        repaymentFields
    }
}

struct BankMark: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var bankID: String?; var fallback = "building.columns"
    private var customPicture: NSImage? {
        if let data = model.db?.financeData.banks.first(where: { $0.id == bankID })?.logo { return NSImage(data: data) }
        return nil
    }
    private var catalogPicture: NSImage? {
        if let bankID, let bank = BankCatalog.get(bankID), let url = BankCatalog.shared.logoURL(bank) { return NSImage(contentsOf: url) }
        return nil
    }
    var body: some View {
        Group {
            if let customPicture { Image(nsImage: customPicture).resizable().scaledToFit() }
            else if let catalogPicture { Image(nsImage: catalogPicture).renderingMode(.template).resizable().scaledToFit() }
            else { Image(systemName: fallback).beeFont(.system(size: 19, weight: .medium)) }
        }
        .foregroundStyle(BeeStyle.color(0x173F42))
        .frame(width: 24, height: 24).padding(5)
        .background(BeeStyle.color(0xF7C756), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel(model.db?.financialBankName(bankID) ?? "Без банка")
    }
}
struct BankPicker: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Binding var bankID: String?
    @State private var search = ""
    @State private var showManual = false
    @State private var expanded = false
    @State private var keyboardBankID: String?
    @FocusState private var searchFocused: Bool
    private var groups: [BankChoiceGroup] {
        BankCatalog.shared.selectionGroups(search, primaryCurrency: model.db?.settings.baseCurrency,
                                           userBanks: model.db?.financeData.banks ?? [])
    }
    var body: some View {
        let visibleGroups = expanded ? groups : []
        DisclosureGroup(model.db?.financialBankName(bankID) ?? "Банк · необязательно", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Поиск банка", text: $search).textFieldStyle(BeeTextFieldStyle()).focused($searchFocused)
                    .onKeyPress(.downArrow) { moveBankSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveBankSelection(-1); return .handled }
                    .onSubmit {
                        if let identity = keyboardBankID ?? (search.isEmpty ? nil : groups.first?.banks.first?.id) {
                            bankID = identity; expanded = false
                        }
                    }
                    .onExitCommand { expanded = false }
                Button("Без банка") { bankID = nil; expanded = false }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleGroups) { group in
                            Section {
                                ForEach(group.banks) { bank in
                                    Button { bankID = bank.id; expanded = false } label: {
                                        HStack(spacing: 10) {
                                            BankMark(bankID: bank.id)
                                            Text(bank.name).fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                            if bankID == bank.id { Image(systemName: "checkmark").accessibilityLabel("Выбран") }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(BeeRowStyle()).accessibilityLabel(bank.name + ", " + group.name)
                                        .background(keyboardBankID == bank.id ? BeeStyle.honey.opacity(0.16) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .id(bank.id)
                                }
                            } header: {
                                Text(group.name).beeFont(.headline).padding(.top, 8).accessibilityAddTraits(.isHeader)
                            }
                        }
                        if visibleGroups.isEmpty { Text("Банки не найдены").foregroundStyle(BeeStyle.muted).padding(.vertical, 8) }
                    }.padding(.horizontal, 4)
                }.frame(maxHeight: 300).accessibilityLabel("Список банков")
                    .onChange(of: keyboardBankID) { _, identity in
                        if let identity { proxy.scrollTo(identity, anchor: .center) }
                    }
                }
                Button("Добавить банк вручную…") { showManual = true }
            }.padding(.top, 10)
        }.onChange(of: expanded) { _, open in searchFocused = open; keyboardBankID = nil }
        .onChange(of: search) { _, _ in keyboardBankID = nil }
        .sheet(isPresented: $showManual) { BankEditor(onSaved: { bankID = $0; expanded = false }) }
    }
    private func moveBankSelection(_ direction: Int) {
        let choices = groups.flatMap(\.banks)
        guard !choices.isEmpty else { keyboardBankID = nil; return }
        let current = choices.firstIndex { $0.id == keyboardBankID }
        let next = current.map { min(max($0 + direction, 0), choices.count - 1) }
            ?? (direction > 0 ? 0 : choices.count - 1)
        keyboardBankID = choices[next].id
    }
}
struct BankEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var bank: UserBank? = nil
    var onSaved: (String) -> Void = { _ in }
    @State private var name = ""
    @State private var country = FinancialMarket.other
    @State private var logo: Data?
    @State private var note = ""
    @State private var imageError = ""
    var body: some View {
        EditorFrame(title: bank == nil ? "Новый банк" : "Изменить банк", isDirty: name != (bank?.name ?? "") || logo != bank?.logo || note != (bank?.note ?? ""), height: 490, save: {
            var copy = bank ?? UserBank(name: name); copy.name = name; copy.country = country; copy.logo = logo; copy.note = note
            try model.commit { try FinancialLedger.saveBank(copy, in: &$0) }; onSaved(copy.id)
        }) {
            TextField("Название банка", text: $name).textFieldStyle(BeeTextFieldStyle())
            FinanceChoice(title: "Страна", value: $country, titleOf: { $0.title })
            if let logo, let image = NSImage(data: logo) { Image(nsImage: image).resizable().scaledToFit().frame(width: 80, height: 80) }
            HStack { Button("Выбрать PNG / JPEG…", action: selectImage); Button("Убрать изображение") { logo = nil }.disabled(logo == nil) }
            if !imageError.isEmpty { Text(imageError).foregroundStyle(BeeStyle.negative).beeFont(.caption) }
            TextField("Примечание", text: $note).textFieldStyle(BeeTextFieldStyle())
            Text("Банк и изображение сохраняются в зашифрованной базе. Изображение используется только локально.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear { name = bank?.name ?? ""; country = bank?.country ?? .other; logo = bank?.logo; note = bank?.note ?? "" }
    }
    private func selectImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.canChooseDirectories = false
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2 * 1024 * 1024 else { throw BudgetError.invalid("Выберите PNG / JPEG до 2 MiB.") }
                logo = try BankImages.normalized(Data(contentsOf: url)); imageError = ""
            } catch { imageError = error.localizedDescription }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
}
struct BankReferenceList: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var search: String; var archived: Bool
    @State private var editing: UserBank?
    var body: some View {
        Text("Свои банки").beeFont(.headline)
        ForEach(model.db?.financeData.banks.filter { (archived || !$0.archived) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) } ?? []) { bank in
            HStack { BankMark(bankID: bank.id); Text(bank.name + " · " + bank.country.rawValue); Spacer(); Button("Изменить") { editing = bank }; Button(bank.archived ? "Вернуть" : "Архивировать") { model.perform { db in var copy = bank; copy.archived.toggle(); try FinancialLedger.saveBank(copy, in: &db) } } }.padding(.vertical, 8)
        }
        Divider(); Text("Каталог: \(BankCatalog.shared.banks.count) записей · \(BankCatalog.shared.manifest.builtOn)").beeFont(.headline)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(BankCatalog.shared.search(search, includeInactive: archived, primaryCurrency: model.db?.settings.baseCurrency)) { bank in
                HStack { BankMark(bankID: bank.id); Text(bank.name).fixedSize(horizontal: false, vertical: true); Spacer(); Text(BankMarket.get(bank.country)?.name ?? bank.country).beeFont(.caption) }.padding(.vertical, 6)
            }
        }
        if !BankCatalog.shared.manifest.logosComplete { Text("Иконки банков ещё проходят проверку.").beeFont(.caption).foregroundStyle(BeeStyle.warning) }
        EmptyView().sheet(item: $editing) { BankEditor(bank: $0) }
    }
}

private enum FinanceAction: Identifiable {
    case payment(FinanceEvent?), statement, manualRow, scenario, issue, depositExit, renewal
    var id: String { switch self { case .payment(let event): "payment-" + (event?.id ?? "manual"); case .statement: "statement"; case .manualRow: "manual"; case .scenario: "scenario"; case .issue: "issue"; case .depositExit: "exit"; case .renewal: "renewal" } }
}
struct FinancialAccountDetail: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var accountID: UUID
    @State private var action: FinanceAction?
    @State private var expanded = false
    var body: some View {
        if let db = model.db, let account = db.accounts.first(where: { $0.id == accountID }), let contract = db.contract(for: accountID) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(account.kind.title + " · " + contract.status.title).beeFont(.headline); if let name = db.financialBankName(account.bankID) { Text(name).foregroundStyle(BeeStyle.muted) }; Spacer(); Button("Условия") { model.sheet = SheetRoute(kind: .account, entityID: accountID) }; if !account.archived && contract.status != .closed { Button(account.kind == .deposit ? "Подтвердить проценты" : "Платёж") { action = .payment(nil) } } }
                if account.kind.isDebt, let debt = try? FinancialLedger.debt(accountID: accountID, db: db) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) { FinanceValue(title: "Задолженность", amount: debt.debt, currency: account.currency); FinanceValue(title: "Тело долга", amount: debt.amount(.principal), currency: account.currency); FinanceValue(title: "Собственные средства", amount: debt.ownFunds, currency: account.currency); if let limit = debt.limit { FinanceValue(title: "Лимит", amount: limit, currency: account.currency); FinanceValue(title: "Доступно", amount: debt.available, currency: account.currency) } }
                    if debt.amount(.unallocated) > 0 { Label("Есть нераспределённый долг. Уточните состав для точного прогноза.", systemImage: "exclamationmark.triangle").beeFont(.caption).foregroundStyle(BeeStyle.warning) }
                }
                Menu("Действия по договору") {
                    if account.kind == .revolvingCredit { Button("Ввести выписку") { action = .statement } }
                    if account.kind.isDebt { Button("Получение кредита") { action = .issue }; Button("Сценарий досрочного погашения") { action = .scenario } }
                    if account.kind == .deposit { Button("Возврат / досрочное закрытие") { action = .depositExit }; Button("Подтвердить продление") { action = .renewal } }
                    Button("Добавить событие / строку графика") { action = .manualRow }
                    if contract.status == .active { Button("Закрыть договор") { model.perform { try FinancialLedger.closeContract(contract.id, in: &$0) } } }
                }.disabled(account.archived)
                DisclosureGroup("График · \((model.financialEvents[contract.id] ?? []).count) событий", isExpanded: $expanded) { ScrollView { FinanceEventList(contract: contract, events: model.financialEvents[contract.id] ?? [], onConfirm: { action = .payment($0) }) }.frame(maxHeight: 230) }
                if let error = model.financialErrors[contract.id] { Text(error).beeFont(.caption).foregroundStyle(BeeStyle.warning) }
            }.beeCard().padding(.horizontal, 24)
                .sheet(item: $action) { action in switch action {
                case .payment(let event): FinancialPaymentEditor(contract: contract, event: event)
                case .statement: CreditStatementEditor(contract: contract)
                case .manualRow: ManualFinanceRowEditor(contract: contract)
                case .scenario: FinancialScenarioView(contract: contract)
                case .issue: CreditIssueEditor(contract: contract)
                case .depositExit: DepositExitEditor(contract: contract)
                case .renewal: DepositRenewalEditor(contract: contract)
                } }
        }
    }
}
struct FinanceValue: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String; var amount: Int64?; var currency: String
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(title).beeFont(.caption).foregroundStyle(BeeStyle.muted); Text(amount.map { BeeFormat.money($0, currency: currency) } ?? "Неизвестно").monospacedDigit() } }
}
struct FinanceEventList: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var contract: FinancialContract
    var events: [FinanceEvent]
    var onConfirm: (FinanceEvent) -> Void
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(CalendarDays.label(event.date)).beeFont(.caption); Text(event.kind.title).beeFont(.headline); Spacer(); Text(event.remaining.map { BeeFormat.money($0, currency: (try? model.db?.account(contract.accountID).currency) ?? "RUB") } ?? "Уточните сумму").monospacedDigit(); if event.isFulfilled { Label("Исполнено", systemImage: "checkmark.circle").beeFont(.caption) } else if [.depositInterest, .loanPayment, .gracePayment, .minimumPayment].contains(event.kind) || event.kind == .tax && contract.kind == .deposit { Button("Подтвердить") { onConfirm(event) }.disabled(model.financialBusy || event.date > .today || model.db?.accounts.first(where: { $0.id == contract.accountID })?.archived == true) } }
                    HStack {
                        if let until = model.db?.financeData.reminders.eventSnoozedUntil?[event.id], until > Date() { Text("Напоминание отложено до " + until.formatted(date: .numeric, time: .shortened)).beeFont(.caption) }
                        Spacer()
                        if !event.isFulfilled { Menu("Напоминания") { Button("Отложить на один день") { model.perform { db in var book = db.financeData; var postponed = book.reminders.eventSnoozedUntil ?? [:]; var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: contract.timeZoneID) ?? .current; postponed[event.id] = calendar.date(byAdding: .day, value: 1, to: Date()); book.reminders.eventSnoozedUntil = postponed; db.finances = book } }; Button("Снять отсрочку") { model.perform { db in var book = db.financeData; book.reminders.eventSnoozedUntil?[event.id] = nil; db.finances = book } } }.beeFont(.caption) }
                    }
                    Text(event.accuracy.title + (event.date < .today && !event.isFulfilled ? " · срок прошёл" : "")).beeFont(.caption).foregroundStyle(event.accuracy == .calculated ? BeeStyle.muted : BeeStyle.warning)
                    if !event.components.isEmpty { Text(event.components.map { $0.component.title + ": " + BeeFormat.money($0.amount, currency: (try? model.db?.account(contract.accountID).currency) ?? "RUB") }.joined(separator: " · ")).beeFont(.caption) }
                    ForEach(event.notes, id: \.self) { Text($0).beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                }; Divider()
            }
            if events.isEmpty { Text("Нет событий. Заполните условия договора или ручной график.").foregroundStyle(BeeStyle.muted) }
        }
    }
}
struct FinancialCalendarView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @State private var includeFulfilled = false
    @State private var payment: FinanceCalendarSelection?
    @State private var accountFilter: UUID?
    @State private var typeFilter: AccountKind?
    @State private var scope = 0
    @State private var search = ""
    @State private var bankFilter: String?
    @State private var from = ""
    @State private var through = ""
    private var contracts: [FinancialContract] { guard let db = model.db else { return [] }; return db.financeData.contracts.filter { contract in contract.status != .closed && (accountFilter == nil || contract.accountID == accountFilter) && (typeFilter == nil || contract.kind == typeFilter) && (bankFilter == nil || db.accounts.first(where: { $0.id == contract.accountID })?.bankID == bankFilter) } }
    private func selectedEvents(_ id: UUID) -> [FinanceEvent] { let first = try? Day(from), last = try? Day(through); return (model.financialEvents[id] ?? []).filter { (includeFulfilled || !$0.isFulfilled) && (first == nil || $0.date >= first!) && (last == nil || $0.date <= last!) } }
    private var ordered: [FinanceCalendarSelection] {
        var selections: [FinanceCalendarSelection] = []
        if scope != 2 { for contract in contracts { for event in selectedEvents(contract.id) { if search.isEmpty || (contract.productName + " " + contract.note).localizedCaseInsensitiveContains(search) || event.notes.joined(separator: " ").localizedCaseInsensitiveContains(search) { selections.append(FinanceCalendarSelection(contract: contract, event: event)) } } } }
        if scope != 1, let db = model.db {
            for p in db.financeData.scheduledPayments ?? [] where !p.cancelled && !p.archived && (accountFilter == nil || p.accountID == accountFilter) {
                let account = db.accounts.first { $0.id == p.accountID }
                guard (typeFilter == nil || account?.kind == typeFilter), (bankFilter == nil || account?.bankID == bankFilter), search.isEmpty || [p.title, p.comment, p.contractReference, p.planName ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(search) }) else { continue }
                for event in selectedEvents(p.id) { selections.append(FinanceCalendarSelection(scheduled: p, event: event)) }
            }
        }
        return selections.sorted { left, right in
            if left.event.date != right.event.date { return left.event.date < right.event.date }
            return left.id < right.id
        }
    }
    var body: some View {
        let rows = ordered
        ScrollView { LazyVStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Календарь") { Button("Запланировать расход") { model.sheet = SheetRoute(kind: .scheduledPayment) }; Toggle("Исполненные", isOn: $includeFulfilled).toggleStyle(.checkbox); Button("Пересчитать") { model.refreshFinancialForecasts() }; if model.financialBusy { ProgressView().controlSize(.small); Button("Отмена") { model.cancelFinancialForecasts() } } }
            BeePicker("События", selection: $scope) { Text("Все").tag(0); Text("Финансовые счета").tag(1); Text("Запланированные расходы").tag(2) }.beePickerStyle(.segmented)
            Text("Планируемые суммы не входят в фактические доходы, расходы и остатки. Минимальный платёж и погашение для льготы могут относиться к одному долгу.").beeFont(.caption).foregroundStyle(BeeStyle.backgroundMuted)
            DisclosureGroup("Фильтры календаря") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Название, комментарий или договор", text: $search).textFieldStyle(BeeTextFieldStyle())
                    BeePicker("Счёт", selection: $accountFilter) { Text("Все счета").tag(nil as UUID?); ForEach(model.db?.accounts ?? []) { Text($0.name).tag(Optional($0.id)) } }
                    BeePicker("Тип", selection: $typeFilter) { Text("Все типы").tag(nil as AccountKind?); ForEach(AccountKind.allCases.filter { $0 != .ordinary }, id: \.self) { Text($0.title).tag(Optional($0)) } }
                    BeePicker("Банк", selection: $bankFilter) { Text("Все банки").tag(nil as String?); ForEach(Array(Set(model.db?.accounts.compactMap(\.bankID) ?? [])).sorted(), id: \.self) { Text(model.db?.financialBankName($0) ?? $0).tag(Optional($0)) } }
                    HStack { DayField(title: "С даты · необязательно", value: $from); DayField(title: "По дату · необязательно", value: $through) }
                    if (!from.isEmpty && (try? Day(from)) == nil) || (!through.isEmpty && (try? Day(through)) == nil) { Text("Введите даты YYYY-MM-DD.").beeFont(.caption).foregroundStyle(BeeStyle.warning) }
                    Button("Сбросить фильтры") { accountFilter = nil; typeFilter = nil; bankFilter = nil; from = ""; through = ""; search = ""; scope = 0 }
                }.padding(.top, 12)
            }.beeCard()
            ForEach(contracts) { contract in if let error = model.financialErrors[contract.id] { Text(((try? model.db?.account(contract.accountID).name) ?? contract.kind.title) + ": " + error).foregroundStyle(BeeStyle.warning).beeCard() } }
            ScheduledTotals(payments: rows.compactMap(\.scheduled))
            ForEach(rows) { selection in
                if let contract = selection.contract { VStack(alignment: .leading, spacing: 12) { Button((try? model.db?.account(contract.accountID).name) ?? contract.kind.title) { model.openHistory(contract.accountID) }.beeFont(.title3.bold()).buttonStyle(BeeRowStyle()); FinanceEventList(contract: contract, events: [selection.event], onConfirm: { payment = FinanceCalendarSelection(contract: contract, event: $0) }) }.beeCard() }
                else if let p = selection.scheduled { ScheduledPaymentCard(payment: p) }
            }
            if rows.isEmpty && !model.financialBusy { EmptyState(title: "Нет событий", detail: "Проверьте фильтры и условия договоров.").beeCard() }
        }.padding(26) }.sheet(item: $payment) { selection in if let contract = selection.contract { FinancialPaymentEditor(contract: contract, event: selection.event) } }
    }
}
private struct FinanceCalendarSelection: Identifiable { var id: String { event.id }; var contract: FinancialContract?; var scheduled: ScheduledPayment?; var event: FinanceEvent }

struct FinancialPaymentEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var contract: FinancialContract; var event: FinanceEvent?
    var editingGroupID: UUID? = nil
    @State private var fromID: UUID?
    @State private var payoutID: UUID?
    @State private var amount = ""
    @State private var received = ""
    @State private var interest = "0"
    @State private var fee = "0"
    @State private var penalty = "0"
    @State private var tax = "0"
    @State private var escrow = "0"
    @State private var escrowAccountID: UUID?
    @State private var date = Day.today.rawValue
    @State private var creditedTime = ""
    @State private var prepayment = false
    @State private var prepaymentMode = PrepaymentMode.reducePayment
    @State private var alreadyCharged = false
    @State private var manualAllocation = false
    @State private var components: [FinancialComponent: String] = [:]
    @State private var allocationRows: [FinancialAllocation] = []
    @State private var statementAmounts: [UUID: String] = [:]
    @State private var allocationErrors: [String: String] = [:]
    @State private var linkID: UUID?
    @State private var linkExisting = false
    var currency: String { (try? model.db?.account(contract.accountID).currency) ?? "RUB" }
    var externalCurrency: String { (fromID.flatMap { id in model.db?.accounts.first { $0.id == id } }?.currency) ?? currency }
    var depositTax: Bool {
        guard contract.kind == .deposit else { return false }
        if event?.kind == .tax { return true }
        guard let group = model.db?.financeData.groups.first(where: { $0.id == editingGroupID }), let db = model.db else { return false }
        let rows = db.operations.filter { group.operationIDs.contains($0.id) }
        return !rows.isEmpty && rows.allSatisfy { $0.kind == .expense && $0.financial?.component == .tax }
    }
    var linkableOperations: [BudgetCore.Operation] {
        model.db?.operations.filter { operation in
            if depositTax { return operation.kind == .expense && model.db?.accounts.first(where: { $0.id == operation.accountID })?.kind == .ordinary && model.db?.accounts.first(where: { $0.id == operation.accountID })?.currency == currency }
            return contract.kind == .deposit ? operation.accountID == contract.accountID && operation.kind == .income : operation.toAccountID == contract.accountID || operation.accountID == contract.accountID && operation.kind == .income
        } ?? []
    }
    var body: some View {
        EditorFrame(title: depositTax ? "Подтвердить налог" : contract.kind == .deposit ? "Подтвердить проценты" : "Подтвердить платёж", isDirty: !amount.isEmpty, height: 720, save: save) {
            if let event { Text(event.kind.title + " · " + CalendarDays.label(event.date)).beeFont(.headline) }
            DayField(title: "Дата фактической операции", value: $date)
            if contract.kind.isDebt && contract.cutoffHour != nil { field("Время зачисления HH:mm · " + contract.timeZoneID + " · пусто — неизвестно", $creditedTime) }
            if event != nil && editingGroupID == nil { Toggle("Связать с существующей операцией", isOn: $linkExisting) }
            if linkExisting {
                BeePicker("Фактическая операция", selection: $linkID) { Text("Выберите").tag(nil as UUID?); ForEach(linkableOperations) { Text("\($0.date) · " + BeeFormat.money($0.toAmount ?? $0.amount, currency: currency) + " · " + $0.comment).tag(Optional($0.id)) } }
                field("Покрытая сумма · " + currency, $amount)
            } else if depositTax {
                accountPicker("Счёт оплаты налога", $fromID)
                field("Фактически списано · " + externalCurrency, $amount)
                if externalCurrency != currency { field("Покрыто в валюте депозита · " + currency, $received) }
            } else if contract.kind == .deposit {
                field("Фактические проценты до удержаний · " + currency, $amount)
                field("Удержанный налог · " + currency, $tax)
                accountPicker("Выплата на счёт (пусто — капитализация)", $payoutID)
                if let id = payoutID, model.db?.accounts.first(where: { $0.id == id })?.currency != currency { field("Фактическое зачисление в валюте получателя", $received) }
            } else {
                accountPicker("Счёт списания", $fromID)
                field("Фактически списано · " + externalCurrency, $amount)
                if externalCurrency != currency { field("Погашено в валюте договора · " + currency, $received) }
                Toggle("Проценты и комиссии уже учтены в истории", isOn: $alreadyCharged)
                if !alreadyCharged { field("Новые проценты · " + currency, $interest); field("Новая комиссия · " + currency, $fee); field("Новый штраф · " + currency, $penalty) }
                Toggle("Досрочное погашение", isOn: $prepayment)
                if prepayment && (contract.kind == .mortgage || contract.kind == .termLoan) { FinanceChoice(title: "После досрочного погашения", value: $prepaymentMode, titleOf: { switch $0 { case .reduceTerm: "Уменьшить срок"; case .reducePayment: "Уменьшить платёж"; case .manual: "График банка вручную" } }); Text("Режим сохранится с фактическим платежом. Новый график остаётся прогнозом; комиссию банка укажите в фактических суммах выше.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                Toggle("Распределить вручную", isOn: $manualAllocation)
                if manualAllocation {
                    if !allocationRows.isEmpty {
                        ForEach(allocationRows.indices, id: \.self) { index in FinanceMoneyField(title: allocationRows[index].component.title + (allocationRows[index].lotID.map { " · транш " + String($0.uuidString.prefix(8)) } ?? ""), value: $allocationRows[index].amount, currency: currency, errors: $allocationErrors) }
                        Button("Задать новое распределение по компонентам") { allocationRows = []; allocationErrors = [:] }
                    } else { ForEach([FinancialComponent.principal, .interest, .fee, .penalty, .unallocated], id: \.self) { component in field(component.title + " · " + currency, Binding(get: { components[component] ?? "0" }, set: { components[component] = $0 })) } }
                }
                field("Взнос escrow внутри общей суммы · " + externalCurrency, $escrow)
                accountPicker("Счёт escrow", $escrowAccountID)
                if contract.kind == .revolvingCredit {
                    Text("Распределение по выпискам · необязательно").beeFont(.headline)
                    Text("Укажите распределение банка. Остаток платежа не будет автоматически приписан другим выпискам.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                    ForEach(model.db?.financeData.statements.filter { $0.contractID == contract.id }.sorted { $0.closedOn < $1.closedOn } ?? []) { statement in
                        field("Выписка " + statement.closedOn.rawValue + " · " + currency, Binding(get: { statementAmounts[statement.id] ?? "" }, set: { statementAmounts[statement.id] = $0 }))
                    }
                }
            }
            Text("Проверьте фактические суммы по документу банка. Связанные записи сохраняются и удаляются вместе.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear {
            fromID = contract.paymentAccountID; payoutID = contract.terms(on: .today)?.deposit.payoutAccountID
            if depositTax { fromID = contract.terms(on: event?.accrualEnd ?? .today)?.deposit.taxPaymentAccountID }
            if let event { amount = Money.string(event.remaining ?? 0, currency: currency); escrow = Money.string(event.amount(.escrow), currency: currency); interest = Money.string(event.amount(.interest), currency: currency); fee = Money.string(event.amount(.fee), currency: currency); penalty = Money.string(event.amount(.penalty), currency: currency) }
            escrowAccountID = contract.terms(on: .today)?.loan.escrowAccountID
            manualAllocation = contract.terms(on: .today)?.credit.repaymentOrder == .manual
            if let event, event.components.contains(where: { $0.lotID != nil }) { allocationRows = event.components; manualAllocation = true }
            if let group = model.db?.financeData.groups.first(where: { $0.id == editingGroupID }), let db = model.db {
                let rows = db.operations.filter { group.operationIDs.contains($0.id) }
                date = rows.first?.date.rawValue ?? date
                if depositTax {
                    let expense = rows.first { $0.kind == .expense && $0.financial?.component == .tax }
                    fromID = expense?.accountID; amount = Money.string(expense?.amount ?? 0, currency: externalCurrency)
                    if externalCurrency != currency { received = Money.string(db.financeData.fulfillments.first { $0.operationIDs == group.operationIDs }?.amount ?? 0, currency: currency) }
                } else if contract.kind == .deposit {
                    let income = rows.first { $0.kind == .income }; amount = Money.string(income?.amount ?? 0, currency: currency)
                    tax = Money.string(rows.first { $0.kind == .expense && $0.financial?.component == .tax }?.amount ?? 0, currency: currency)
                    let transfer = rows.first { $0.kind == .transfer }; payoutID = transfer?.toAccountID; received = transfer?.toAmount.map { Money.string($0, currency: db.accounts.first { $0.id == transfer?.toAccountID }?.currency ?? currency) } ?? ""
                } else {
                    let transfer = rows.first { $0.kind == .transfer && $0.toAccountID == contract.accountID }
                    fromID = transfer?.accountID
                    let escrowTransfer = rows.first { $0.financial?.component == .escrow }; escrowAccountID = escrowTransfer?.toAccountID
                    escrow = Money.string(escrowTransfer?.amount ?? 0, currency: externalCurrency)
                    amount = Money.string((transfer?.amount ?? 0) + (escrowTransfer?.amount ?? 0), currency: externalCurrency)
                    received = transfer?.toAmount.map { Money.string($0, currency: currency) } ?? ""
                    interest = Money.string(rows.first { $0.kind == .expense && $0.financial?.component == .interest }?.amount ?? 0, currency: currency)
                    fee = Money.string(rows.first { $0.kind == .expense && $0.financial?.component == .fee }?.amount ?? 0, currency: currency)
                    penalty = Money.string(rows.first { $0.kind == .expense && $0.financial?.component == .penalty }?.amount ?? 0, currency: currency)
                    allocationRows = transfer?.financial?.allocations ?? []; manualAllocation = !allocationRows.isEmpty
                    statementAmounts = Dictionary(uniqueKeysWithValues: (transfer?.financial?.statementAllocations ?? []).map { ($0.statementID, Money.string($0.amount, currency: currency)) })
                    prepayment = transfer?.financial?.prepayment ?? false
                    prepaymentMode = transfer?.financial?.prepaymentMode ?? .manual
                    if let instant = transfer?.financial?.creditedAt { let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: contract.timeZoneID); formatter.dateFormat = "HH:mm"; creditedTime = formatter.string(from: instant) }
                }
            }
        }
    }
    @ViewBuilder private func field(_ title: String, _ value: Binding<String>) -> some View { FormField(title: title) { TextField("0", text: value).textFieldStyle(BeeTextFieldStyle()) } }
    @ViewBuilder private func accountPicker(_ title: String, _ value: Binding<UUID?>) -> some View { FormField(title: title) { BeePicker(title, selection: value) { Text("Не выбран").tag(nil as UUID?); ForEach(model.db?.accounts.filter { !$0.archived && $0.id != contract.accountID } ?? []) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }.labelsHidden() } }
    private func commitPayment(_ mutation: (inout Database) throws -> Void) throws {
        try model.commit { db in if let editingGroupID { try FinancialLedger.replaceGroup(editingGroupID, in: &db, with: mutation) } else { try mutation(&db) } }
    }
    private func save() throws {
        let day = try Day(date)
        if linkExisting { guard let event, let linkID else { throw BudgetError.invalid("Выберите событие и операцию.") }; let covered = try Money.parse(amount, currency: currency); try model.commit { try FinancialLedger.link(event: event, operationIDs: [linkID], amount: covered, in: &$0) }; return }
        if contract.kind == .deposit {
            if depositTax {
                guard let fromID, let eventID = model.db?.financeData.groups.first(where: { $0.id == editingGroupID })?.eventID ?? event?.id else { throw BudgetError.invalid("Выберите счёт оплаты налога.") }
                let paid = try Money.parse(amount, currency: externalCurrency)
                let covered = received.isEmpty ? nil : try Money.parse(received, currency: currency)
                try commitPayment { try FinancialLedger.payDepositTax(contractID: contract.id, eventID: eventID, from: fromID, amount: paid, coveredInContractCurrency: covered, date: day, in: &$0) }
                return
            }
            let gross = try Money.parse(amount, currency: currency), tax = try Money.parse(tax, currency: currency)
            let received = self.received.isEmpty ? nil : try Money.parse(self.received, currency: payoutID.flatMap { id in model.db?.accounts.first { $0.id == id } }?.currency ?? currency)
            let eventID = model.db?.financeData.groups.first(where: { $0.id == editingGroupID })?.eventID ?? event?.id ?? FinancialEngine.eventKey(contract.id, kind: .depositInterest, anchor: day.rawValue)
            try commitPayment { try FinancialLedger.confirmDeposit(contractID: contract.id, eventID: eventID, gross: gross, tax: tax, payoutAccountID: payoutID, receivedAmount: received, date: day, in: &$0) }
        } else {
            guard let fromID else { throw BudgetError.invalid("Выберите счёт оплаты.") }
            let paid = try Money.parse(amount, currency: externalCurrency), received = self.received.isEmpty ? nil : try Money.parse(self.received, currency: currency)
            let interest = alreadyCharged ? 0 : try Money.parse(interest, currency: currency), fee = alreadyCharged ? 0 : try Money.parse(fee, currency: currency), penalty = alreadyCharged ? 0 : try Money.parse(penalty, currency: currency)
            let escrowAmount = try Money.parse(escrow, currency: externalCurrency)
            guard allocationErrors.isEmpty else { throw BudgetError.invalid(allocationErrors.values.joined(separator: "\n")) }
            let allocation = manualAllocation ? (!allocationRows.isEmpty ? allocationRows : try components.compactMap { key, value -> FinancialAllocation? in let parsed = try Money.parse(value, currency: currency); return parsed == 0 ? nil : FinancialAllocation(key, parsed) }) : []
            let statements = try statementAmounts.compactMap { id, value -> CreditStatementAllocation? in
                guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                let amount = try Money.parse(value, currency: currency)
                return amount == 0 ? nil : CreditStatementAllocation(statementID: id, amount: amount)
            }.sorted { $0.statementID.uuidString < $1.statementID.uuidString }
            var creditedAt: Date?
            if !creditedTime.isEmpty {
                let parts = creditedTime.split(separator: ":"); guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute), let zone = TimeZone(identifier: contract.timeZoneID) else { throw BudgetError.invalid("Введите время HH:mm в часовом поясе банка.") }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                creditedAt = calendar.date(from: DateComponents(timeZone: zone, year: FinanceMath.year(day), month: FinanceMath.month(day), day: FinanceMath.day(day), hour: hour, minute: minute))
                guard creditedAt != nil else { throw BudgetError.invalid("Такого времени нет в календаре банка.") }
            }
            try commitPayment { try FinancialLedger.payDebt(contractID: contract.id, from: fromID, amount: paid, interestCharge: interest, feeCharge: fee, penaltyCharge: penalty, escrowAmount: escrowAmount, escrowAccountID: escrowAccountID, allocations: allocation, statementAllocations: statements, eventID: model.db?.financeData.groups.first(where: { $0.id == editingGroupID })?.eventID ?? event?.id, receivedAmount: received, date: day, prepayment: prepayment, prepaymentMode: prepayment && contract.kind != .revolvingCredit ? prepaymentMode : nil, creditedAt: creditedAt, in: &$0) }
        }
    }
}
struct CreditStatementEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var contract: FinancialContract
    @State private var start = Day.today.firstOfMonth.rawValue
    @State private var closed = Day.today.rawValue
    @State private var due = Day.today.adding(25).rawValue
    @State private var balance: Int64 = 0
    @State private var minimum: Int64 = 0
    @State private var grace: Int64 = 0
    @State private var errors: [String: String] = [:]
    var body: some View {
        EditorFrame(title: "Выписка банка", isDirty: true, height: 610, save: {
            guard errors.isEmpty else { throw BudgetError.invalid(errors.values.joined(separator: "\n")) }
            let statement = CreditStatement(contractID: contract.id, start: try Day(start), closedOn: try Day(closed), dueOn: try Day(due), balance: balance, minimum: minimum, graceAmount: grace)
            try model.commit { db in if let index = db.financeData.statements.firstIndex(where: { $0.contractID == contract.id && $0.closedOn == statement.closedOn }) { db.finances?.statements[index] = statement } else { var book = db.financeData; book.statements.append(statement); db.finances = book } }
        }) { DayField(title: "Начало цикла", value: $start); DayField(title: "Закрытие выписки", value: $closed); DayField(title: "Оплатить до", value: $due); FinanceMoneyField(title: "Долг выписки", value: $balance, currency: currency, errors: $errors); FinanceMoneyField(title: "Минимальный платёж", value: $minimum, currency: currency, errors: $errors); FinanceMoneyField(title: "Для сохранения льготы", value: $grace, currency: currency, errors: $errors); Text("Выписка уточняет план. Остаток меняют фактические операции.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
    }
    private var currency: String { (try? model.db?.account(contract.accountID).currency) ?? "RUB" }
}
struct ManualFinanceRowEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var contract: FinancialContract
    @State private var date = Day.today.adding(1).rawValue
    @State private var kind = FinanceEventKind.loanPayment
    @State private var values: [FinancialComponent: String] = [:]
    @State private var comment = ""
    var body: some View {
        EditorFrame(title: "Событие / строка графика", isDirty: !values.isEmpty || !comment.isEmpty, height: 650, save: {
            let currency = (try? model.db?.account(contract.accountID).currency) ?? "RUB"
            let components = try values.compactMap { key, value -> FinancialAllocation? in let amount = try Money.parse(value, currency: currency); guard amount >= 0 else { throw BudgetError.invalid("Суммы должны быть неотрицательными.") }; return amount == 0 ? nil : FinancialAllocation(key, amount) }
            var row = ManualFinanceRow(date: try Day(date), kind: kind, components: components, amount: components.isEmpty ? nil : try components.reduce(0) { try Money.add($0, $1.amount) }); row.comment = comment
            try model.commit { db in guard var current = db.contract(for: contract.accountID) else { throw BudgetError.corrupt }; current.manualRows.append(row); try FinancialLedger.saveContract(current, in: &db) }
        }) { DayField(title: "Дата", value: $date); BeePicker("Событие", selection: $kind) { ForEach(FinanceEventKind.allCases.filter { $0 != .scheduledPayment }, id: \.self) { Text($0.title).tag($0) } }; ForEach([FinancialComponent.principal, .interest, .fee, .penalty, .escrow, .tax], id: \.self) { component in FormField(title: component.title) { TextField("0", text: Binding(get: { values[component] ?? "" }, set: { values[component] = $0 })).textFieldStyle(BeeTextFieldStyle()) } }; TextField("Комментарий", text: $comment).textFieldStyle(BeeTextFieldStyle()) }.onAppear { kind = contract.kind == .deposit ? .depositInterest : .loanPayment }
    }
}
struct CreditIssueEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var contract: FinancialContract
    @State private var destination: UUID?
    @State private var amount = ""
    @State private var received = ""
    @State private var date = Day.today.rawValue
    var body: some View {
        EditorFrame(title: "Получение кредита", isDirty: !amount.isEmpty, height: 480, save: {
            guard let destination, let source = try model.db?.account(contract.accountID), let target = try model.db?.account(destination) else { throw BudgetError.invalid("Выберите счёт получения.") }
            let amount = try Money.parse(amount, currency: source.currency), received = self.received.isEmpty ? nil : try Money.parse(self.received, currency: target.currency)
            try model.commit { try FinancialLedger.issueCredit(contractID: contract.id, to: destination, amount: amount, receivedAmount: received, date: Day(date), in: &$0) }
        }) { DayField(title: "Дата", value: $date); TextField("Сумма в валюте кредита", text: $amount).textFieldStyle(BeeTextFieldStyle()); BeePicker("Счёт получения", selection: $destination) { Text("Выберите").tag(nil as UUID?); ForEach(model.db?.accounts.filter { !$0.archived && $0.id != contract.accountID } ?? []) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }; TextField("Фактически получено (для другой валюты)", text: $received).textFieldStyle(BeeTextFieldStyle()); Text("Получение кредита учитывается переводом и не увеличивает доход.").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
    }
}
struct FinancialScenarioView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var contract: FinancialContract
    @State private var amount = ""
    @State private var date = Day.today.rawValue
    @State private var paymentDate = Day.today.adding(30).rawValue
    @State private var results: [LoanScenario] = []
    @State private var creditCost: CreditCostScenario?
    @State private var error = ""
    @State private var busy = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Сценарий").beeFont(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            DayField(title: "Дата досрочного погашения", value: $date)
            if contract.kind == .revolvingCredit { DayField(title: "Планируемая полная оплата", value: $paymentDate) }
            else { TextField("Сумма досрочного погашения", text: $amount).textFieldStyle(BeeTextFieldStyle()) }
            Button("Рассчитать", action: calculate).disabled(busy)
            if busy { ProgressView() }; if !error.isEmpty { Text(error).foregroundStyle(BeeStyle.warning) }
            if let cost = creditCost { FinanceValue(title: "Дополнительные проценты", amount: cost.interest, currency: currency); FinanceValue(title: "Комиссии", amount: cost.fees, currency: currency); Text(cost.accuracy.title).beeFont(.caption); ForEach(cost.notes, id: \.self) { Text($0).beeFont(.caption) } }
            ForEach(results.indices, id: \.self) { index in VStack(alignment: .leading, spacing: 8) { Text(index == 0 ? "Уменьшить срок" : "Уменьшить платёж").beeFont(.headline); FinanceValue(title: "Оставшиеся проценты", amount: results[index].remainingInterest, currency: currency); FinanceValue(title: "Комиссия досрочного погашения", amount: results[index].fee, currency: currency); Text("Окончание: " + (results[index].end?.rawValue ?? "Неизвестно") + " · " + results[index].accuracy.title).beeFont(.caption) }.beeCard() }
            Text("Сценарий не меняет историю и не подтверждает будущие операции.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.padding(24) }.beeSheet(width: 620, height: 650).beeWindow()
    }
    private var currency: String { (try? model.db?.account(contract.accountID).currency) ?? "RUB" }
    private func calculate() {
        guard let db = model.db else { return }; busy = true; error = ""
        do { let day = try Day(date), paidOn = try Day(paymentDate), amount = contract.kind == .revolvingCredit ? 0 : try Money.parse(amount, currency: currency)
            Task { do { let result = try await Task.detached { () throws -> ([LoanScenario], CreditCostScenario?) in if contract.kind == .revolvingCredit { return ([], try FinancialEngine.creditCost(contract: contract, db: db, paymentDate: paidOn, asOf: day)) }; return (try [FinancialEngine.prepayment(contract: contract, db: db, amount: amount, mode: .reduceTerm, asOf: day), FinancialEngine.prepayment(contract: contract, db: db, amount: amount, mode: .reducePayment, asOf: day)], nil as CreditCostScenario?) }.value; guard model.db?.id == db.id else { busy = false; return }; results = result.0; creditCost = result.1; busy = false } catch { self.error = error.localizedDescription; busy = false } }
        } catch { self.error = error.localizedDescription; busy = false }
    }
}

struct FinancialDashboardSummary: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let db = model.db, !db.financeData.contracts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Финансовые счета").beeFont(.headline); Spacer(); Button("Календарь") { model.section = .financialCalendar } }
                let events = upcomingEvents()
                let debtRows = debt(db)
                if let total = try? Reports.total(debtRows) { Text("Задолженность: " + BeeFormat.valuation(total, currency: db.settings.reportCurrency)).beeFont(.title3).monospacedDigit() }
                ForEach(Array(events.prefix(3))) { event in
                    if let contract = db.financeData.contracts.first(where: { $0.id == event.contractID }), let account = try? db.account(contract.accountID) {
                        Button { model.openHistory(account.id) } label: { HStack { Text(CalendarDays.label(event.date)); Text(account.name + " · " + event.kind.title).lineLimit(1); Spacer(); Text(event.remaining.map { BeeFormat.money($0, currency: account.currency) } ?? "Уточните сумму") } }.buttonStyle(BeeRowStyle())
                    }
                }
                if model.financialBusy { ProgressView("Пересчёт графиков…").controlSize(.small) }
                Text("Долг включает архивные счета. Предстоящие суммы показаны отдельно от фактических расходов.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            }.beeCard()
        }
    }
    private func upcomingEvents() -> [FinanceEvent] {
        var nearest: [FinanceEvent] = []
        for rows in model.financialEvents.values {
            for event in rows where !event.isFulfilled && event.kind != .scheduledPayment {
                if let index = nearest.firstIndex(where: { $0.date > event.date }) {
                    nearest.insert(event, at: index)
                    if nearest.count > 3 { nearest.removeLast() }
                } else if nearest.count < 3 { nearest.append(event) }
            }
        }
        return nearest
    }
    private func debt(_ db: Database) -> [ReportRow] { var report = Report(name: "Долг"); report.dataset = .debt; report.metric = .balance; report.grouping = .account; report.filters = Filters(); report.currency = db.settings.reportCurrency; return (try? FinancialReports.rows(report, db: db)) ?? [] }
}

struct FinancialGroupEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    var groupID: UUID?
    var body: some View {
        if let group = model.db?.financeData.groups.first(where: { $0.id == groupID }), let contract = model.db?.financeData.contracts.first(where: { $0.id == group.contractID }), group.title == "Выплата процентов" || group.title == "Платёж кредитору" || group.title == "Досрочное погашение" {
            FinancialPaymentEditor(contract: contract, event: nil, editingGroupID: group.id)
        } else { VStack(spacing: 16) { Text("Для изменения выдачи или закрытия договора удалите соответствующую группу и оформите исправленные факты."); Button("Закрыть") { dismiss() } }.padding(24).frame(width: 480) }
    }
}
struct DepositRenewalEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var contract: FinancialContract
    @State private var start = ""
    @State private var end = ""
    @State private var rate = ""
    var body: some View {
        EditorFrame(title: "Подтвердить продление", isDirty: true, height: 420, save: { try model.commit { try FinancialLedger.renewDeposit(contract.id, start: Day(start), end: Day(end), annualPercent: rate.isEmpty ? nil : rate.replacingOccurrences(of: ",", with: "."), in: &$0) } }) {
            DayField(title: "Начало нового срока", value: $start); DayField(title: "Окончание нового срока", value: $end)
            TextField("Новая ставка, % (пусто — неизвестна)", text: $rate).textFieldStyle(BeeTextFieldStyle())
            Text("Предыдущий срок и его условия сохранятся. Неподтверждённые проценты не добавляются к остатку автоматически.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear { start = contract.end?.rawValue ?? ""; end = contract.end?.adding(365).rawValue ?? ""; rate = contract.terms(on: contract.end ?? .today)?.deposit.renewalAnnualPercent ?? "" }
    }
}
struct DepositExitEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var contract: FinancialContract
    @State private var date = Day.today.rawValue
    @State private var adjustment = "0"
    @State private var fee = "0"
    @State private var tax = "0"
    @State private var destination: UUID?
    @State private var received = ""
    @State private var result: DepositExitScenario?
    @State private var error = ""
    @State private var confirmed = false
    var body: some View {
        EditorFrame(title: "Возврат депозита", canSave: confirmed && destination != nil, isDirty: true, height: 720, save: {
            guard let destination else { throw BudgetError.invalid("Выберите счёт возврата.") }
            let currency = (try? model.db?.account(contract.accountID).currency) ?? "RUB"
            let adjustment = try Money.parse(adjustment, currency: currency), fee = try Money.parse(fee, currency: currency), tax = try Money.parse(tax, currency: currency)
            let received = self.received.isEmpty ? nil : try Money.parse(self.received, currency: model.db?.accounts.first { $0.id == destination }?.currency ?? currency)
            try model.commit { try FinancialLedger.closeDeposit(contract.id, to: destination, interestAdjustment: adjustment, fee: fee, newTax: tax, receivedAmount: received, date: Day(date), in: &$0) }
        }) {
            DayField(title: "Дата возврата", value: $date)
            Button("Рассчитать досрочный вариант") { do { guard let db = model.db else { return }; result = try FinancialEngine.depositExit(contract: contract, db: db, exitOn: Day(date)); if let amount = result?.interestAdjustment { adjustment = Money.string(amount, currency: currency) }; fee = Money.string(result?.fee ?? 0, currency: currency); error = "" } catch { self.error = error.localizedDescription } }
            if let result { FinanceValue(title: "Уже выплачено процентов", amount: result.previouslyPaidInterest, currency: currency); FinanceValue(title: "Пересчитанные проценты", amount: result.recomputedInterest, currency: currency); FinanceValue(title: "Возврат до нового налога", amount: result.returnBeforeNewTax, currency: currency); Text(result.accuracy.title).beeFont(.caption); ForEach(result.notes, id: \.self) { Text($0).beeFont(.caption).foregroundStyle(BeeStyle.muted) } }
            if !error.isEmpty { Text(error).foregroundStyle(BeeStyle.warning) }
            TextField("Разница процентов банка, + / −", text: $adjustment).textFieldStyle(BeeTextFieldStyle())
            TextField("Комиссия закрытия", text: $fee).textFieldStyle(BeeTextFieldStyle())
            TextField("Новый налог (ранее удержанный не повторять)", text: $tax).textFieldStyle(BeeTextFieldStyle())
            BeePicker("Вернуть на счёт", selection: $destination) { Text("Выберите").tag(nil as UUID?); ForEach(model.db?.accounts.filter { !$0.archived && $0.id != contract.accountID } ?? []) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) } }
            TextField("Фактически получено в другой валюте", text: $received).textFieldStyle(BeeTextFieldStyle())
            Toggle("Сверено с документом банка; закрыть договор", isOn: $confirmed)
        }
    }
    private var currency: String { (try? model.db?.account(contract.accountID).currency) ?? "RUB" }
}
