import XCTest
@testable import Khih

/// In-app language is a stored override, not the Mac's language. Follow
/// System still hits the XCTest English pin when nothing is stored.
final class AppLanguageTests: XCTestCase {
    private var suiteName = ""
    private var previousDefaults: UserDefaults?
    private var previousTestLocale: Locale?

    /// A scratch suite, not `.standard`. The test host *is* the app, so
    /// `.standard` is the preferences of the copy of Khih installed on
    /// this Mac: reading it would let a language chosen in Settings decide
    /// what these assert, and writing it would leave a language behind in the
    /// real app when a test failed before its restore.
    override func setUp() {
        super.setUp()
        suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: suiteName)!
        scratch.removePersistentDomain(forName: suiteName)
        previousDefaults = L10n.defaults
        previousTestLocale = L10n.testLocale
        L10n.defaults = scratch
        L10n.testLocale = nil
        L10n.apply(.system)
    }

    override func tearDown() {
        L10n.testLocale = previousTestLocale
        L10n.defaults.removePersistentDomain(forName: suiteName)
        if let previousDefaults { L10n.defaults = previousDefaults }
        super.tearDown()
    }

    func testFollowSystemUsesTheEnglishPinWhenNothingIsStored() {
        L10n.apply(.system)
        L10n.testLocale = nil
        XCTAssertTrue(
            L10n.locale.identifier.hasPrefix("en"),
            "XCTest pin should return English when appLanguage is unset, got \(L10n.locale.identifier)"
        )
    }

    /// A forced English must actually be English. The catalog files its
    /// source strings under `en`, so the region-qualified `en_US` this used
    /// to store matched nothing and fell through to the next localization the
    /// bundle offered — Chinese, on a build that ships one.
    func testApplyEnglishServesEnglishCopy() {
        L10n.apply(.english)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.t("Always show"), "Always show")
    }

    func testOnlySupportedLanguagesAreSelectable() {
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["system", "en", "zh-Hant-TW"])
    }

    func testUnknownLanguageUsesSystemSelection() {
        L10n.defaults.set("removed-language", forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(AppLanguage(rawValue: "removed-language") ?? .system, .system)
    }

    func testApplyTaiwanChinesePersistsAndServesTaiwanCopy() {
        L10n.apply(.traditionalChineseTaiwan)
        XCTAssertEqual(L10n.defaults.string(forKey: L10n.languageDefaultsKey), "zh-Hant-TW")
        XCTAssertEqual(L10n.locale.identifier, "zh-Hant-TW")
        XCTAssertEqual(L10n.t("Settings…"), "設定…")
        XCTAssertEqual(L10n.t("Accounts"), "帳號")
        XCTAssertEqual(L10n.t("Sign in to \("Codex")"), "登入 Codex")
        XCTAssertEqual(AppLanguage.traditionalChineseTaiwan.title, "繁體中文（台灣）")

        L10n.apply(.english)
        XCTAssertEqual(L10n.t("Settings…"), "Settings…")
        L10n.apply(.system)
        XCTAssertNil(L10n.defaults.string(forKey: L10n.languageDefaultsKey))
    }
}
