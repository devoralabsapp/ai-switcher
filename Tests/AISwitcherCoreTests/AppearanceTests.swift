import XCTest
@testable import AISwitcherCore

final class AppearanceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "ai-switcher-preferences-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: suite) }

    func testPreferencesSurviveRelaunchForEveryLanguageAndTheme() {
        for language in AppLanguage.allCases {
            for theme in AppTheme.allCases {
                let preferences = AppPreferences(language: language, theme: theme)
                AppPreferencesStore(defaults: defaults).save(preferences)
                XCTAssertEqual(AppPreferencesStore(defaults: UserDefaults(suiteName: suite)!).load(), preferences)
            }
        }
    }

    func testAbsentOrInvalidPreferencesPreserveCompatibleDefaults() {
        let store = AppPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.load(), AppPreferences())
        defaults.set("unknown-theme", forKey: "ui.theme")
        defaults.set("en", forKey: "ui.language")
        XCTAssertEqual(store.load(), AppPreferences(language: .english, theme: .light))
        defaults.set("unknown-language", forKey: "ui.language")
        defaults.set("terminal", forKey: "ui.theme")
        XCTAssertEqual(store.load(), AppPreferences(language: .vietnamese, theme: .terminal))
    }

    func testThemeAdditionKeepsPersistedIdentifiersAndAppearanceCompatible() {
        let existing: [(String, Bool)] = [("light", false), ("dark", true), ("terminal", true), ("code", true), ("dracula", true)]
        for (identifier, isDark) in existing {
            defaults.set(identifier, forKey: "ui.theme")
            let theme = AppPreferencesStore(defaults: defaults).load().theme
            XCTAssertEqual(theme.rawValue, identifier)
            XCTAssertEqual(theme.isDark, isDark)
            XCTAssertEqual(theme.outlineWidth, 0)
            XCTAssertEqual(theme.hardShadowOffset, 0)
        }
        XCTAssertTrue(AppTheme.allCases.contains(.terminalBlack))
        XCTAssertEqual(AppTheme.terminalBlack.colors.canvas, 0x000000)
        XCTAssertTrue(AppTheme.terminalBlack.monospaced)
        XCTAssertTrue(AppTheme.terminalBlack.isDark)
        XCTAssertTrue(AppTheme.allCases.contains(.playfulRetro))
        XCTAssertFalse(AppTheme.playfulRetro.isDark)
        XCTAssertFalse(AppTheme.playfulRetro.monospaced)
        XCTAssertEqual(AppTheme.playfulRetro.colors.secondary, AppTheme.playfulRetro.colors.ink)
    }

    func testSeasonalThemesHaveDistinctSharedArtworkAndLocalizedLabels() throws {
        let seasonal: [AppTheme] = [.halloween, .christmas, .tetHoliday, .blackFriday]
        XCTAssertEqual(AppTheme.allCases.count, 11)
        XCTAssertEqual(Set(seasonal.map { $0.colors.canvas }).count, 4)
        for theme in seasonal {
            let style = try XCTUnwrap(theme.seasonal)
            XCTAssertEqual(style.id, theme.rawValue)
            XCTAssertGreaterThan(style.marks.count, 20, theme.rawValue)
            XCTAssertFalse(style.symbol.isEmpty)
            for language in AppLanguage.allCases {
                XCTAssertNotNil(try catalog(language)[style.label], style.label)
            }
            for mark in style.marks {
                XCTAssertTrue(["ellipse", "rect", "path", "text"].contains(mark.kind))
                if mark.kind == "path" { XCTAssertGreaterThanOrEqual(mark.points?.count ?? 0, 2) }
            }
        }
        XCTAssertNil(AppTheme.light.seasonal)
        XCTAssertNil(AppTheme.playfulRetro.seasonal)
    }

    private func catalog(_ language: AppLanguage) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testCatalogsHaveMatchingKeysAndFormatPlaceholders() throws {
        let english = try catalog(.english), vietnamese = try catalog(.vietnamese)
        XCTAssertGreaterThan(english.count, 230)
        XCTAssertEqual(Set(english.keys), Set(vietnamese.keys))
        let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?@|%%"#)
        for (key, en) in english {
            let vi = try XCTUnwrap(vietnamese[key])
            func formats(_ value: String) -> [String] {
                placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                    String(value[Range($0.range, in: value)!])
                }
            }
            XCTAssertFalse(en.isEmpty, key)
            XCTAssertFalse(vi.isEmpty, key)
            XCTAssertEqual(formats(en), formats(vi), key)
            XCTAssertEqual(L10n.text(key, language: .english), en)
            XCTAssertEqual(L10n.text(key, language: .vietnamese), vi)
        }
    }

    func testSourceLocalizationKeysAreIncludedInCatalog() throws {
        let keys = Set(try catalog(.english).keys)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let regex = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\(("(?:\\.|[^"\\])*")"#)
        let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil)!
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = String(text[Range(match.range(at: 1), in: text)!])
                let key = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
                XCTAssertTrue(keys.contains(key), "Missing key in \(file.lastPathComponent): \(key)")
            }
        }
    }

    func testFormattingPreservesUserLabelsAndPercentages() {
        let name = "Work 50% %@"
        XCTAssertEqual(L10n.format("Opened %@", name, language: .english), "Opened " + name)
        XCTAssertEqual(L10n.format("Opened %@", name, language: .vietnamese), "Đã mở " + name)
        XCTAssertEqual(L10n.format("%@%% remaining", "77", language: .english), "77% remaining")
        XCTAssertEqual(L10n.format("%@%% remaining", "77", language: .vietnamese), "77% còn lại")
    }

    func testQuotaWindowLabelsUseSelectedLanguageAndEnglishSingulars() {
        func label(_ minutes: Int, _ language: AppLanguage) -> String {
            CodexQuotaWindow(usedPercent: nil, windowDurationMins: minutes, resetsAt: nil).durationLabel(in: language)
        }
        XCTAssertEqual(label(300, .english), "5 hours")
        XCTAssertEqual(label(60, .english), "1 hour")
        XCTAssertEqual(label(1_440, .english), "1 day")
        XCTAssertEqual(label(1, .english), "1 minute")
        XCTAssertEqual(label(10_080, .english), "Week")
        XCTAssertEqual(label(300, .vietnamese), "5 giờ")
        XCTAssertEqual(label(10_080, .vietnamese), "Tuần")
    }

    func testThemeTextAndButtonsHaveReadableContrast() {
        func luminance(_ hex: UInt32) -> Double {
            [16, 8, 0].map { shift -> Double in
                let channel = Double((hex >> shift) & 255) / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }.enumerated().reduce(0) { $0 + $1.element * [0.2126, 0.7152, 0.0722][$1.offset] }
        }
        func contrast(_ a: UInt32, _ b: UInt32) -> Double {
            let x = luminance(a), y = luminance(b)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for theme in AppTheme.allCases {
            let c = theme.colors
            let candySurfaces = theme.isPlayfulRetro ? [RetroColors.yellow, RetroColors.pink, RetroColors.blue, RetroColors.mint, RetroColors.peach, RetroColors.violet] : []
            for background in [c.canvas, c.surface, c.sidebar] + candySurfaces {
                XCTAssertGreaterThanOrEqual(contrast(c.ink, background), 4.5, theme.rawValue)
                XCTAssertGreaterThanOrEqual(contrast(c.secondary, background), 4.5, theme.rawValue)
            }
            XCTAssertGreaterThanOrEqual(contrast(c.onAccent, c.accent), 4.5, theme.rawValue)
        }
    }
}
