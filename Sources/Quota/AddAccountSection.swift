import SwiftUI
import AppKit

struct AddCodexAccountSection: View {
    @ObservedObject var quota: QuotaController
    var onAdded: () -> Void = {}
    @State private var showing = false

    var body: some View {
        Section(L10n.t("Add a Codex account")) {
            Button(L10n.t("Add Codex account…")) { showing = true }
                .disabled(quota.isBusy)
        }
        .sheet(isPresented: $showing) {
            CodexSignInSheet(quota: quota, onAdded: onAdded)
        }
    }
}

struct CodexSignInSheet: View {
    @ObservedObject var quota: QuotaController
    var onAdded: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var loginTask: Task<Void, Never>?
    @State private var closing = false
    @FocusState private var nameFocused: Bool

    private var trimmed: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var step: Int {
        switch quota.addAccountState {
        case .starting, .waiting: return 2
        case .added: return 3
        default: return 1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.t("Add a Codex account")).font(.title2.bold())
            HStack(spacing: 16) {
                stepLabel(1, L10n.t("Name account"))
                stepLabel(2, L10n.t("Browser sign-in"))
                stepLabel(3, L10n.t("Complete"))
            }
            Divider()
            switch quota.addAccountState {
            case .idle, .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("Account name"))
                    TextField(L10n.t("For example: Personal, Work"), text: $label)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .accessibilityLabel(L10n.t("Account name"))
                    if case .failed(let message) = quota.addAccountState {
                        Text(message).foregroundStyle(.orange).font(.callout)
                    }
                }
            case .starting:
                ProgressView(L10n.t("Starting sign-in…"))
            case .waiting(let code):
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.t("Enter this code in your browser to finish signing in:"))
                    Text(code.userCode).font(.title.monospaced()).textSelection(.enabled)
                    Button(L10n.t("Copy code and open sign-in page")) {
                        guard let url = URL(string: code.verificationURL) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                        NSWorkspace.shared.open(url)
                    }
                    ProgressView(L10n.t("Waiting for browser sign-in…")).controlSize(.small)
                }
            case .added(let name):
                Label(L10n.t("\(name) is signed in. Its usage now appears under Codex."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack {
                Spacer()
                if step == 3 {
                    Button(L10n.t("Done")) { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(closing ? L10n.t("Cancelling…") : L10n.t("Cancel")) { close() }
                        .keyboardShortcut(.cancelAction)
                    if step == 1 {
                        Button(L10n.t("Sign in…")) { begin() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(trimmed.isEmpty)
                    }
                }
            }
            .disabled(closing)
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .interactiveDismissDisabled()
        .onExitCommand { close() }
        .task { await quota.cancelAddAccount(); nameFocused = true }
        .onDisappear {
            let pending = loginTask
            Task { await quota.cancelAddAccount(); await pending?.value }
        }
    }

    private func stepLabel(_ number: Int, _ title: String) -> some View {
        Text("\(number). \(title)")
            .font(.callout.weight(step == number ? .semibold : .regular))
            .foregroundStyle(step == number ? .primary : .secondary)
            .accessibilityAddTraits(step == number ? .isSelected : [])
    }

    private func begin() {
        loginTask = Task {
            await quota.beginAddCodexAccount(label: trimmed)
            if case .added = quota.addAccountState { onAdded() }
        }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        Task {
            await quota.cancelAddAccount()
            await loginTask?.value
            dismiss()
        }
    }
}

/// Renames one managed account, or puts its original name back.
///
/// A glyph on the row rather than an editable title: the name on the row is
/// part of the drag handle, and a text field there would compete with the
/// gesture that reorders the rings. On the row rather than under it because
/// Antigravity has no account summary to sit beside — it is read through a
/// CLI, so `provider.account` is nil and a link there would never appear.
///
/// The field starts on the name currently shown — including the one Khih
/// worked out — so renaming is an edit rather than a blank to fill in.
struct RenameAccountButton: View {
    @ObservedObject var quota: QuotaController
    let providerID: String
    /// What the row shows today, whether or not anyone chose it.
    let current: String

    @State private var isEditing = false
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var hasCustomName: Bool {
        quota.account(forProviderID: providerID)?.displayName != nil
    }

    var body: some View {
        Button {
            name = current
            error = nil
            isEditing = true
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        // Not gated on `isBusy` like the two beside it: this writes one small
        // file and reaches no backend.
        .help(L10n.t("Rename…") + " — "
              + L10n.t("Changes what this account is called in the notch, the menu and here."))
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Name on screen")).font(.headline)
                TextField(current, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit { save(name) }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    // Only offered once there is something to undo. On an
                    // account that has never been renamed it would be a button
                    // that puts back the name already on screen.
                    if hasCustomName {
                        Button(L10n.t("Use the default name")) { save(nil) }
                    }
                    Spacer()
                    Button(L10n.t("Save")) { save(name) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            .frame(width: 280)
            .controlSize(.small)
            .onAppear { focused = true }
        }
    }

    private func save(_ value: String?) {
        Task {
            if let message = await quota.rename(providerID: providerID, to: value) {
                error = message
            } else {
                isEditing = false
            }
        }
    }
}
