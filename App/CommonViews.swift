import SwiftUI
import BudgetCore

struct CurrencyPicker: View {
    var title: String; @Binding var selection: String; @State private var search = ""
    var body: some View { HStack { Picker(title, selection: $selection) { ForEach(Currency.catalog.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.code == selection }) { c in Text(c.label).tag(c.code) } }.frame(minWidth: 180); TextField("Поиск валюты", text: $search).frame(width: 130) } }
}
struct DayField: View {
    var title: String; @Binding var value: String
    var body: some View { TextField(title + " (YYYY-MM-DD)", text: $value).textFieldStyle(.roundedBorder) }
}
struct EditorFrame<Content: View>: View {
    var title: String; var saveTitle = "Сохранить"; var canSave = true; var save: () throws -> Void; @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) var dismiss; @EnvironmentObject var model: AppModel; @State private var error = ""; @State private var discard = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.title2.bold()); Spacer() }.padding(24)
            ScrollView { VStack(alignment: .leading, spacing: 16) { content(); if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }.padding(.horizontal, 24).padding(.bottom, 24) }
            Divider(); HStack { Text("При блокировке несохранённая форма закроется.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Отмена") { discard = true }.keyboardShortcut(.cancelAction); Button(saveTitle) { do { try save(); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave || model.busy) }.padding(20)
        }.frame(width: 650, height: 650).interactiveDismissDisabled()
        .confirmationDialog("Сохранить изменения перед закрытием?", isPresented: $discard) { Button("Сохранить") { do { try save(); dismiss() } catch { self.error = error.localizedDescription } }; Button("Отказаться", role: .destructive) { dismiss() }; Button("Продолжить редактирование", role: .cancel) {} }
    }
}
struct FilterBar: View {
    @EnvironmentObject var model: AppModel; @Binding var filters: Filters; var showParticipation = true; var allowCategoryProject = true
    @State private var start = ""; @State private var end = ""
    var body: some View { VStack(alignment: .leading, spacing: 8) {
        HStack {
            TextField("От YYYY-MM-DD", text: $start).frame(width: 135).onSubmit(applyDates)
            TextField("До YYYY-MM-DD", text: $end).frame(width: 135).onSubmit(applyDates)
            Button("Применить даты", action: applyDates)
            Button("Этот месяц") { filters.start = .today.firstOfMonth; filters.end = .today; syncDates() }
            Spacer(); Toggle("Архивные счета", isOn: $filters.includeArchived).toggleStyle(.checkbox)
        }
        HStack {
            Menu("Счета: \(filters.accounts.isEmpty ? "все" : String(filters.accounts.count))") { ForEach(model.db?.accounts ?? []) { a in Toggle(a.name, isOn: Binding(get: { filters.accounts.contains(a.id) }, set: { if $0 { filters.accounts.insert(a.id) } else { filters.accounts.remove(a.id) } })) }; Button("Все счета") { filters.accounts = [] } }
            if allowCategoryProject {
                Menu("Категории: \(filters.categories.isEmpty ? "все" : String(filters.categories.count))") { ForEach(model.db?.categories ?? []) { c in Toggle((model.db?.categoryPath(c.id) ?? c.name) + (c.kind == .income ? " · доход" : ""), isOn: Binding(get: { filters.categories.contains(c.id) }, set: { if $0 { filters.categories.insert(c.id) } else { filters.categories.remove(c.id) } })) }; Button("Все категории") { filters.categories = [] } }
                Picker("Проект", selection: $filters.projectID) { Text("Все").tag(nil as UUID?); ForEach(model.db?.projects ?? []) { Text($0.name).tag(Optional($0.id)) } }.frame(maxWidth: 200)
            }
            Picker("Исходная валюта", selection: $filters.currency) { Text("Все").tag(nil as String?); ForEach(Currency.catalog) { Text($0.code).tag(Optional($0.code)) } }.frame(maxWidth: 190)
            if showParticipation { Picker("Бюджет", selection: $filters.participation) { Text("Все").tag(Participation.all); Text("Вне бюджетов").tag(Participation.outside); Text("Без месячного").tag(Participation.noMonthly); Text("Без проектного").tag(Participation.noProject) }.frame(maxWidth: 210) }
        }.controlSize(.small)
    }.textFieldStyle(.roundedBorder).onAppear(perform: syncDates).onChange(of: filters.start) { syncDates() }.onChange(of: filters.end) { syncDates() } }
    func syncDates() { start = filters.start?.rawValue ?? ""; end = filters.end?.rawValue ?? "" }
    func applyDates() { do { let s = start.isEmpty ? nil : try Day(start); let e = end.isEmpty ? nil : try Day(end); guard s == nil || e == nil || s! <= e! else { throw BudgetError.invalid("Начало периода позже конца.") }; filters.start = s; filters.end = e } catch { model.error = error.localizedDescription } }
}
func confirmDeletion(_ name: String, consequence: String) -> Bool {
    let a = NSAlert(); a.messageText = "Удалить «\(name)»?"; a.informativeText = consequence; a.addButton(withTitle: "Удалить"); a.addButton(withTitle: "Отмена"); return a.runModal() == .alertFirstButtonReturn
}
struct EmptyState: View {
    var title: String; var detail: String; var icon = "tray"
    var body: some View { ContentUnavailableView(title, systemImage: icon, description: Text(detail)).frame(maxWidth: .infinity, minHeight: 150) }
}
