import SwiftUI
import BudgetCore

struct FinancialBankCalendarEditor: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var id: UUID?
    var onSave: (UUID) -> Void
    @State private var name = ""
    @State private var years = String(FinanceMath.year(.today))
    @State private var holidays = ""
    @State private var exceptions = ""
    @State private var source = "Введено вручную"
    var body: some View {
        EditorFrame(title: "Календарь банка", isDirty: true, height: 650, save: save) {
            FormField(title: "Название") { TextField("Мой банковский календарь", text: $name).textFieldStyle(BeeTextFieldStyle()) }
            FormField(title: "Годы подтверждённого покрытия", hint: "Через запятую, например 2026, 2027. В других годах рабочий день остаётся неизвестным.") { TextField("2026, 2027", text: $years).textFieldStyle(BeeTextFieldStyle()) }
            FormField(title: "Праздники · одна дата YYYY-MM-DD в строке") { TextEditor(text: $holidays).frame(height: 110).border(BeeStyle.line.opacity(0.3)) }
            FormField(title: "Рабочие выходные · одна дата в строке") { TextEditor(text: $exceptions).frame(height: 90).border(BeeStyle.line.opacity(0.3)) }
            FormField(title: "Источник") { TextField("Документ банка / ссылка / ручной ввод", text: $source).textFieldStyle(BeeTextFieldStyle()) }
            Text("Суббота и воскресенье считаются выходными. Рабочее исключение имеет приоритет над праздником. Изменение выбранного календаря пересчитает связанные договоры.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
        }.onAppear {
            guard let value = model.db?.financeData.calendars.first(where: { $0.id == id }) else { return }
            name = value.name; years = value.years.map(String.init).joined(separator: ", "); holidays = value.holidays.map(\.rawValue).joined(separator: "\n"); exceptions = value.workingExceptions.map(\.rawValue).joined(separator: "\n"); source = value.source
        }
    }
    private func save() throws {
        try Ledger.nonempty(name); try Ledger.nonempty(source)
        let pieces = years.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, numbers = pieces.compactMap(Int.init)
        guard !numbers.isEmpty, pieces.count == numbers.count, numbers.allSatisfy({ (1...9999).contains($0) }) else { throw BudgetError.invalid("Укажите годы через запятую.") }
        func days(_ text: String) throws -> [Day] { try Array(Set(text.split(whereSeparator: { $0.isNewline }).map { try Day($0.trimmingCharacters(in: .whitespaces)) })).sorted() }
        var calendar = BankCalendar(name: name, years: Array(Set(numbers)).sorted(), holidays: try days(holidays), workingExceptions: try days(exceptions), source: source)
        guard (calendar.holidays + calendar.workingExceptions).allSatisfy({ calendar.years.contains(FinanceMath.year($0)) }) else { throw BudgetError.invalid("Все даты должны входить в заданные годы покрытия.") }
        calendar.id = id ?? calendar.id
        try model.commit { db in var book = db.financeData; if let index = book.calendars.firstIndex(where: { $0.id == calendar.id }) { book.calendars[index] = calendar } else { book.calendars.append(calendar) }; db.finances = book }
        onSave(calendar.id); dismiss()
    }
}
