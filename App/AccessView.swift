import SwiftUI
import AppKit
import BudgetCore

struct AccessView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let error = model.startupError {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Не удалось открыть бюджет").font(.title2.bold()); Text(error)
                    Button("Повторить открытие") { do { try model.vault.acquire(); if model.vault.exists { model.bootstrap = try model.vault.inspect() }; model.startupError = nil } catch { model.startupError = error.localizedDescription } }.buttonStyle(BeePrimaryStyle())
                    Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }
                }.beeCard().frame(maxWidth: 500)
            } else if model.vault.exists { LoginView() } else { SetupWizard() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).beeWindow()
    }
}

struct SetupWizard: View {
    @EnvironmentObject var model: AppModel
    @State private var step = 0
    @State private var password = ""
    @State private var repeated = ""
    @State private var passwordOn = true
    @State private var currency = "RUB"
    @State private var touchID = false
    @State private var lockMinutes = 5
    @State private var advanced = false
    @State private var openSessionConfirmed = false
    @State private var recovery = ""
    @State private var recoveryCheck = ""
    @State private var acknowledged = false
    @State private var error = ""
    @FocusState private var focus: Int?
    private var passwordValid: Bool { password.count >= 12 && password == repeated }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack { Text("BeeSave").font(.title2.bold()); Spacer(); Text("Шаг \(step + 1) из 3").font(.subheadline).foregroundStyle(BeeStyle.backgroundMuted) }
            HStack(spacing: 8) { ForEach(0..<3) { index in Capsule().fill(index <= step ? BeeStyle.honey : BeeStyle.onBackground.opacity(0.22)).frame(height: 4) } }
            VStack(alignment: .leading, spacing: 20) {
                if step == 0 {
                    Text("Придумайте пароль").font(.system(size: 34, weight: .semibold)); Text("Для входа в ваш бюджет на этом Mac.").foregroundStyle(BeeStyle.muted)
                    FormField(title: "Пароль", hint: "Не менее 12 символов") { SecureField("Введите пароль", text: $password).focused($focus, equals: 0).font(.title3).textFieldStyle(.roundedBorder) }
                    FormField(title: "Повторите пароль") { SecureField("Введите ещё раз", text: $repeated).focused($focus, equals: 1).font(.title3).textFieldStyle(.roundedBorder).onSubmit { if passwordValid { advance() } } }
                    if !repeated.isEmpty && password != repeated { Text("Пароли пока не совпадают").font(.caption).foregroundStyle(BeeStyle.negative) }
                    Button("Другой способ входа") { passwordOn = false; advance() }.buttonStyle(.plain).foregroundStyle(BeeStyle.muted)
                } else if step == 1 {
                    Text("Настройте под себя").font(.system(size: 30, weight: .semibold)); CurrencyPicker(title: "Базовая валюта", selection: $currency)
                    Toggle("Вход с Touch ID", isOn: $touchID).disabled(!LocalKeys.biometricAvailable()).toggleStyle(.checkbox)
                    if !LocalKeys.biometricAvailable() { Text("Touch ID недоступен на этом Mac.").font(.caption).foregroundStyle(BeeStyle.muted) }
                    DisclosureGroup("Дополнительно", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Использовать пароль приложения", isOn: Binding(get: { passwordOn }, set: { passwordOn = $0; if $0 && !passwordValid { step = 0; focus = 0 } })).toggleStyle(.checkbox)
                            FormField(title: "Автоблокировка") { Picker("Автоблокировка", selection: $lockMinutes) { Text("Выключена").tag(0); ForEach([1, 5, 10, 15, 30], id: \.self) { Text("Через \($0) мин").tag($0) } }.labelsHidden() }
                        }.padding(.top, 12)
                    }
                    if !passwordOn && !touchID {
                        Text("Любой пользователь вашей разблокированной сессии macOS сможет открыть бюджет. Данные остаются зашифрованными.").font(.subheadline).foregroundStyle(BeeStyle.warning)
                        Toggle("Разрешаю вход из моей сессии macOS", isOn: $openSessionConfirmed).toggleStyle(.checkbox).disabled(!LocalKeys.keychainEntitled())
                        if !LocalKeys.keychainEntitled() { Text("В этой сборке доступен вход паролем. Вернитесь к первому шагу.").font(.caption).foregroundStyle(BeeStyle.muted) }
                    }
                } else {
                    Text("Сохраните ключ восстановления").font(.title.bold()); Text("Храните его отдельно от этого Mac. Ключ нужен для восстановления доступа и переноса полной копии.").foregroundStyle(BeeStyle.muted)
                    Text(recovery).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(BeeStyle.selected, in: RoundedRectangle(cornerRadius: 8))
                    Button("Скопировать ключ", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(recovery, forType: .string) }
                    Toggle("Ключ сохранён в безопасном месте", isOn: $acknowledged).toggleStyle(.checkbox)
                    FormField(title: "Проверочный ввод ключа") { SecureField("Введите сохранённый ключ целиком", text: $recoveryCheck).textFieldStyle(.roundedBorder).focused($focus, equals: 2) }
                    Text("Без способов входа и этого ключа данные восстановить невозможно.").font(.caption).foregroundStyle(BeeStyle.muted)
                }
                if !error.isEmpty { Text(error).foregroundStyle(BeeStyle.negative).fixedSize(horizontal: false, vertical: true) }
                Divider()
                HStack { if step > 0 { Button("Назад") { step -= 1; error = "" } }; Spacer(); Button(step == 2 ? "Создать бюджет" : "Далее") { if step == 2 { create() } else { advance() } }.buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction).disabled(!canContinue || model.busy) }
            }.beeCard(padding: 32)
            if step == 0 { Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }.buttonStyle(.plain).foregroundStyle(BeeStyle.backgroundMuted) }
        }.frame(width: 620).padding(36).task { if recovery.isEmpty { do { recovery = try VaultCrypto.recoveryString(VaultCrypto.random()) } catch { self.error = error.localizedDescription } }; focus = 0 }
            .onDisappear { password = ""; repeated = ""; recovery = ""; recoveryCheck = "" }
    }
    private var canContinue: Bool { if step == 0 { return passwordValid }; if step == 1 { return (!passwordOn || passwordValid) && (passwordOn || touchID || openSessionConfirmed) }; return acknowledged && !recoveryCheck.isEmpty }
    private func advance() { error = ""; step += 1; if step == 2 { focus = 2 } }
    private func create() {
        do { try model.setup(currency: currency, password: passwordOn ? password : "", touchID: touchID, recovery: recovery, confirmed: recoveryCheck, lockMinutes: lockMinutes) } catch { self.error = error.localizedDescription; focus = 2 }
    }
}

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var recovery = ""
    @State private var recovering = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("BeeSave").font(.title2.bold()).foregroundStyle(BeeStyle.onBackground)
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: recovering ? "key" : "lock").font(.system(size: 30)).foregroundStyle(BeeStyle.expense)
                Text(recovering ? "Восстановите доступ" : "Откройте свой бюджет").font(.title.bold())
                if recovering {
                    FormField(title: "Ключ восстановления") { SecureField("Полный ключ", text: $recovery).textFieldStyle(.roundedBorder).focused($focused) }
                    Text("Ключ откроет текущую базу на этом Mac.").font(.caption).foregroundStyle(BeeStyle.muted)
                } else if model.bootstrap?.password != nil {
                    FormField(title: "Пароль приложения") { SecureField("Введите пароль", text: $password).textFieldStyle(.roundedBorder).focused($focused) }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(ceil((model.retryAt ?? .distantPast).timeIntervalSince(context.date))))
                    VStack(alignment: .leading, spacing: 12) {
                        if remaining > 0 { Text("После пяти неверных попыток: подождите \(remaining) сек.").font(.caption).foregroundStyle(BeeStyle.warning) }
                        if recovering || model.bootstrap?.password != nil { Button(recovering ? "Войти с ключом" : "Открыть") { if recovering { model.unlock(recovery: recovery); recovery = "" } else { model.unlock(password: password); password = "" } }.buttonStyle(BeePrimaryStyle()).keyboardShortcut(.defaultAction).disabled(remaining > 0 || model.busy || (recovering ? recovery.isEmpty : password.isEmpty)) }
                        if !recovering && model.bootstrap?.touchID == true { Button("Войти с Touch ID", systemImage: "touchid") { model.unlock(biometric: true) }.disabled(remaining > 0 || model.busy) }
                    }
                }
                if !recovering && model.bootstrap?.requiresAuthentication == false { Button("Открыть через Keychain") { model.resumeSession() }.buttonStyle(BeePrimaryStyle()) }
                Button(recovering ? "Назад ко входу" : "Не получается войти?") { recovering.toggle(); password = ""; recovery = ""; focused = true }.buttonStyle(.plain).foregroundStyle(BeeStyle.muted)
            }.beeCard(padding: 30)
            if recovering { Button("Восстановить полную копию…") { model.sheet = SheetRoute(kind: .restore) }.buttonStyle(.plain).foregroundStyle(BeeStyle.backgroundMuted) }
        }.frame(width: 470).padding(30).onAppear { focused = true }.onDisappear { password = ""; recovery = "" }
    }
}
