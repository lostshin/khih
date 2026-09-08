import Foundation

/// Where the standalone Claude Code command lives, if it is installed.
///
/// Deliberately *not* the copy inside the Claude desktop app, under
/// `~/Library/Application Support/Claude/claude-code/<version>/`. Checked on a
/// real machine: that copy keeps its OAuth token in the desktop app's own
/// store (`config.json`, `oauth:tokenCacheV2`) and never writes the login
/// keychain — which is the item Codenotch reads. Renewing with it would look
/// like it worked and change nothing here, so the search refuses to return it.
enum ClaudeCLI {
    /// The usual install locations, in the order a shell would find them.
    static let candidates = [
        "/opt/homebrew/bin/claude",      // Homebrew on Apple silicon
        "/usr/local/bin/claude",         // Homebrew on Intel, and the installer
        "~/.local/bin/claude",           // the standalone installer's default
        "/usr/bin/claude"
    ]

    /// Anything under here belongs to the desktop app and is not usable for
    /// this. Matched on the resolved path, so a symlink into it is caught too.
    static let desktopOwned = "/Library/Application Support/Claude/"

    static func standalone(candidates: [String] = candidates,
                           fileManager: FileManager = .default) -> URL? {
        for path in candidates {
            let expanded = (path as NSString).expandingTildeInPath
            guard fileManager.isExecutableFile(atPath: expanded) else { continue }
            // `resolvingSymlinksInPath` because the Homebrew entry is a symlink
            // into the Caskroom, and the desktop app's copy could equally be
            // linked somewhere on PATH.
            let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
            guard !isDesktopOwned(resolved) else { continue }
            return resolved
        }
        return nil
    }

    static func isDesktopOwned(_ url: URL) -> Bool {
        url.path.contains(desktopOwned)
    }
}
