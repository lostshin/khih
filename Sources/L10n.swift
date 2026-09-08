import Foundation

/// Visible copy. English source strings are the keys; `Localizable.xcstrings`
/// supplies every other language.
///
/// Looked up against this module's bundle, not `Bundle.main`, so unit tests
/// still find the catalog when the test host is the test bundle.
enum L10n {
    private final class Token {}

    static var bundle: Bundle { Bundle(for: Token.self) }

    /// Tests pin English so existing assertions stay stable on a Chinese Mac.
    /// The running app uses the system locale.
    static var locale: Locale {
        if NSClassFromString("XCTestCase") != nil {
            return Locale(identifier: "en")
        }
        return .current
    }

    static func t(_ key: String.LocalizationValue, locale: Locale = locale) -> String {
        // `String(localized:locale:)` only formats interpolated numbers; it
        // still looks the string up in the bundle's preferred language. The
        // resource carries the locale into the lookup, which is what the
        // XCTest pin needs on a Chinese Mac.
        String(localized: LocalizedStringResource(
            key, locale: locale, bundle: .atURL(bundle.bundleURL)
        ))
    }
}
