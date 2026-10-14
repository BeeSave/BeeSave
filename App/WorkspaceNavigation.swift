import SwiftUI
import AppKit
import BudgetCore
import BudgetPresentation

extension AppModel {
    var backDestinationTitle: String {
        guard let route = navigation.history.last else { return "Назад" }
        let title: String
        switch route.section {
        case .overview: title = route.section.title
        case .plan: title = route.planPage == .calendar ? route.calendarScope.title : route.planPage.title
        case .projects: title = route.objectID.flatMap { id in (db?.projects.first { $0.id == id }).map { $0.name + " · " + route.projectPage.title } } ?? route.section.title
        case .accounts: title = route.objectID.flatMap { id in db?.accounts.first { $0.id == id }?.name } ?? route.section.title
        case .operations: title = route.operationsPage.title
        }
        return "Назад: " + title
    }
    func navigate(_ route: WorkspaceRoute) {
        guard db != nil, !updateFrozen, !updateVerificationPending else { return }
        guard updateForms.isEmpty, sheet == nil else { showNotice("Сохраните или закройте открытую форму перед переходом."); return }
        objectWillChange.send()
        navigation.go(to: route)
    }
    func navigateBack() {
        guard db != nil, !updateFrozen, !updateVerificationPending, updateForms.isEmpty, sheet == nil else { return }
        objectWillChange.send()
        navigation.back()
    }
    func navigateLegacy(_ section: SectionID) {
        guard db != nil, !updateFrozen, !updateVerificationPending, updateForms.isEmpty, sheet == nil else { return }
        switch section {
        case .dashboard: navigate(WorkspaceRoute(.overview))
        case .accounts: navigate(WorkspaceRoute(.accounts, objectID: historyAccount))
        case .projects: navigate(WorkspaceRoute(.projects, objectID: planningProjectID))
        case .planning: navigate(WorkspaceRoute(.plan))
        case .financialCalendar: navigate(WorkspaceRoute(.plan, calendar: .contracts))
        case .operations: navigate(WorkspaceRoute(.operations))
        case .budgets: navigate(WorkspaceRoute(.operations, operations: .budgets))
        case .references: navigate(WorkspaceRoute(.operations, operations: .references))
        case .expenses, .incomes:
            let route = WorkspaceRoute(.operations)
            navigation.updateContext(for: route) { $0.journal = section == .expenses ? .expenses : .incomes }
            navigate(route)
        }
    }
    func updateWorkspaceContext(_ route: WorkspaceRoute, notifyViews: Bool = true, _ change: (inout WorkspaceContext) -> Void) {
        guard db != nil else { return }
        let original = navigation.context(for: route); var candidate = original; change(&candidate)
        guard candidate != original else { return }
        if notifyViews { objectWillChange.send() }
        navigation.updateContext(for: route) { $0 = candidate }
    }
    func newPlanFlow(_ purpose: PlanPurpose) {
        sheet = SheetRoute(kind: .planFlow, operationKind: purpose == .income ? .income : .expense, planPurpose: purpose)
    }
    func openPlannedPayments() {
        navigate(WorkspaceRoute(.plan, calendar: .scheduled))
    }
}

struct WorkspacePages<Page: Identifiable & Hashable>: View {
    var title: String
    var pages: [Page]
    var selected: Page
    var label: (Page) -> String
    var select: (Page) -> Void
    var body: some View {
        WrappingLayout(spacing: 8) {
            ForEach(pages) { page in
                Button(label(page)) { select(page) }
                    .buttonStyle(BeeRowStyle()).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(selected == page ? BeeStyle.controlAccent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityAddTraits(selected == page ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Restore the position of a real native scroll view, without a second financial state.
struct WorkspaceScrollMemory: NSViewRepresentable {
    @EnvironmentObject var model: AppModel
    var route: WorkspaceRoute
    var table = false
    func makeCoordinator() -> Coordinator { Coordinator(model: model, route: route, table: table) }
    func makeNSView(context: Context) -> Marker { let view = Marker(); view.attach = { [weak coordinator = context.coordinator] marker in coordinator?.attach(marker) }; return view }
    func updateNSView(_ view: Marker, context: Context) { context.coordinator.model = model; view.attach?(view) }
    static func dismantleNSView(_ view: Marker, coordinator: Coordinator) { coordinator.detach() }
    final class Marker: NSView {
        var attach: ((Marker) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { DispatchQueue.main.async { [weak self] in if let self { self.attach?(self) } } } }
    }
    @MainActor final class Coordinator {
        weak var model: AppModel?; let route: WorkspaceRoute; let table: Bool
        weak var scroll: NSScrollView?; var observer: NSObjectProtocol?
        init(model: AppModel, route: WorkspaceRoute, table: Bool) { self.model = model; self.route = route; self.table = table }
        func tableScroll(in view: NSView) -> NSScrollView? {
            if let value = view as? NSScrollView, value.documentView is NSTableView { return value }
            for child in view.subviews { if let found = tableScroll(in: child) { return found } }; return nil
        }
        func synchronizeHeader(_ scroll: NSScrollView) {
            guard table, let header = (scroll.documentView as? NSTableView)?.headerView,
                  let clip = header.superview as? NSClipView else { return }
            let x = scroll.contentView.bounds.origin.x
            if clip.bounds.origin.x != x { clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y)) }
        }
        func attach(_ marker: NSView) {
            guard scroll == nil else { return }
            var candidate = table ? nil : marker.enclosingScrollView
            if table {
                var parent = marker.superview
                for _ in 0..<6 { guard let value = parent else { break }; if let found = tableScroll(in: value) { candidate = found; break }; parent = value.superview }
            }
            guard let candidate else { return }
            scroll = candidate; candidate.contentView.postsBoundsChangedNotifications = true
            let context = model?.navigation.context(for: route)
            let y = (table ? context?.tableScrollOffset : context?.scrollOffset) ?? 0
            let x = table ? context?.tableScrollX ?? 0 : candidate.contentView.bounds.origin.x
            if x > 0 || y > 0 { candidate.contentView.scroll(to: NSPoint(x: x, y: y)); candidate.reflectScrolledClipView(candidate.contentView) }
            synchronizeHeader(candidate)
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: candidate.contentView, queue: .main) { [weak self, weak candidate] _ in
                Task { @MainActor in guard let self, let candidate else { return }; self.synchronizeHeader(candidate); self.model?.updateWorkspaceContext(self.route, notifyViews: false) { context in
                    if self.table { context.tableScrollOffset = candidate.contentView.bounds.origin.y; context.tableScrollX = candidate.contentView.bounds.origin.x }
                    else { context.scrollOffset = candidate.contentView.bounds.origin.y }
                } }
            }
        }
        func detach() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil; scroll = nil }
    }
}
