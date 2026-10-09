import SwiftUI
import BudgetCore
import BudgetPresentation

struct CurrencyPicker: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    @Binding var selection: String
    var compact = false
    @State private var search = ""
    @State private var open = false
    var body: some View {
        Group { if compact { HStack(spacing: 7) { Text(title).beeFont(.caption); pickerButton } } else { FormField(title: title) { pickerButton } } }
    }
    private var pickerButton: some View {
            Button { search = ""; open = true } label: {
                HStack { Text(compact ? selection : ((try? Currency.get(selection).label) ?? selection)); if !compact { Spacer() }; Image(systemName: "chevron.down") }
            }.buttonStyle(BeeRowStyle()).popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).beeFont(.headline)
                    TextField("Найти валюту", text: $search).textFieldStyle(BeeTextFieldStyle())
                    ScrollView { LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Currency.catalog.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }) { currency in
                            Button { selection = currency.code; open = false } label: { HStack { Text(currency.label); Spacer(); if selection == currency.code { Image(systemName: "checkmark") } } }.buttonStyle(BeeRowStyle()).padding(7)
                        }
                    } }.frame(height: 260)
                    Button("Отмена") { open = false }.keyboardShortcut(.cancelAction)
                }.padding(18).frame(width: 330 * pow(appearanceStore.preferences.scale, 0.5)).foregroundStyle(.primary)
            }
    }
}

struct DayField: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    @Binding var value: String
    var body: some View {
        FormField(title: title) {
            BeeDatePicker(title, selection: Binding(get: { CalendarDays.localDate((try? Day(value)) ?? .today) }, set: { value = CalendarDays.day($0).rawValue }), displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field).environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }
}

struct EditorFrame<Content: View>: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    var saveTitle = "Сохранить"
    var canSave = true
    var isDirty = true
    var width: CGFloat = 580
    var height: CGFloat = 590
    var tintColor: Color = BeeStyle.controlAccent
    var onError: (String) -> Void = { _ in }
    var saveAsync: (() async throws -> Void)? = nil
    var save: () throws -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var error = ""
    @State private var discard = false
    @State private var submitting = false
    @State private var submitTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).beeFont(.title2.weight(.semibold)); Spacer() }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                    if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(BeeStyle.negative) }
                }.padding(.horizontal, 24).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if isDirty { Text("При блокировке незавершённая форма закроется.").beeFont(.caption).foregroundStyle(BeeStyle.muted).fixedSize(horizontal: false, vertical: true) }
                HStack {
                Spacer()
                Button("Отмена") { if isDirty { discard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button(saveTitle, action: submit).buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction).disabled(!canSave || model.busy || submitting)
                }
            }.padding(20)
        }.beeSheet(width: width, height: height).foregroundStyle(BeeStyle.text).background(BeeStyle.surface).tint(tintColor).beeAppearance()
            .interactiveDismissDisabled(isDirty)
            .modifier(UpdateFormGuard(active: true))
            .onDisappear { submitTask?.cancel() }
            .confirmationDialog("Сохранить изменения перед закрытием?", isPresented: $discard) {
                Button("Сохранить", action: submit).disabled(!canSave || model.busy || submitting)
                Button("Отказаться", role: .destructive) { dismiss() }
                Button("Продолжить редактирование", role: .cancel) {}
            }
    }
    private func submit() {
        guard !submitting else { return }
        if let saveAsync { submitting = true; submitTask = Task { do { try await saveAsync(); try Task.checkCancellation(); submitting = false; dismiss() } catch { submitting = false; self.error = error.localizedDescription; onError(self.error) } } }
        else { do { try save(); dismiss() } catch { self.error = error.localizedDescription; onError(self.error) } }
    }
}

struct EmptyState: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var title: String
    var detail: String
    var icon = "tray"
    var body: some View { VStack(spacing: 12) { Image(systemName: icon).beeFont(.title2); Text(title).beeFont(.headline); Text(detail).beeFont(.subheadline).foregroundStyle(BeeStyle.muted).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(24) }
}

func confirmDeletion(_ name: String, consequence: String) -> Bool {
    let alert = NSAlert(); alert.messageText = name; alert.informativeText = consequence
    alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
    return alert.runModal() == .alertFirstButtonReturn
}

struct OperationDetailContext: Identifiable {
    var id = UUID()
    var title: String
    var accountID: UUID?
    var ids: [UUID]?
    var filters = Filters()
}
struct OperationDetailSheet: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    var context: OperationDetailContext
    @Environment(\.dismiss) private var dismiss
    var body: some View { VStack(spacing: 0) { HStack { Text(context.title).beeFont(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22); OperationsView(accountID: context.accountID, ids: context.ids, initialFilters: context.filters) }.beeSheet(width: 960, height: 640).beeWindow() }
}

/// A sheet grows for large text but never places its action row offscreen.
private struct BeeSheetSize: ViewModifier {
    @ObservedObject private var store = AppearanceStore.shared
    var width: CGFloat
    var height: CGFloat
    func body(content: Content) -> some View {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 1000)
        let available = BudgetWindows.sheetAvailableSize ?? CGSize(width: max(320, visible.width - 64), height: max(320, visible.height - 100))
        let size = CGSize(width: min(width * pow(store.preferences.scale, 0.4), available.width),
                          height: min(height * pow(store.preferences.scale, 0.65), available.height))
        content.frame(width: size.width, height: size.height)
            .background(BeeSheetWindowSize(size: size))
    }
}

/// SwiftUI can retain the initial native sheet frame when a form changes type.
/// Synchronize that frame as well as the view's requested content size.
private struct BeeSheetWindowSize: NSViewRepresentable {
    var size: CGSize
    func makeNSView(context: Context) -> Anchor { Anchor(size: size) }
    func updateNSView(_ view: Anchor, context: Context) { view.requested = size; view.resizeSheet() }
    final class Anchor: NSView {
        var requested: CGSize
        init(size: CGSize) { requested = size; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resizeSheet() }
        func resizeSheet() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.sheetParent != nil else { return }
                let current = window.contentRect(forFrameRect: window.frame).size
                if abs(current.width - requested.width) > 1 || abs(current.height - requested.height) > 1 {
                    window.setContentSize(requested)
                }
            }
        }
    }
}
extension View {
    func beeSheet(width: CGFloat, height: CGFloat) -> some View { modifier(BeeSheetSize(width: width, height: height)) }
}
