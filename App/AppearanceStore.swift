import SwiftUI
import AppKit
import BudgetPresentation

final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()
    private let defaults: UserDefaults
    private let key = "BeeSave.appearance.v1"
    @Published private(set) var preferences: AppearancePreferences
    @Published private(set) var systemDark: Bool
    private var systemAppearanceObservation: NSKeyValueObservation?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = AppearancePreferences.load(defaults.data(forKey: key))
        let application = NSApplication.shared
        systemDark = application.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        systemAppearanceObservation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
            let dark = application.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DispatchQueue.main.async { self?.systemDark = dark }
        }
    }
    func update(_ change: (inout AppearancePreferences) -> Void) {
        var next = preferences; change(&next)
        guard AppearancePreferences.scales.contains(next.textPercent), next.custom.validationIssues.isEmpty,
              let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: key)
        preferences = next
    }
    func reset() { update { $0 = AppearancePreferences() } }
    var colorScheme: ColorScheme? {
        switch preferences.theme {
        // Explicitly restore the system mode: preferredColorScheme(nil) can
        // retain the preceding fixed theme in an already open macOS window.
        case .beeSave: return systemDark ? .dark : .light
        case .midnight: return .dark
        case .sepia: return .light
        case .custom: return preferences.custom.dark ? .dark : .light
        }
    }
}

private struct BeeAppearanceKey: EnvironmentKey { static let defaultValue = AppearancePreferences() }
extension EnvironmentValues {
    var beeAppearance: AppearancePreferences {
        get { self[BeeAppearanceKey.self] }
        set { self[BeeAppearanceKey.self] = newValue }
    }
}

/// Explicit font roles scale on macOS, including controls and fixed-size titles.
struct BeeFont {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    static let body = Self(size: 15), callout = Self(size: 15), subheadline = Self(size: 15)
    static let headline = Self(size: 17, weight: .semibold)
    static let caption = Self(size: 12), caption2 = Self(size: 12)
    static let title = Self(size: 28, weight: .semibold), title2 = Self(size: 22), title3 = Self(size: 19)
    static func system(size: CGFloat, weight: Font.Weight = .regular) -> Self { Self(size: max(12, size), weight: weight) }
    static func system(_ font: Self, design: Font.Design) -> Self { var value = font; value.design = design; return value }
    func weight(_ value: Font.Weight) -> Self { var result = self; result.weight = value; return result }
    func bold() -> Self { weight(.bold) }
    func monospaced() -> Self { var result = self; result.design = .monospaced; return result }
}

private struct BeeFontModifier: ViewModifier {
    @Environment(\.beeAppearance) private var appearance
    var role: BeeFont
    func body(content: Content) -> some View {
        content.font(.system(size: role.size * appearance.scale, weight: role.weight, design: role.design))
    }
}

struct BeeAppearanceModifier: ViewModifier {
    @ObservedObject private var store = AppearanceStore.shared
    func body(content: Content) -> some View {
        content.environment(\.beeAppearance, store.preferences)
            .font(.system(size: 15 * store.preferences.scale))
            .preferredColorScheme(store.colorScheme)
            .buttonStyle(BeeRowStyle())
    }
}


extension View {
    func beeFont(_ role: BeeFont) -> some View { modifier(BeeFontModifier(role: role)) }
    func beeAppearance() -> some View { modifier(BeeAppearanceModifier()) }
}
