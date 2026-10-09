import SwiftUI
import AppKit
import BudgetCore

struct AccessView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let error = model.startupError {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Не удалось открыть бюджет", systemImage: "exclamationmark.triangle").beeFont(.headline)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Button("Повторить открытие") { do { try model.vault.acquire(); if model.vault.exists { model.bootstrap = try model.vault.inspect() }; model.startupError = nil } catch { model.startupError = error.localizedDescription } }.buttonStyle(BeePrimaryStyle())
                    Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }
                }.padding(28).frame(width: 440)
            } else if model.vault.exists { LoginView() }
            else {
                ScrollView { SetupWizard() }
                    .frame(width: min(720, (NSScreen.main?.visibleFrame.width ?? 900) - 48),
                           height: min(760, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
            }
        }.foregroundStyle(BeeStyle.onBackground)
    }
}

struct SetupWizard: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @State private var step = 0
    @State private var password = ""
    @State private var repeated = ""
    @State private var currency = "RUB"
    @State private var lockMinutes = 5
    @State private var advanced = false
    @State private var recovery = ""
    @State private var recoveryCheck = ""
    @State private var acknowledged = false
    @State private var error = ""
    @FocusState private var focus: Int?
    #if DEBUG && UI_SMOKE
    init(qaStep: Int = 0) { _step = State(initialValue: qaStep) }
    #endif
    private var passwordValid: Bool { password.count >= 12 && password == repeated }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack { Text("BeeSave").beeFont(.title2.bold()); Spacer(); Text("Шаг \(step + 1) из 3").beeFont(.subheadline).foregroundStyle(BeeStyle.backgroundMuted) }
            HStack(spacing: 8) { ForEach(0..<3) { index in Capsule().fill(index <= step ? BeeStyle.honey : BeeStyle.onBackground.opacity(0.22)).frame(height: 4) } }
            VStack(alignment: .leading, spacing: 20) {
                if step == 0 {
                    Text("Придумайте пароль").beeFont(.system(size: 34, weight: .semibold)); Text("Для входа в ваш бюджет на этом Mac.").foregroundStyle(BeeStyle.muted)
                    FormField(title: "Пароль", hint: "Не менее 12 символов") { SecureField("Введите пароль", text: $password).focused($focus, equals: 0).beeFont(.title3).textFieldStyle(BeeTextFieldStyle()) }
                    FormField(title: "Повторите пароль") { SecureField("Введите ещё раз", text: $repeated).focused($focus, equals: 1).beeFont(.title3).textFieldStyle(BeeTextFieldStyle()).onSubmit { if passwordValid { advance() } } }
                    if !repeated.isEmpty && password != repeated { Text("Пароли пока не совпадают").beeFont(.caption).foregroundStyle(BeeStyle.negative) }
                } else if step == 1 {
                    Text("Настройте под себя").beeFont(.system(size: 30, weight: .semibold)); CurrencyPicker(title: "Базовая валюта", selection: $currency)
                    DisclosureGroup("Дополнительно", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 14) {
                            FormField(title: "Автоблокировка") { BeePicker("Автоблокировка", selection: $lockMinutes) { Text("Выключена").tag(0); ForEach([1, 5, 10, 15, 30], id: \.self) { Text("Через \($0) мин").tag($0) } }.labelsHidden() }
                        }.padding(.top, 12)
                    }
                } else {
                    Text("Сохраните ключ восстановления").beeFont(.title.bold()); Text("Храните его отдельно от этого Mac. Ключ нужен для восстановления доступа и переноса полной копии.").foregroundStyle(BeeStyle.muted)
                    Text(recovery).beeFont(.system(.body, design: .monospaced)).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(BeeStyle.selected, in: RoundedRectangle(cornerRadius: 8))
                    Button("Скопировать ключ", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(recovery, forType: .string) }
                    Toggle("Ключ сохранён в безопасном месте", isOn: $acknowledged).toggleStyle(.checkbox)
                    FormField(title: "Проверочный ввод ключа") { SecureField("Введите сохранённый ключ целиком", text: $recoveryCheck).textFieldStyle(BeeTextFieldStyle()).focused($focus, equals: 2) }
                    Text("Без пароля и этого ключа данные восстановить невозможно.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                }
                if !error.isEmpty { Text(error).foregroundStyle(BeeStyle.negative).fixedSize(horizontal: false, vertical: true) }
                Divider()
                HStack { if step > 0 { Button("Назад") { step -= 1; error = "" } }; Spacer(); Button(step == 2 ? "Создать бюджет" : "Далее") { if step == 2 { create() } else { advance() } }.buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction).disabled(!canContinue || model.busy) }
            }.beeCard(padding: 32)
            if step == 0 { Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }.buttonStyle(BeeRowStyle()).foregroundStyle(BeeStyle.backgroundMuted) }
        }.frame(maxWidth: 620).padding(36).modifier(UpdateFormGuard(active: step > 0 || !password.isEmpty || !repeated.isEmpty)).task { if recovery.isEmpty { do { recovery = try VaultCrypto.recoveryString(VaultCrypto.random()) } catch { self.error = error.localizedDescription } }; focus = 0 }
            .onDisappear { password = ""; repeated = ""; recovery = ""; recoveryCheck = "" }
    }
    private var canContinue: Bool { if step < 2 { return passwordValid }; return acknowledged && !recoveryCheck.isEmpty }
    private func advance() { error = ""; step += 1; if step == 2 { focus = 2 } }
    private func create() {
        do { try model.setup(currency: currency, password: password, recovery: recovery, confirmed: recoveryCheck, lockMinutes: lockMinutes) } catch { self.error = error.localizedDescription; focus = 2 }
    }
}

struct LoginView: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var recovery = ""
    @State private var newPassword = ""
    @State private var repeated = ""
    @State private var recovering = false
    @FocusState private var focused: Bool
    private var scale: CGFloat { appearanceStore.preferences.scale }
    private var windowHeight: CGFloat {
        min((recovering ? 610 : 320) * pow(scale, 0.85), (NSScreen.main?.visibleFrame.height ?? 900) - 80)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: recovering ? "key.fill" : "circle.hexagongrid.fill")
                        .beeFont(.title2).foregroundStyle(BeeStyle.expense).accessibilityHidden(true)
                    Text("BeeSave").beeFont(.title2.weight(.semibold))
                }
                if recovering {
                    Text("Восстановление доступа").beeFont(.headline)
                    FormField(title: "Ключ восстановления") { SecureField("Полный ключ", text: $recovery).textFieldStyle(BeeTextFieldStyle()).focused($focused) }
                    Text("Ключ подтвердит доступ к бюджету. Данные и копии сохранятся.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                    FormField(title: "Новый пароль", hint: "Не менее 12 символов") { SecureField("Введите новый пароль", text: $newPassword).textFieldStyle(BeeTextFieldStyle()) }
                    FormField(title: "Повторите пароль") { SecureField("Введите ещё раз", text: $repeated).textFieldStyle(BeeTextFieldStyle()) }
                } else {
                    FormField(title: "Пароль бюджета") {
                        SecureField("Введите пароль", text: $password).textFieldStyle(BeeTextFieldStyle())
                            .focused($focused).accessibilityIdentifier("access.password")
                    }
                    if model.bootstrap?.password == nil {
                        Text("Восстановите доступ с помощью ключа, чтобы задать пароль.").beeFont(.caption).foregroundStyle(BeeStyle.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let error = model.error { Text(error).foregroundStyle(BeeStyle.negative).fixedSize(horizontal: false, vertical: true) }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil((model.retryAt ?? .distantPast).timeIntervalSince(context.date))))
                        if remaining > 0 { Text("Повторите через \(remaining) сек.").foregroundStyle(BeeStyle.warning) }
                    }
                }.beeFont(.caption).frame(minHeight: 20, alignment: .topLeading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let waiting = (model.retryAt ?? .distantPast) > context.date
                    Button(model.busy ? "Проверяем…" : recovering ? "Сохранить и открыть" : "Открыть бюджет", action: submit)
                        .buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction)
                        .disabled(waiting || model.busy || (recovering ? recovery.isEmpty || newPassword.count < 12 || newPassword != repeated : password.isEmpty || model.bootstrap?.password == nil))
                        .accessibilityIdentifier("access.unlock")
                }
                Button(recovering ? "Назад ко входу" : "Не получается войти?") {
                    recovering.toggle(); model.error = nil; password = ""; recovery = ""; newPassword = ""; repeated = ""; focused = true
                }.buttonStyle(.borderless).beeFont(.caption)
                if recovering { Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }.buttonStyle(.borderless).beeFont(.caption) }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: min(420 * pow(scale, 0.6), (NSScreen.main?.visibleFrame.width ?? 900) - 48), height: windowHeight)
            .modifier(UpdateFormGuard(active: !password.isEmpty || !recovery.isEmpty || !newPassword.isEmpty || !repeated.isEmpty))
            .onAppear { focused = true }
            .onDisappear { password = ""; recovery = ""; newPassword = ""; repeated = "" }
    }
    private func submit() {
        guard !model.busy, (model.retryAt ?? .distantPast) <= Date() else { return }
        if recovering {
            guard !recovery.isEmpty, newPassword.count >= 12, newPassword == repeated else { return }
            model.resetPassword(recovery: recovery, newPassword: newPassword); recovery = ""; newPassword = ""; repeated = ""
        } else {
            guard !password.isEmpty, model.bootstrap?.password != nil else { return }
            model.unlock(password: password); password = ""
        }
    }
}
