import XCTest
@testable import BudgetPresentation

final class AppearanceTests: XCTestCase {
    func testPreGlassCustomPreferencesKeepEveryStoredColor() throws {
        // Frozen v1 data from the previous appearance format. Do not generate
        // this fixture with the current encoder or replace it with a preset.
        let stored = Data(#"{"theme":"custom","textPercent":140,"custom":{"dark":true,"backgroundStart":{"hex":482405},"backgroundEnd":{"hex":77625},"chrome":{"hex":143160},"surface":{"hex":1195849},"text":{"hex":16775142},"muted":{"hex":12308681},"accent":{"hex":16238422},"accentText":{"hex":1523522},"onBackground":{"hex":16775142},"backgroundMuted":{"hex":14018525}}}"#.utf8)
        let loaded = AppearancePreferences.load(stored)
        XCTAssertEqual(loaded.theme, .custom)
        XCTAssertEqual(loaded.textPercent, 140)
        XCTAssertEqual(loaded.custom, AppearancePalette(dark: true, colors: [0x075C65, 0x012F39, 0x022F38, 0x123F49, 0xFFF7E6, 0xBBD0C9, 0xF7C756, 0x173F42, 0xFFF7E6, 0xD5E7DD]))
        XCTAssertNotEqual(loaded.custom, AppearancePalette.preset(.beeSave, systemDark: true))
        XCTAssertEqual(AppearancePreferences.load(try JSONEncoder().encode(loaded)), loaded)
    }
    func testPresetContrastAndSemanticColors() {
        for dark in [false, true] {
            for theme in AppearanceTheme.allCases {
                let palette = AppearancePalette.preset(theme, systemDark: dark)
                XCTAssertTrue(palette.validationIssues.isEmpty, "\(theme) / \(dark): \(palette.validationIssues)")
                for color in [palette.positive, palette.warning, palette.negative, palette.expense] { XCTAssertGreaterThanOrEqual(color.contrast(on: palette.surface), 4.5) }
                XCTAssertGreaterThanOrEqual(palette.line.contrast(on: palette.surface), 3)
                XCTAssertGreaterThanOrEqual(palette.controlAccent.contrast(on: palette.surface), 3)
                XCTAssertGreaterThanOrEqual(palette.backgroundLine.contrast(on: palette.backgroundStart), 3)
            }
        }
    }
    func testHEXStrictParsingAndRoundTrip() {
        XCTAssertEqual(AppearanceColor(hexString: " #a0B1c2 ")?.hexString, "#A0B1C2")
        XCTAssertEqual(AppearanceColor(hexString: "000000"), AppearanceColor(0))
        for value in ["", "#FFF", "#12345678", "12345G", "1234560", "＃123456", "#１２３４５６"] { XCTAssertNil(AppearanceColor(hexString: value), value) }
        XCTAssertEqual(AppearanceColor(0).contrast(on: AppearanceColor(0xFFFFFF)), 21, accuracy: 0.0001)
    }
    func testGradientInteriorCanFailWhenBothEndsPass() {
        let black = AppearanceColor(0), red = AppearanceColor(0xFF0000), green = AppearanceColor(0x00FF00)
        XCTAssertGreaterThan(black.contrast(on: red), 4.5)
        XCTAssertGreaterThan(black.contrast(on: green), 4.5)
        XCTAssertLessThan(black.contrast(onGradientFrom: red, to: green), 4.5)
        var palette = AppearancePalette.preset(.sepia)
        palette.backgroundStart = red; palette.backgroundEnd = green; palette.onBackground = black
        XCTAssertTrue(palette.validationIssues.contains { $0.contains("Текст на фоне") })
    }
    func testInaccessibleCustomTextRejected() {
        var palette = AppearancePalette.preset(.midnight)
        palette.text = palette.surface
        XCTAssertTrue(palette.validationIssues.contains { $0.contains("Основной текст") })
        palette = .preset(.sepia); palette.accentText = palette.accent
        XCTAssertTrue(palette.validationIssues.contains { $0.contains("Текст на акценте") })
    }
    func testPreferencesFallbackAndPersistence() throws {
        XCTAssertEqual(AppearancePreferences.load(nil), AppearancePreferences())
        XCTAssertEqual(AppearancePreferences.load(Data("broken".utf8)), AppearancePreferences())
        XCTAssertEqual(AppearancePreferences.load(Data("{}".utf8)), AppearancePreferences())
        var value = AppearancePreferences(); value.theme = .custom; value.textPercent = 160; value.custom = .preset(.sepia)
        XCTAssertEqual(AppearancePreferences.load(try JSONEncoder().encode(value)), value)
        XCTAssertEqual(value.scale, 1.6)
        value.theme = .sepia; XCTAssertEqual(value.palette(systemDark: true), value.palette(systemDark: false))
        value.theme = .midnight; XCTAssertTrue(value.palette(systemDark: false).dark)
        value.theme = .beeSave; XCTAssertNotEqual(value.palette(systemDark: false), value.palette(systemDark: true))
        value.textPercent = 999; XCTAssertEqual(AppearancePreferences.load(try JSONEncoder().encode(value)), AppearancePreferences())
        value.textPercent = 100; value.custom.muted = value.custom.surface
        XCTAssertEqual(AppearancePreferences.load(try JSONEncoder().encode(value)), AppearancePreferences())
        let unknown = Data("{\"theme\":\"future\",\"textPercent\":100}".utf8)
        XCTAssertEqual(AppearancePreferences.load(unknown), AppearancePreferences())
    }
    func testDerivedRolesRemainReadableForUnusualSurfaces() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0x777777, 0x325874, 0xAA2244] {
            var palette = AppearancePalette.preset(.midnight); palette.surface = AppearanceColor(hex)
            for color in [palette.positive, palette.warning, palette.negative, palette.expense] { XCTAssertGreaterThanOrEqual(color.contrast(on: palette.surface), 4.5) }
            XCTAssertGreaterThanOrEqual(palette.line.contrast(on: palette.surface), 3)
        }
    }
}
