import Foundation

/// How much of itself the notch shows when you are not using it.
///
/// Three states rather than the two that get asked for, because the default is
/// neither: at rest the notch is already a small pill that opens on contact.
/// Offering only "always" and "hidden" would quietly delete the behaviour the
/// app was designed around.
enum NotchVisibility: String, CaseIterable, Identifiable {
    /// Pinned open. The readings are always on screen.
    case alwaysShow
    /// A pill at the edge that unfolds when the pointer reaches it. The default.
    case onHover
    /// Nothing on screen at all.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysShow: return L10n.t("Always show")
        case .onHover:    return L10n.t("Show on hover")
        case .hidden:     return L10n.t("Hide")
        }
    }

    var explanation: String {
        switch self {
        case .alwaysShow:
            return L10n.t("The notch stays open with every reading visible.")
        case .onHover:
            return L10n.t("A small pill at the screen edge that opens when you reach it.")
        case .hidden:
            // Said here because a hidden notch is also a hidden way back in.
            return L10n.t("Nothing on screen. Open Codenotch again from Applications to bring these settings back.")
        }
    }
}
