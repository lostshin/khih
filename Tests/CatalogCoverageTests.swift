import XCTest

/// The catalog's source language is English. A missing translation in any
/// other language must fall back to that English, not fail the suite — the
/// app's language is English, and a half-finished locale must not block CI.
final class CatalogCoverageTests: XCTestCase {
    func testSourceLanguageIsEnglish() throws {
        XCTAssertEqual(try loadCatalog().json.sourceLanguage, "en")
    }

    func testTheCatalogHasKeys() throws {
        XCTAssertFalse(try loadCatalog().json.strings.isEmpty, "catalog has no strings")
    }

    func testCatalogHasNoMergeConflictMarkers() throws {
        XCTAssertFalse(
            try loadCatalog().raw.contains("<<<<<<"),
            "Localizable.xcstrings still has a leftover conflict marker"
        )
    }

    func testTaiwanTranslationsPreserveFormatArguments() throws {
        let pattern = try NSRegularExpression(pattern: #"%(?:lld|@|%)"#)
        func arguments(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for (key, entry) in try loadCatalog().json.strings {
            // Future untranslated copy may still fall back to English.
            guard let value = entry.localizations?["zh-Hant-TW"]?.stringUnit?.value else { continue }
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(arguments(key), arguments(value), key)
        }
    }

    // MARK: - Loading

    /// Repo `Tests/`, so the catalog is `../Sources/Localizable.xcstrings`.
    private func catalogURL() -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Localizable.xcstrings")
            .standardizedFileURL
    }

    private func loadCatalog() throws -> (raw: String, json: CatalogFile) {
        let data = try Data(contentsOf: catalogURL())
        return (String(decoding: data, as: UTF8.self), try JSONDecoder().decode(CatalogFile.self, from: data))
    }
}

private struct CatalogFile: Decodable {
    var sourceLanguage: String
    var strings: [String: CatalogEntry]
}

private struct CatalogEntry: Decodable {
    var localizations: [String: CatalogLocalization]?
}

private struct CatalogLocalization: Decodable {
    var stringUnit: CatalogStringUnit?
}

private struct CatalogStringUnit: Decodable {
    var value: String?
}
