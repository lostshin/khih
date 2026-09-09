import XCTest

/// Completeness of `Localizable.xcstrings` on disk. A missing zh-Hans
/// value still looks like English on an English Mac, so the file itself
/// is what has to be complete.
final class CatalogCoverageTests: XCTestCase {
    func testSourceLanguageIsEnglish() throws {
        XCTAssertEqual(try loadCatalog().json.sourceLanguage, "en")
    }

    func testEveryEntryHasANonEmptySimplifiedChineseValue() throws {
        let strings = try loadCatalog().json.strings
        XCTAssertFalse(strings.isEmpty, "catalog has no strings")

        let missing = strings.compactMap { key, entry -> String? in
            guard let value = entry.localizations?["zh-Hans"]?.stringUnit?.value,
                  !value.isEmpty else { return key }
            return nil
        }
        XCTAssertTrue(
            missing.isEmpty,
            "missing or empty zh-Hans for: \(missing.sorted().joined(separator: ", "))"
        )
    }

    func testCatalogHasNoMergeConflictMarkers() throws {
        XCTAssertFalse(
            try loadCatalog().raw.contains("<<<<<<"),
            "Localizable.xcstrings still has a leftover conflict marker"
        )
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
