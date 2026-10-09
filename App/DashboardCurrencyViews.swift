import SwiftUI
import BudgetCore
import BudgetPresentation

private func rateDescription(_ rate: ResolvedRate) -> String {
    guard let date = rate.date else { return "Основная валюта" }
    return [date.rawValue, rate.provider ?? "", rate.stale() ? "устарел" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

struct DashboardExchangeRates: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.beeAppearance) private var appearance
    var wrapping = true
    var body: some View {
        if let db = model.db, !db.settings.selectedDashboardCurrencies.isEmpty {
            if wrapping {
                DashboardRateLayout(spacing: 12 * appearance.scale) { positions(db) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else { HStack(spacing: 12 * appearance.scale) { positions(db) } }
        }
    }
    @ViewBuilder private func positions(_ db: Database) -> some View {
        ForEach(db.settings.selectedDashboardCurrencies, id: \.self) { code in
            ExchangeRatePosition(code: code, base: db.settings.baseCurrency, rates: db.rates)
        }
    }
}

/// Each wrapped row shares the right edge of the dashboard cards.
private struct DashboardRateLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        return CGSize(width: width, height: rows(width, subviews).last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(bounds.width, subviews) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
        }
    }
    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var result: [Row] = []; var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let gap = row.indices.isEmpty ? 0 : spacing
            if !row.indices.isEmpty && row.width + gap + size.width > width {
                result.append(row); row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height); row.indices.append(index)
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }
}

private struct ExchangeRatePosition: View {
    @Environment(\.beeAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @EnvironmentObject private var model: AppModel
    private var reduceTransparency: Bool {
        #if DEBUG && UI_SMOKE
        return systemReduceTransparency || model.previewReduceTransparency
        #else
        return systemReduceTransparency
        #endif
    }
    var code: String
    var base: String
    var rates: [FXRate]
    private var result: Result<ResolvedRate?, Error> { Result { try Reports.resolvedRate(from: code, to: base, rates: rates, on: .today) } }
    private var title: String {
        switch result {
        case .success(let rate?): return "1 \(code) = \(DisplayFormat.rate(rate.value)) \(base)"
        case .success(nil): return "\(code) → \(base) · Нет курса"
        case .failure: return "\(code) → \(base) · Ошибка курса"
        }
    }
    private var detail: String {
        switch result {
        case .success(let rate?): return rateDescription(rate)
        case .success(nil): return "Нет доступного курса. Обновите или добавьте курс в настройках «Валюты и курсы»."
        case .failure(let error): return error.localizedDescription
        }
    }
    private var stale: Bool { if case .success(let rate?) = result { return rate.stale() }; return false }
    var body: some View {
        Group {
            if reduceTransparency { content.background(BeeStyle.surface, in: .capsule).overlay { Capsule().strokeBorder(BeeStyle.line, lineWidth: 1) } }
            else { content.glassEffect(.regular, in: .capsule) }
        }.help(title + " · " + detail)
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(detail)
    }
    private var content: some View {
        HStack(spacing: 6 * appearance.scale) {
            Text(title).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            if stale { Image(systemName: "exclamationmark.triangle").foregroundStyle(BeeStyle.warning).accessibilityHidden(true) }
        }.beeFont(.body).foregroundStyle(BeeStyle.onBackground)
            .padding(.horizontal, 16 * appearance.scale).padding(.vertical, 10 * appearance.scale)
    }
}

struct DashboardCurrencySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var choosing = false
    private var selected: [String] { model.db?.settings.selectedDashboardCurrencies ?? [] }
    private var base: String { model.db?.settings.baseCurrency ?? "RUB" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Валюты на Главной").beeFont(.headline); Spacer(); Text("\(selected.count) из 5").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
            Text("Курсы относительно базовой валюты. До 5 валют; основная валюта исключена.").beeFont(.caption).foregroundStyle(BeeStyle.muted).fixedSize(horizontal: false, vertical: true)
            if selected.isEmpty { Text("Курсы на Главной скрыты").foregroundStyle(BeeStyle.muted) }
            ForEach(selected, id: \.self) { code in
                HStack {
                    Text((try? Currency.get(code).label) ?? code).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Убрать", systemImage: "minus.circle") { model.setDashboardCurrencies(selected.filter { $0 != code }) }.labelStyle(.iconOnly).focusable().onKeyPress(keys: [.return, .space]) { _ in model.setDashboardCurrencies(selected.filter { $0 != code }); return .handled }.accessibilityLabel("Убрать валюту " + code)
                }
            }
            Button("Добавить валюту", systemImage: "plus") { search = ""; choosing = true }.focusable().onKeyPress(keys: [.return, .space]) { _ in guard selected.count < DashboardCurrencySelection.limit else { return .ignored }; search = ""; choosing = true; return .handled }.disabled(selected.count >= DashboardCurrencySelection.limit)
                .popover(isPresented: $choosing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Добавить валюту").beeFont(.headline)
                        TextField("Найти валюту", text: $search).textFieldStyle(BeeTextFieldStyle())
                        ScrollView { LazyVStack(alignment: .leading) {
                            ForEach(Currency.catalog.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }) { currency in
                                Button { model.setDashboardCurrencies(selected + [currency.code]); choosing = false } label: {
                                    HStack { Text(currency.label); Spacer(); if selected.contains(currency.code) { Image(systemName: "checkmark") }; if currency.code == base { Text("Основная валюта").beeFont(.caption).foregroundStyle(BeeStyle.muted) } }
                                }.buttonStyle(BeeRowStyle()).focusable().onKeyPress(keys: [.return, .space]) { _ in guard currency.code != base, !selected.contains(currency.code), selected.count < DashboardCurrencySelection.limit else { return .ignored }; model.setDashboardCurrencies(selected + [currency.code]); choosing = false; return .handled }.disabled(currency.code == base || selected.contains(currency.code) || selected.count >= DashboardCurrencySelection.limit).padding(5)
                            }
                        } }.frame(height: 260)
                        Button("Отмена") { choosing = false }.keyboardShortcut(.cancelAction)
                    }.padding(18).frame(width: 360).foregroundStyle(.primary)
                }
            if selected.count == DashboardCurrencySelection.limit { Text("Достигнут лимит 5 валют. Уберите одну, чтобы добавить другую.").beeFont(.caption).foregroundStyle(BeeStyle.muted).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading).beeCard()
    }
}

struct DashboardAccountBalances: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.beeAppearance) private var appearance
    var db: Database
    var filters: Filters
    @State private var tableWidth: CGFloat = 0
    private var result: Result<([AccountBalanceRow], Valuation), Error> {
        Result {
            let rows = try Reports.accountBalances(db, filters: filters, currency: db.settings.baseCurrency)
            return (rows, try Reports.total(rows.map(\.reportRow)))
        }
    }
    var body: some View {
        switch result {
        case .success(let (rows, total)):
            PartialValue(value: total, currency: db.settings.baseCurrency, large: true)
            Text("Текущие остатки · в основной валюте").beeFont(.caption).foregroundStyle(BeeStyle.muted)
            Text("Период, категории и проекты к остаткам не применяются.").beeFont(.caption).foregroundStyle(BeeStyle.muted).fixedSize(horizontal: false, vertical: true)
            if total.partial { Text("Нет курса: " + total.currencies.sorted().joined(separator: ", ")).beeFont(.caption).foregroundStyle(BeeStyle.warning) }
            if rows.isEmpty { Text("Нет счетов по выбранным фильтрам").foregroundStyle(BeeStyle.muted) }
            else { balancesTable(Array(rows.prefix(3))) }
            Button("Все счета →") { model.historyAccount = nil; model.section = .accounts }.buttonStyle(BeeRowStyle()).beeFont(.caption).foregroundStyle(BeeStyle.muted)
        case .failure(let error):
            Label("Не удалось рассчитать остатки", systemImage: "exclamationmark.triangle").foregroundStyle(BeeStyle.negative)
            Text(error.localizedDescription).beeFont(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func balancesTable(_ rows: [AccountBalanceRow]) -> some View {
        let originalWidth = amountWidth(rows.map { DisplayFormat.money($0.amount, currency: $0.account.currency) }, header: "В валюте счёта")
        let convertedWidth = amountWidth(rows.map { $0.value.partial ? "Нет курса" : DisplayFormat.money($0.value.known, currency: db.settings.baseCurrency) }, header: "В основной валюте")
        let nameWidth = max(120 * appearance.scale, tableWidth - originalWidth - convertedWidth - 62)
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 16) {
                    Text("Счёт").frame(width: nameWidth, alignment: .leading)
                    Text("В валюте счёта").fixedSize().frame(width: originalWidth, alignment: .trailing)
                    Text("В основной валюте").fixedSize().frame(width: convertedWidth, alignment: .trailing).help("Основная валюта: " + db.settings.baseCurrency).accessibilityLabel("В основной валюте, " + db.settings.baseCurrency)
                    Color.clear.frame(width: 14)
                }.beeFont(.caption).foregroundStyle(BeeStyle.muted).fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach(rows) { row in
                    Button { model.openHistory(row.id) } label: {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.account.name).fixedSize(horizontal: false, vertical: true)
                                if row.account.archived { Text("Архив").beeFont(.caption).foregroundStyle(BeeStyle.muted) }
                                if row.amount < 0 { Text("Отрицательный остаток").beeFont(.caption).foregroundStyle(BeeStyle.negative).fixedSize(horizontal: false, vertical: true) }
                            }.frame(width: nameWidth, alignment: .leading).multilineTextAlignment(.leading)
                            Text(DisplayFormat.money(row.amount, currency: row.account.currency)).beeFont(.body).monospacedDigit().fixedSize().foregroundStyle(row.amount < 0 ? BeeStyle.negative : BeeStyle.text).frame(width: originalWidth, alignment: .trailing)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(row.value.partial ? "Нет курса" : DisplayFormat.money(row.value.known, currency: db.settings.baseCurrency)).beeFont(.body).monospacedDigit().fixedSize().foregroundStyle(row.value.partial ? BeeStyle.warning : row.value.known < 0 ? BeeStyle.negative : BeeStyle.text)
                                if let rate = row.rate, row.account.currency != db.settings.baseCurrency {
                                    Text(rateDescription(rate)).beeFont(.caption).foregroundStyle(rate.stale() ? BeeStyle.warning : BeeStyle.muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }.frame(width: convertedWidth, alignment: .trailing)
                            Image(systemName: "chevron.right").beeFont(.caption).frame(width: 14)
                        }.padding(.vertical, 4).fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(BeeRowStyle()).focusable().onKeyPress(keys: [.return, .space]) { _ in model.openHistory(row.id); return .handled }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
                        .accessibilityLabel("История счёта \(row.account.name), \(DisplayFormat.money(row.amount, currency: row.account.currency)), " + (row.value.partial ? "Нет курса" : DisplayFormat.money(row.value.known, currency: db.settings.baseCurrency)))
                }
            }.padding(.bottom, 4).fixedSize(horizontal: false, vertical: true)
        }.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
    }
    private func amountWidth(_ values: [String], header: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 15 * appearance.scale, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: BeeFont.caption.size * appearance.scale)
        let headerWidth = (header as NSString).size(withAttributes: [.font: headerFont]).width + 4
        return max(110 * appearance.scale, headerWidth, values.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 4 }.max() ?? 0)
    }
}
