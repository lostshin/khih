import SwiftUI

/// Adds a second (or third) Codex account, each with a home of its own.
///
/// The app never handles the credential. It creates the directory, shows the
/// code, and waits — the browser half happens at ChatGPT and the CLI writes the
/// result into that directory.
struct AddCodexAccountSection: View {
    @ObservedObject var quota: QuotaController
    /// Told when an account actually joins, because the list above this section
    /// is a snapshot taken when the window opened. Without this the new account
    /// appeared in the notch immediately and in Settings only after the window
    /// lost and regained focus — the same window saying two different things.
    var onAdded: () -> Void = {}
    @State private var label = ""

    private var trimmed: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Section(L10n.t("Add a Codex account")) {
            switch quota.addAccountState {
            case .idle, .failed, .added:
                entry
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("Starting sign-in…")).foregroundStyle(.secondary)
                }
            case .waiting(let code):
                waiting(code)
            }
        }
    }

    @ViewBuilder
    private var entry: some View {
        HStack(spacing: 8) {
            TextField(L10n.t("Name this account"), text: $label)
                .textFieldStyle(.roundedBorder)
            Button(L10n.t("Sign in…")) {
                Task {
                    await quota.beginAddCodexAccount(label: trimmed)
                    // Leaving the name in place would offer it again as the
                    // name of the next account.
                    if case .added = quota.addAccountState {
                        label = ""
                        onAdded()
                    }
                }
            }
            .controlSize(.small)
            .disabled(trimmed.isEmpty)
        }

        if case .failed(let message) = quota.addAccountState {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if case .added(let name) = quota.addAccountState {
            Text(L10n.t("\(name) is signed in. Its usage now appears under Codex."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text(L10n.t("Each account gets its own configuration directory, so their sign-ins never overwrite one another."))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func waiting(_ code: CodexDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Enter this code in your browser to finish signing in:"))
                .fixedSize(horizontal: false, vertical: true)
            // Selectable and monospaced: it is going to be typed somewhere else.
            Text(code.userCode)
                .font(.title3.monospaced())
                .textSelection(.enabled)
            HStack(spacing: 12) {
                if let url = URL(string: code.verificationURL) {
                    Link(L10n.t("Open the sign-in page"), destination: url)
                }
                Button(L10n.t("Cancel")) { Task { await quota.cancelAddAccount() } }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
