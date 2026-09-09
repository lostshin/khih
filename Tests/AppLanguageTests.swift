import XCTest
@testable import Codenotch

/// In-app language is a stored override, not the Mac's language. Follow
/// System still hits the XCTest English pin when nothing is stored.
final class AppLanguageTests: XCTestCase {
    private var previousLanguage: Any?
    private var previousTestLocale: Locale?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.object(forKey: L10n.languageDefaultsKey)
        previousTestLocale = L10n.testLocale
        L10n.testLocale = nil
        L10n.apply(.system)
    }

    override func tearDown() {
        L10n.testLocale = previousTestLocale
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: L10n.languageDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)
        }
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

    /// `apply(.simplifiedChinese)` stores `zh-Hans`, and `L10n.locale`
    /// honours that even under XCTest, so the default `t()` lookup is
    /// Chinese without setting `testLocale`.
    func testApplySimplifiedChineseServesChineseCopy() {
        L10n.apply(.simplifiedChinese)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.t("Always show"), "始终显示")
    }
}
