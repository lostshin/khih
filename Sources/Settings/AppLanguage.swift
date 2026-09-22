import Foundation

/// Which language Khih's own copy uses.
///
/// Follow System is the default. An explicit language
/// choice exists because the Mac's language is not always the one the
/// person wants this app in — bilingual machines, or a Mac in a language
/// we do not ship.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case traditionalChineseTaiwan = "zh-Hant-TW"

    var id: String { rawValue }

    /// `nil` means follow the Mac.
    ///
    /// Plain `en`, not `en_US`: these identifiers are looked up against the
    /// string catalog, whose English is filed under `en`. A region-qualified
    /// identifier misses it and falls through to whatever localization the
    /// bundle offers next — which made choosing English serve Chinese.
    var locale: Locale? {
        switch self {
        case .system:            return nil
        case .english:           return Locale(identifier: "en")
        case .traditionalChineseTaiwan: return Locale(identifier: "zh-Hant-TW")
        }
    }

    /// Language names stay in their own language so the row is
    /// recognizable when the rest of Settings is in the other one.
    var title: String {
        switch self {
        case .system:            return L10n.t("Follow System")
        case .english:           return "English"
        case .traditionalChineseTaiwan: return "繁體中文（台灣）"
        }
    }

    var explanation: String {
        switch self {
        case .system:
            return L10n.t("Matches the Mac's preferred language.")
        case .english, .traditionalChineseTaiwan:
            return L10n.t("Khih uses this language even if the Mac does not.")
        }
    }
}
