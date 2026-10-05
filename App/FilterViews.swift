import SwiftUI
import BudgetCore
import BudgetPresentation

extension Participation {
    var title: String { switch self { case .all: "Все операции"; case .outside: "Вне бюджетов"; case .noMonthly: "Без месячного бюджета"; case .noProject: "Без проектного бюджета" } }
}

struct FilterBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var filters: Filters
    var showParticipation = true
    var allowCategoryProject = true
    var kind: OperationKind?
    var kinds: Set<OperationKind>?
    var fixedAccount: UUID?
    var operationIDs: [UUID]?
    var resetPeriod: Filters?
    @State private var narrow = false
    @State private var calendarOpen = false
    @State private var filtersOpen = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { filtersOpen = false; calendarOpen = true } label: { Label(CalendarDays.range(filters), systemImage: "calendar"); Image(systemName: "chevron.down") }
                    .popover(isPresented: $calendarOpen) { DateRangePopover(filters: $filters, narrow: narrow, close: { calendarOpen = false }) }
                Button { calendarOpen = false; filtersOpen = true } label: { Label("Фильтры", systemImage: "slider.horizontal.3"); let count = FilterDraft(countFilters).activeCount; if count > 0 { Text("\(count)").font(.caption.bold()) } }
                    .popover(isPresented: $filtersOpen) { FilterPanel(filters: $filters, showParticipation: showParticipation, allowCategoryProject: allowCategoryProject, kind: kind, kinds: kinds, fixedAccount: fixedAccount, operationIDs: operationIDs, resetPeriod: resetPeriod, narrow: narrow, close: { filtersOpen = false }) }
                Spacer()
            }
            if let db = model.db {
                WrappingLayout(spacing: 6) {
                    if !filters.accounts.isEmpty && fixedAccount == nil { chip("Счета: \(filters.accounts.count)") { filters.accounts = [] } }
                    if allowCategoryProject && !filters.categories.isEmpty { chip("Категории: \(filters.categories.count)") { filters.categories = [] } }
                    if allowCategoryProject, let p = db.projects.first(where: { $0.id == filters.projectID }) { chip(p.name) { filters.projectID = nil } }
                    if let currency = filters.currency { chip(currency) { filters.currency = nil } }
                    if showParticipation && filters.participation != .all { chip(filters.participation.title) { filters.participation = .all } }
                    if !filters.includeArchived { chip("Без архива") { filters.includeArchived = true } }
                }
            }
        }.onGeometryChange(for: Bool.self) { $0.size.width < 630 } action: { narrow = $0 }
    }
    private var countFilters: Filters { var value = filters; if fixedAccount != nil { value.accounts = [] }; return value }
    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { HStack(spacing: 5) { Text(title).lineLimit(1); Image(systemName: "xmark").font(.caption2) } }.buttonStyle(.plain).font(.caption).padding(.horizontal, 8).padding(.vertical, 5).background(BeeStyle.selected, in: Capsule()).foregroundStyle(BeeStyle.text).accessibilityLabel("Убрать фильтр: " + title)
    }
}

struct DateRangePopover: View {
    @Binding var filters: Filters
    var narrow = false
    var close: () -> Void
    @State private var draft = DateRangeDraft(start: nil, end: nil)
    @State private var month = Day.today.firstOfMonth
    @State private var error = ""
    @FocusState private var dayFocus: Day?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Период").font(.title3.bold()); Spacer(); Text(draft.choosingEnd ? "Выберите последний день" : "Выберите первый день").font(.caption).foregroundStyle(BeeStyle.muted) }
            WrappingLayout(spacing: 8) { ForEach(PeriodPreset.allCases, id: \.self) { preset in Button(preset.title) { draft.preset(preset, today: .today); month = (draft.start ?? .today).firstOfMonth; error = "" } } }
            HStack { Button { month = CalendarDays.month(month, offset: -1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Предыдущий месяц"); Spacer(); Button("Сегодня") { month = Day.today.firstOfMonth }; Spacer(); Button { month = CalendarDays.month(month, offset: 1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Следующий месяц") }
            HStack(alignment: .top, spacing: 20) { MonthCalendar(month: month, draft: $draft, focused: $dayFocus, navigate: navigate); if !narrow { MonthCalendar(month: CalendarDays.month(month, offset: 1), draft: $draft, focused: $dayFocus, navigate: navigate) } }
            if draft.start != nil || draft.end != nil { HStack(spacing: 18) { boundary("С", day: $draft.start); boundary("По", day: $draft.end) } }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(BeeStyle.negative) }
            Divider()
            Text(draft.start == nil && draft.end == nil ? "Без ограничения дат" : "Границы включены в период").font(.caption).foregroundStyle(BeeStyle.muted)
            HStack { Spacer(); Button("Отмена", action: close).keyboardShortcut(.cancelAction); Button("Применить") { do { filters = try draft.apply(to: filters); close() } catch { self.error = error.localizedDescription } }.buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction).disabled(draft.choosingEnd) }

        }.padding(20).frame(width: narrow ? 350 : 620).foregroundStyle(BeeStyle.text).background(BeeStyle.surface).onAppear { draft = DateRangeDraft(start: filters.start, end: filters.end); month = (filters.start ?? .today).firstOfMonth }
    }
    private func navigate(_ day: Day) { if day < month { month = day.firstOfMonth }; if day >= CalendarDays.month(month, offset: narrow ? 1 : 2) { month = day.firstOfMonth }; dayFocus = day }
    private func boundary(_ title: String, day: Binding<Day?>) -> some View {
        FormField(title: title) { DatePicker(title, selection: Binding(get: { CalendarDays.localDate(day.wrappedValue ?? draft.start ?? .today) }, set: { day.wrappedValue = CalendarDays.day($0); draft = DateRangeDraft(start: draft.start, end: draft.end) }), displayedComponents: .date).labelsHidden().datePickerStyle(.field).environment(\.locale, Locale(identifier: "ru_RU")) }
    }
}

struct MonthCalendar: View {
    var month: Day
    @Binding var draft: DateRangeDraft
    var focused: FocusState<Day?>.Binding
    var navigate: (Day) -> Void
    var body: some View {
        VStack(spacing: 10) {
            Text(monthTitle).font(.headline).frame(maxWidth: .infinity)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { Text($0).font(.caption).foregroundStyle(BeeStyle.muted).frame(height: 22) }
                ForEach(Array(CalendarDays.cells(month).enumerated()), id: \.offset) { _, day in
                    if let day { Button { draft.select(day); focused.wrappedValue = day } label: {
                        Text(String(Day.calendar.component(.day, from: day.date))).font(.subheadline.weight(day == draft.start || day == draft.end ? .bold : .regular)).frame(maxWidth: .infinity).frame(height: 28)
                            .foregroundStyle(day == draft.start || day == draft.end ? BeeStyle.honeyText : BeeStyle.text)
                            .background(day == draft.start || day == draft.end ? BeeStyle.honey : inRange(day) ? BeeStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay { if day == .today { RoundedRectangle(cornerRadius: 6).stroke(BeeStyle.line, lineWidth: 1) } }
                    }.buttonStyle(.plain).focused(focused, equals: day).accessibilityLabel(CalendarDays.label(day, full: true)).accessibilityValue(day == draft.start && day == draft.end ? "Начало и конец периода" : day == draft.start ? "Начало периода" : day == draft.end ? "Конец периода" : inRange(day) ? "В выбранном периоде" : "")
                        .onKeyPress(.leftArrow) { move(day, by: -1); return .handled }.onKeyPress(.rightArrow) { move(day, by: 1); return .handled }.onKeyPress(.upArrow) { move(day, by: -7); return .handled }.onKeyPress(.downArrow) { move(day, by: 7); return .handled }
                    } else { Color.clear.frame(height: 28) }
                }
            }
        }.frame(maxWidth: .infinity)
    }
    private var monthTitle: String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = Day.calendar.timeZone; formatter.dateFormat = "LLLL yyyy"; return formatter.string(from: month.date).capitalized }
    private func inRange(_ day: Day) -> Bool { guard let start = draft.start else { return false }; return day >= start && day <= (draft.end ?? start) }
    private func move(_ day: Day, by offset: Int) { navigate(day.adding(offset)) }
}

struct FilterPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var filters: Filters
    var showParticipation: Bool
    var allowCategoryProject: Bool
    var kind: OperationKind?
    var kinds: Set<OperationKind>?
    var fixedAccount: UUID?
    var operationIDs: [UUID]?
    var resetPeriod: Filters?
    var narrow = false
    var close: () -> Void
    @State private var draft = FilterDraft(Filters())
    @State private var accountSearch = ""
    @State private var categorySearch = ""
    @State private var count: Int?
    @State private var error = ""
    @State private var generation = UUID()
    @State private var countTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Фильтры").font(.title3.bold()); Spacer(); Text("Изменения применятся после подтверждения").font(.caption).foregroundStyle(BeeStyle.muted) }
            if let db = model.db { ScrollView { let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 22)) : AnyLayout(HStackLayout(alignment: .top, spacing: 22)); layout {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Счета").font(.headline)
                    if let account = db.accounts.first(where: { $0.id == fixedAccount }) { Label(account.name, systemImage: "lock").font(.subheadline); Text("Счёт истории закреплён").font(.caption).foregroundStyle(BeeStyle.muted) }
                    else {
                        TextField("Найти счёт", text: $accountSearch).textFieldStyle(.roundedBorder)
                        ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(db.accounts.filter { accountSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(accountSearch) }) { a in Toggle(a.name + (a.archived ? " · архив" : ""), isOn: membership(a.id, set: $draft.value.accounts)).toggleStyle(.checkbox) } } }.frame(height: 170)
                        Text("Без выбора — все счета").font(.caption).foregroundStyle(BeeStyle.muted)
                    }
                    if showParticipation { FormField(title: "Участие в бюджетах") { Picker("Участие в бюджетах", selection: $draft.value.participation) { ForEach(Participation.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden() } }
                    Toggle("Включать архивные счета", isOn: $draft.value.includeArchived).toggleStyle(.checkbox)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 9) {
                    if allowCategoryProject {
                        Text("Категории").font(.headline)
                        TextField("Найти категорию", text: $categorySearch).textFieldStyle(.roundedBorder)
                        ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(db.categories.filter { (kind == nil || $0.kind == kind) && (categorySearch.isEmpty || db.categoryPath($0.id).localizedCaseInsensitiveContains(categorySearch)) }.sorted { db.categoryPath($0.id) < db.categoryPath($1.id) }) { c in
                            Toggle(db.categoryPath(c.id) + (kind == nil ? " · " + (c.kind == .expense ? "расходы" : "доходы") : "") + (c.archived ? " · архив" : ""), isOn: membership(c.id, set: $draft.value.categories)).toggleStyle(.checkbox).padding(.leading, c.parentID == nil ? 0 : 14)
                        } } }.frame(height: 170)
                        FormField(title: "Проект") { Picker("Проект", selection: $draft.value.projectID) { Text("Все проекты").tag(nil as UUID?); ForEach(db.projects) { Text($0.name + ($0.archived ? " · архив" : "")).tag(Optional($0.id)) } }.labelsHidden() }
                    }
                    FormField(title: "Исходная валюта операции") { Picker("Исходная валюта", selection: $draft.value.currency) { Text("Все валюты").tag(nil as String?); ForEach(Array(Set(db.accounts.map(\.currency))).sorted(), id: \.self) { Text($0).tag(Optional($0)) } }.labelsHidden() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } }.frame(maxHeight: narrow ? 360 : 390) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(BeeStyle.negative) }
            Divider()
            HStack { Text(count.map { "Найдено \(allowCategoryProject ? "записей" : "счетов"): \($0)" } ?? "Проверяем выборку…").font(.caption).foregroundStyle(BeeStyle.muted); Spacer(); Button("Сбросить") { draft.reset(today: .today, fixedAccount: fixedAccount, period: resetPeriod) } }
            HStack { Spacer(); Button("Отмена", action: close).keyboardShortcut(.cancelAction); Button("Применить") { do { guard let db = model.db else { return }; filters = try draft.apply(database: db, fixedAccount: fixedAccount); close() } catch { self.error = error.localizedDescription } }.buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction) }

        }.padding(20).frame(width: narrow ? 390 : 650).foregroundStyle(BeeStyle.text).background(BeeStyle.surface)
            .onAppear { draft = FilterDraft(filters); updateCount() }.onChange(of: draft.value) { updateCount() }.onChange(of: model.db?.revision) { updateCount() }.onDisappear { countTask?.cancel() }
    }
    private func membership(_ id: UUID, set: Binding<Set<UUID>>) -> Binding<Bool> { Binding(get: { set.wrappedValue.contains(id) }, set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } }) }
    private func updateCount() {
        countTask?.cancel(); count = nil; let token = UUID(); generation = token
        guard let db = model.db else { return }; let revision = db.revision; var candidate = draft.value; if let fixedAccount { candidate.accounts = [fixedAccount] }; let selectedKinds = kind.map { Set([$0]) } ?? kinds; let balances = !allowCategoryProject; let ids = operationIDs.map(Set.init)
        countTask = Task { let worker = Task.detached { if balances { return (try? Reports.balances(db, filters: candidate, currency: db.settings.reportCurrency).count) ?? 0 }; let rows = Reports.selected(db, filters: candidate, kinds: selectedKinds); return ids.map { ids in rows.filter { ids.contains($0.id) }.count } ?? rows.count }; let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() }); guard !Task.isCancelled, generation == token, model.db?.revision == revision else { return }; count = result }
    }
}
