import Foundation

public struct AppearanceColor: Codable, Equatable, Sendable {
    public let hex: UInt32
    public init(_ hex: UInt32) { self.hex = min(hex, 0xFFFFFF) }
    public init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }), let hex = UInt32(digits, radix: 16) else { return nil }
        self.init(hex)
    }
    public var hexString: String { String(format: "#%06X", hex) }
    public var red: Double { Double((hex >> 16) & 255) / 255 }
    public var green: Double { Double((hex >> 8) & 255) / 255 }
    public var blue: Double { Double(hex & 255) / 255 }
    public var luminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    public func contrast(on other: Self) -> Double { Self.contrast(luminance, other.luminance) }
    private static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    public func mixed(with other: Self, fraction: Double) -> Self {
        let t = min(1, max(0, fraction))
        func channel(_ a: Double, _ b: Double) -> UInt32 { UInt32(((a + (b - a) * t) * 255).rounded()) }
        return Self(channel(red, other.red) << 16 | channel(green, other.green) << 8 | channel(blue, other.blue))
    }
    /// The luminance of an sRGB interpolation is convex. Its maximum is at an
    /// endpoint; search its minimum, including gradients whose ends both pass.
    public func contrast(onGradientFrom start: Self, to end: Self) -> Double {
        func luminance(_ t: Double) -> Double {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(start.red + (end.red - start.red) * t)
                + 0.7152 * linear(start.green + (end.green - start.green) * t)
                + 0.0722 * linear(start.blue + (end.blue - start.blue) * t)
        }
        var low = 0.0, high = 1.0
        for _ in 0..<80 {
            let a = low + (high - low) / 3, b = high - (high - low) / 3
            if luminance(a) < luminance(b) { high = b } else { low = a }
        }
        // A small conservative allowance also covers rounding of gradient stops.
        let minimum = max(0, min(luminance((low + high) / 2), start.luminance, end.luminance) - 0.002)
        let maximum = min(1, max(start.luminance, end.luminance) + 0.002)
        if (minimum...maximum).contains(self.luminance) { return 1 }
        return min(Self.contrast(self.luminance, minimum), Self.contrast(self.luminance, maximum))
    }
}

public enum AppearanceTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case beeSave, midnight, sepia, custom
    public var id: String { rawValue }
    public var title: String { switch self { case .beeSave: "BeeSave"; case .midnight: "Полночь"; case .sepia: "Сепия"; case .custom: "Своя тема" } }
    public var detail: String { switch self { case .beeSave: "Liquid Glass · системный светлый и тёмный"; case .midnight: "Тёмно-синяя и оранжевый"; case .sepia: "Тёплая светлая и чёрный"; case .custom: "Ваша собственная палитра" } }
}

public struct AppearancePalette: Codable, Equatable, Sendable {
    public var dark: Bool
    public var backgroundStart, backgroundEnd, chrome, surface, text, muted, accent, accentText, onBackground, backgroundMuted: AppearanceColor
    public init(dark: Bool, colors: [UInt32]) {
        precondition(colors.count == 10)
        self.dark = dark
        backgroundStart = .init(colors[0]); backgroundEnd = .init(colors[1]); chrome = .init(colors[2]); surface = .init(colors[3])
        text = .init(colors[4]); muted = .init(colors[5]); accent = .init(colors[6]); accentText = .init(colors[7])
        onBackground = .init(colors[8]); backgroundMuted = .init(colors[9])
    }
    public static func preset(_ theme: AppearanceTheme, systemDark: Bool = false) -> Self {
        switch theme {
        case .beeSave, .custom:
            return systemDark
                ? Self(dark: true, colors: [0x172427, 0x101B1E, 0x1B2B2F, 0x213338, 0xF1F6F3, 0xB5C7C1, 0xF3C75C, 0x172E2E, 0xF1F6F3, 0xB5C7C1])
                : Self(dark: false, colors: [0xF2F5F5, 0xE8EEEE, 0xEAF0EF, 0xFFFFFF, 0x192B2D, 0x536567, 0xF7C756, 0x173F42, 0x192B2D, 0x536567])
        case .midnight:
            return Self(dark: true, colors: [0x142743, 0x090F1D, 0x0C1729, 0x1B2B43, 0xF4F6FA, 0xB9C6D9, 0xFFAB61, 0x25180D, 0xF4F6FA, 0xB9C6D9])
        case .sepia:
            return Self(dark: false, colors: [0xF6F1E8, 0xEEE7DA, 0xF1EADD, 0xFFFCF5, 0x25231F, 0x625A4C, 0x29251F, 0xFFF8E9, 0x25231F, 0x5D5548])
        }
    }
    public var selected: AppearanceColor { surface.mixed(with: accent, fraction: dark ? 0.12 : 0.08) }
    public var controlAccent: AppearanceColor { accent.contrast(on: surface) >= 3 ? accent : text }
    public var line: AppearanceColor { bestNeutral(on: surface) }
    public var backgroundLine: AppearanceColor { bestNeutral(on: backgroundStart) }
    public var positive: AppearanceColor { readable(dark ? 0x9DE4C2 : 0x21634C) }
    public var warning: AppearanceColor { readable(dark ? 0xFFD18B : 0x76510A) }
    public var negative: AppearanceColor { readable(dark ? 0xFFB6AA : 0xA23529) }
    public var expense: AppearanceColor { readable(dark ? 0xFFCF83 : 0x825310) }
    private func bestNeutral(on background: AppearanceColor) -> AppearanceColor {
        let white = AppearanceColor(0xFFFFFF), black = AppearanceColor(0x000000)
        let target = white.contrast(on: background) > black.contrast(on: background) ? white : black
        // The first 3:1 neutral keeps borders calm, while remaining perceptible.
        for step in 1...100 { let c = background.mixed(with: target, fraction: Double(step) / 100); if c.contrast(on: background) >= 3.1 { return c } }
        return target
    }
    private func readable(_ hex: UInt32) -> AppearanceColor {
        let initial = AppearanceColor(hex)
        if initial.contrast(on: surface) >= 4.5 { return initial }
        let target = AppearanceColor(0xFFFFFF).contrast(on: surface) > AppearanceColor(0).contrast(on: surface) ? AppearanceColor(0xFFFFFF) : AppearanceColor(0)
        for step in 1...100 { let c = initial.mixed(with: target, fraction: Double(step) / 100); if c.contrast(on: surface) >= 4.5 { return c } }
        return target
    }
    public var validationIssues: [String] {
        var issues: [String] = []
        if [backgroundStart, backgroundEnd, chrome, surface, text, muted, accent, accentText, onBackground, backgroundMuted].contains(where: { $0.hex > 0xFFFFFF }) {
            return ["Цвет вне диапазона #RRGGBB"]
        }
        let pairs: [(String, AppearanceColor, AppearanceColor)] = [
            ("Основной текст на карточке", text, surface), ("Вторичный текст на карточке", muted, surface),
            ("Текст на акценте", accentText, accent), ("Текст боковой панели", onBackground, chrome),
            ("Подписи боковой панели", backgroundMuted, chrome), ("Текст выделенной строки", text, selected)
        ]
        for (name, foreground, background) in pairs where foreground.contrast(on: background) < 4.5 { issues.append(name + ": контраст ниже 4,5:1") }
        for (name, color) in [("Текст на фоне", onBackground), ("Подписи на фоне", backgroundMuted)] {
            if color.contrast(onGradientFrom: backgroundStart, to: backgroundEnd) < 4.5 { issues.append(name + ": контраст на градиенте ниже 4,5:1") }
        }
        // A primary control must have a distinguishable perimeter on a surface.
        if accent.contrast(on: surface) < 3 && accentText.contrast(on: surface) < 3 { issues.append("Граница акцентной кнопки: контраст ниже 3:1") }
        return issues
    }
}

public struct AppearancePreferences: Codable, Equatable, Sendable {
    public static let scales = [100, 110, 125, 140, 160]
    public var theme: AppearanceTheme = .beeSave
    public var textPercent: Int = 100
    public var custom = AppearancePalette.preset(.midnight)
    public init() {}
    public var scale: Double { Double(textPercent) / 100 }
    public func palette(systemDark: Bool) -> AppearancePalette { theme == .custom ? custom : .preset(theme, systemDark: systemDark) }
    public static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data), scales.contains(value.textPercent),
              value.custom.validationIssues.isEmpty else { return Self() }
        return value
    }
}
