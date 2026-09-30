import AppKit
import SwiftUI
import AinkradAppKit

/// The account rail and the selected account's live web client, built from
/// the kit: `AinkradAppTile` tiles, `AinkradMenuButton` to add, and the kit's
/// modal and confirm dialog instead of native alerts.
struct WhisperRootView: View {
    let store: WhisperStore
    let launcher: PluginAppLauncher

    @State private var editor: Editor?
    @State private var editorText = ""
    @State private var removing: Account?
    @Environment(\.ainkradTheme) private var theme

    /// What the modal is editing.
    private enum Editor: Equatable {
        case rename(Account)
        case addWebApp
    }

    /// The webview is an AppKit view and would sit on top of any SwiftUI
    /// scrim, so it steps aside (parked, still live) while a dialog is up.
    private var isDialogUp: Bool { editor != nil || removing != nil }

    var body: some View {
        HStack(spacing: 0) {
            rail
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .ainkradModal(isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
            editorForm
        }
        .ainkradConfirmDialog(
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            title: "Remove \(removing?.label ?? "account")?",
            message: "Whisper signs out of it and deletes its local data.",
            confirmTitle: "Remove", isDestructive: true) {
                if let removing { store.remove(removing.id) }
            }
        .onAppear {
            // A notification click that opened this pane names its account.
            if let id = launcher.takePendingLaunch().flatMap(UUID.init(uuidString:)),
               store.accounts.contains(where: { $0.id == id }) {
                store.selection = id
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let account = store.accounts.first(where: { $0.id == store.selection }) {
            Group {
                if isDialogUp {
                    theme.surface
                } else {
                    WhisperWebHost(store: store, account: account)
                }
            }
            .clipShape(ChamferShape(cut: AinkradRadius.sm))
            .padding([.vertical, .trailing], AinkradSpacing.sm)
        } else {
            AinkradEmptyState(icon: WhisperApp.icon, title: "No accounts yet",
                              message: "Add Slack, Teams or WhatsApp with the + in the rail, then sign in once.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var rail: some View {
        VStack(spacing: AinkradSpacing.sm) {
            ScrollView {
                VStack(spacing: AinkradSpacing.md) {
                    ForEach(store.accounts) { account in
                        AccountTile(account: account, unread: store.unread[account.id] ?? 0,
                                    isSelected: account.id == store.selection,
                                    isLoaded: store.isLoaded(account.id)) { store.selection = account.id }
                            .ainkradContextMenu(menu(for: account))
                    }
                }
                .padding(.vertical, AinkradSpacing.md)
            }
            .scrollIndicators(.never)
            AinkradMenuButton(items: addItems) {
                AinkradAppTile(symbol: "plus", size: 36)
                    .help("Add an account")
                    .accessibilityLabel("Add an account")
            }
            .padding(.bottom, AinkradSpacing.md)
        }
        .frame(width: 68)
    }

    private var addItems: [AinkradMenuItem] {
        [Service.slack, .teams, .whatsapp].map { service in
            AinkradMenuItem(title: service.name, systemName: service.icon) {
                store.add(Account(service: service, label: store.freshLabel(for: service)))
            }
        } + [AinkradMenuItem(title: "Other web app…", systemName: Service.custom.icon) { open(.addWebApp, text: "https://") }]
    }

    private func menu(for account: Account) -> [AinkradMenuItem] {
        [
            AinkradMenuItem(title: "Rename…", systemName: "pencil") { open(.rename(account), text: account.label) },
            AinkradMenuItem(title: "Reload", systemName: "arrow.clockwise") { store.reload(account.id) },
            AinkradMenuItem(title: "Remove…", systemName: "trash", isDestructive: true) { removing = account },
        ]
    }

    private func open(_ editor: Editor, text: String) {
        editorText = text
        self.editor = editor
    }

    // MARK: Modal

    private var webAppURL: URL? {
        guard let url = URL(string: editorText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private var canSave: Bool {
        switch editor {
        case .rename: !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .addWebApp: webAppURL != nil
        case nil: false
        }
    }

    private var editorForm: some View {
        let isRename = if case .rename = editor { true } else { false }
        return VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: isRename ? "Rename account" : "Add a web app",
                                 subtitle: isRename ? "How it is listed in the rail."
                                                    : "Any chat app with a web client, by its https:// address.")
            AinkradTextField(text: $editorText, placeholder: isRename ? "Name" : "https://chat.example.com")
                .onSubmit(save)
            HStack(spacing: AinkradSpacing.sm) {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost) { editor = nil }
                AinkradButton(title: isRename ? "Save" : "Add", style: .primary, action: save)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        switch editor {
        case .rename(let account): store.rename(account.id, to: editorText)
        case .addWebApp:
            if let url = webAppURL { store.add(Account(service: .custom, label: url.host ?? "Web", customURL: url)) }
        case nil: break
        }
        editor = nil
    }
}

/// One account: the kit's app tile with the service glyph and the account's
/// name under it, plus an unread badge.
private struct AccountTile: View {
    let account: Account
    let unread: Int
    let isSelected: Bool
    let isLoaded: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            AinkradAppTile(symbol: account.service.icon, title: account.label, size: 36, isSelected: isSelected)
                .opacity(isLoaded || isSelected ? 1 : 0.6)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        AinkradBadge(text: unread > 99 ? "99+" : "\(unread)", status: .danger)
                            .fixedSize()
                            .offset(x: 6, y: -6)
                    }
                }
                .frame(width: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isLoaded ? "\(account.label) · \(account.service.name)"
                       : "\(account.label) · \(account.service.name) · hibernated, loads when opened")
        .accessibilityLabel("\(account.label), \(account.service.name), \(unread > 0 ? "\(unread) unread" : "nothing unread")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Hosts the store's webview. The store owns it: dismantling this view parks
/// the webview rather than destroying it, so the account keeps receiving.
private struct WhisperWebHost: NSViewRepresentable {
    let store: WhisperStore
    let account: Account

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        store.attach(account, to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        MainActor.assumeIsolated { WhisperApp.sharedStore?.detach(from: container) }
    }
}
