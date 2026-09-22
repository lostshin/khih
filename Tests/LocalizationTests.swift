import XCTest
@testable import Khih

/// Catalog lookups with an explicit locale. English is the source; Chinese
/// assertions here only prove a translation that exists is served, not that
/// every key has one.
final class LocalizationTests: XCTestCase {
    private let zhTaiwan = Locale(identifier: "zh-Hant-TW")
    private let english = Locale(identifier: "en")
    private let now = Date(timeIntervalSince1970: 1_787_900_000)
    private let resetNow = Date(timeIntervalSince1970: 1_700_000_000)

    func testTaiwanChineseTimeAndSystemLocaleMatching() {
        let locale = Locale(identifier: "zh-Hant-TW")
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: locale),
            "1 小時 5 分鐘"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: locale),
            "51 分鐘後重置"
        )
        for identifier in ["zh-TW", "zh-Hant-TW"] {
            XCTAssertEqual(L10n.t("Settings…", locale: Locale(identifier: identifier)), "設定…")
            XCTAssertEqual(
                Bundle.preferredLocalizations(from: L10n.bundle.localizations, forPreferences: [identifier]).first,
                "zh-Hant-TW"
            )
        }
    }

    // MARK: - ElapsedCopy

    func testElapsedCopyInTaiwanChinese() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: zhTaiwan),
            "剛剛"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: zhTaiwan),
            "6 分鐘"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: zhTaiwan),
            "1 小時"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: zhTaiwan),
            "1 小時 5 分鐘"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: zhTaiwan),
            "6 分鐘前"
        )
    }

    func testElapsedCopyInEnglishWhenAsked() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: english),
            "just now"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: english),
            "6 min"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: english),
            "1 hr"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: english),
            "1 hr 5 min"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: english),
            "6 min ago"
        )
    }

    // MARK: - ResetCopy

    func testResetCopyUnderAnHourInTaiwanChinese() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: zhTaiwan),
            "51 分鐘後重置"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: zhTaiwan),
            "正在重置…"
        )
    }

    func testResetCopyUnderAnHourInEnglishWhenAsked() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: english),
            "Resets in 51 min"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: english),
            "Resetting…"
        )
    }

    // MARK: - LimitWindow.summary

    func testWindowSummaryInTaiwanChinese() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: zhTaiwan),
            "12% 已用 · 88% 剩餘"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: zhTaiwan),
            "已用 8"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: zhTaiwan),
            "剩餘 3"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: zhTaiwan),
            "尚無讀值"
        )
    }

    func testWindowSummaryInEnglishWhenAsked() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: english),
            "12% Used · 88% left"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: english),
            "8 used"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: english),
            "3 left"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: english),
            "No reading"
        )
    }

    // MARK: - Menu and settings keys

    func testMenuCopyInTaiwanChinese() {
        XCTAssertEqual(L10n.t("Always show", locale: zhTaiwan), "一律顯示")
        XCTAssertEqual(L10n.t("Settings…", locale: zhTaiwan), "設定…")
    }

    func testMenuCopyInEnglishWhenAsked() {
        XCTAssertEqual(L10n.t("Always show", locale: english), "Always show")
        XCTAssertEqual(L10n.t("Settings…", locale: english), "Settings…")
    }

    // MARK: - Sign-in

    func testSignInActionTitleStaysEnglishUnderTheTestPin() {
        XCTAssertEqual(
            SignInRoute.modal(name: "Perplexity").actionTitle,
            "Sign in to Perplexity"
        )
    }

    func testSignInCopyInTaiwanChinese() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: zhTaiwan),
            "登入 Perplexity"
        )
    }

    func testSignInCopyInEnglishWhenAsked() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: english),
            "Sign in to Perplexity"
        )
    }

    private func percentWindow(_ fraction: Double) -> LimitWindow {
        LimitWindow(id: "w", label: "Monthly limit", usedFraction: fraction)
    }
}
