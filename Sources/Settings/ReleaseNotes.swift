import Foundation

/// What one release changed, in the app's own words.
struct ReleaseNote: Equatable {
    /// Matched against `CFBundleShortVersionString`, so it has to be exactly
    /// the string `MARKETING_VERSION` is set to.
    let version: String
    /// One line under the title. What this release is *about*.
    let headline: String
    let changes: [Change]

    /// A title carries the change; the detail is optional, so a small fix can
    /// be a single line rather than a line padded out to match its neighbours.
    struct Change: Equatable {
        let title: String
        let detail: String

        init(title: String, detail: String = "") {
            self.title = title
            self.detail = detail
        }
    }
}

/// The release history the app ships with.
///
/// Written here rather than fetched from the appcast: it has to be there on a
/// first launch with no network, and it belongs to the build it describes.
/// Bumping `MARKETING_VERSION` without adding an entry is caught by
/// `testTheCurrentVersionHasANote`.
enum ReleaseNotes {
    static var all: [ReleaseNote] {
        [
            ReleaseNote(
                version: "1.5.0",
                headline: L10n.t("Two more providers, and a live account plan that was silently dropped."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Grok is a new ring"),
                        detail: L10n.t("SuperGrok's weekly Grok Build allowance, read from the same billing endpoint the CLI uses, with the session in ~/.grok/auth.json.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("OpenCode's Go plan is a new ring"),
                        detail: L10n.t("Reads the Go plan's official usage endpoint with the key OpenCode itself stores on sign-in — no second sign-in.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A real Codex account went unmetered"),
                        detail: L10n.t("Codex's live reading only recognised a 5-hour and a 7-day window. A free-plan account's real limit was a 30-day one, which fell through unnoticed and showed as nothing metered on an account that was genuinely tracked.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Switching a provider off now really stops it"),
                        detail: L10n.t("Opening Settings could still read a switched-off provider's account, and a reply already in flight could restore a reading you had just asked it to forget.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Contributors can build without a certificate"),
                        detail: L10n.t("make build and make test now sign themselves automatically when the maintainer's Developer ID isn't present — no Apple account needed to work on this.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.4.1",
                headline: L10n.t("Waking from sleep no longer erases a reading."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("A ring survives waking your Mac"),
                        detail: L10n.t("A brief window right after sleep, where macOS won't allow a keychain prompt yet, was mistaken for being signed out — which erased the reading and left \"waiting for the first reading\" on screen. It now ages the number instead of throwing it away, and picks back up on its own.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.4.0",
                headline: L10n.t("Two more accounts, four community fixes, and honest duplicates."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Multiple Claude Code accounts"),
                        detail: L10n.t("Keep a work login apart with CLAUDE_CONFIG_DIR? It now gets its own ring, its own limits, and its own row in Settings, beside your personal one.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("GLM added"),
                        detail: L10n.t("Z.ai's Coding Plan reads live now too, with a key borrowed from whichever tool already holds one.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A stuck Claude ring recovers on its own"),
                        detail: L10n.t("One momentary failure — the Mac waking from sleep, most often — used to lock the ring until the app restarted. It now clears itself on the next check.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Cursor sessions stop reporting work that already ended"),
                        detail: L10n.t("A crashed or abandoned chat could read as \"still working\" for a day or more. It now notices when the writing has actually stopped.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A months-old duplicate can no longer win"),
                        detail: L10n.t("Claude Code files a new keychain entry on every token rotation. An account signed in for a while could pick an old, expired one at random and show \"waiting for the first reading\" forever.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A stray click no longer pins the notch open"),
                        detail: L10n.t("Clicking near the screen edge before the notch had even opened could leave it stuck open with nothing on screen explaining why.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.3.0",
                headline: L10n.t("Codex reads live, and Always show stays on."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Codex is read live instead of from a log"),
                        detail: L10n.t("The figure came from a file Codex writes during a turn, so it was as old as the last time you used it — three days stale in one case. Codenotch now asks Codex itself, and matches its own panel.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The Codex ring notices the desktop app"),
                        detail: L10n.t("It only ever watched the files the CLI and the VS Code extension write, so work done in the desktop app never made it spin.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Always show no longer turns itself off"),
                        detail: L10n.t("Clicking the notch toggled the same flag the setting used, so a stray click quietly put it back to showing on hover.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Far fewer keychain prompts"),
                        detail: L10n.t("Once a token expired, every check went back to the keychain — a prompt a minute. It now reads the secret only when the owning app has changed it, and never retries a refusal on a timer.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A paused limit is shown as paused"),
                        detail: L10n.t("Some limits are reached while the headline still shows room. The ring reads as spent and says when it lifts.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Long messages are no longer cut off"),
                        detail: L10n.t("A tooltip with something to explain reserved one line for it however much it said.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.2.0",
                headline: L10n.t("Every session, and a tooltip that fits on the screen."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Tooltips are no longer cut off"),
                        detail: L10n.t("A card is centred on the ring it belongs to, so the first and last providers threw half of it past the end of the panel — and what fell off was the title. The panel now keeps room for it.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("As many sessions as your screen can hold"),
                        detail: L10n.t("The list was capped at four whatever you were running on. It is now solved for the display: ten on a large one, and \"and N more\" only when there is genuinely no room for the rest.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The ones that need you come first"),
                        detail: L10n.t("Waiting, then busy, then idle — so if anything is summarised away, it is what matters least.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.1.0",
                headline: L10n.t("Antigravity's real numbers, and a switch that stays off."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Antigravity shows its actual quota"),
                        detail: L10n.t("Google will not answer Codenotch directly, so it asks Antigravity's own language server instead — the same place Antigravity's usage panel gets its figure.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Usage reads both ways"),
                        detail: L10n.t("\"12% used · 88% left\", so a reading lines up with whichever end your vendor happens to show.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A way back from a declined keychain prompt"),
                        detail: L10n.t("Declining no longer looks like being signed out, and Allow access… asks macOS again.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Switching a provider off now sticks"),
                        detail: L10n.t("It stopped being read but its last reading was kept, so the ring came back at the next launch.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Distant resets show a date"),
                        detail: L10n.t("A limit renewing in four weeks said \"Mon\", which read as this Monday. It says \"28 Sep\".")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.0.0",
                headline: L10n.t("The first release."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Put the notch anywhere"),
                        detail: L10n.t("Right, left, top or bottom. It keeps clear of the Dock and the menu bar, and follows when the Dock moves.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("It joins your Mac's own notch"),
                        detail: L10n.t("On the top edge it takes the hardware's shape, so the two read as one rather than as a bar parked underneath.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Claude, Cursor, Codex and Gemini"),
                        detail: L10n.t("Each read from the tool already signed in on this Mac. Codenotch never asks for a password.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Choose where Codenotch appears"),
                        detail: L10n.t("In the Dock, in the menu bar, or nowhere at all.")
                    )
                ]
            )
        ]
    }

    static func note(for version: String) -> ReleaseNote? {
        all.first { $0.version == version }
    }

    /// The note worth showing on this launch, if there is one.
    ///
    /// `notes` is a parameter so the rule can be tested against a fixed history
    /// rather than against whatever the app happens to ship this week.
    static func unseen(in version: String,
                       lastSeen: String?,
                       notes: [ReleaseNote] = ReleaseNotes.all) -> ReleaseNote? {
        guard lastSeen != version else { return nil }
        return notes.first { $0.version == version }
    }
}
