import Foundation

/// Whose account a provider reads.
///
/// Settings lists one row per account, and a Mac signed in to several Codex
/// accounts plus Claude and Antigravity showed them as siblings of equal rank:
/// four rows differing only by a name the user chose, with the other tools
/// interleaved among them. Grouping is presentation only — the stored order
/// stays one flat list, because that is what dragging a row rearranges.
enum ProviderFamily: CaseIterable {
    case openAI
    case anthropic
    case google
    case other

    var title: String {
        switch self {
        // Company names, not translated: they are spelled the same everywhere
        // and a localised spelling would read as a different company.
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google:    return "Google"
        case .other:     return L10n.t("Other tools")
        }
    }

    /// Uses each provider's own idea of what belongs to it, rather than a
    /// second list of prefixes that could disagree with the first.
    static func of(providerID id: String) -> ProviderFamily {
        if CodexProfile.isCodex(providerID: id) { return .openAI }
        if ClaudeProfile.isClaude(providerID: id) { return .anthropic }
        if id == "gemini" || id == "gemini-api" { return .google }
        return .other
    }

    /// The families present, each with its members, keeping the order the items
    /// arrived in: a family sits where its first member sat, so the groups
    /// follow the order the user dragged rather than an alphabet.
    ///
    /// `.other` is the exception and always goes last. It is not a company, it
    /// is everything that is not one, and a heading that means "the rest"
    /// reads wrong anywhere but the end.
    static func groups<T>(_ items: [T], id: (T) -> String) -> [ProviderFamilyGroup<T>] {
        var order: [ProviderFamily] = []
        var grouped: [ProviderFamily: [T]] = [:]
        for item in items {
            let family = of(providerID: id(item))
            if grouped[family] == nil { order.append(family) }
            grouped[family, default: []].append(item)
        }
        return order
            .sorted { ($0 == .other ? 1 : 0) < ($1 == .other ? 1 : 0) }
            .map { ProviderFamilyGroup(family: $0, items: grouped[$0] ?? []) }
    }
}

/// A named type rather than a tuple, because `ForEach` addresses its elements
/// by key path and there are no key paths into tuples.
struct ProviderFamilyGroup<T>: Identifiable {
    let family: ProviderFamily
    let items: [T]
    var id: ProviderFamily { family }
}
