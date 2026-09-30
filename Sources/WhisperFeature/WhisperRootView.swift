import AppKit
import SwiftUI
import AinkradAppKit

/// The account sidebar and the selected account's live web client, built from
/// kit components: list rows, a footer button, the kit modal and confirm dialog.
struct WhisperRootView: View {
    let store: WhisperStore
    let launcher: PluginAppLauncher

    @State private var editor: Editor?
    @State private var editorText = ""
    @State private var removing: Account?
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    /// What the modal is editing.
    private enum Editor: Equatable {
        case add
        case rename(Account)
        case addWebApp
    }

    /// The webview is an AppKit view and would sit on top of any SwiftUI
    /// scrim, so it steps aside (parked, still live) while a dialog is up.
    private var isDialogUp: Bool { editor != nil || removing != nil }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
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
            if isDialogUp {
                theme.background.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WhisperWebHost(store: store, account: account)
            }
        } else {
            AinkradEmptyState(icon: WhisperApp.icon, title: "No accounts yet",
                              message: "Add Slack, Teams or WhatsApp and sign in once.",
                              actionTitle: "Add account") { open(.add, text: "") }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A quiet column of account tiles: no header, no labels (the name is in
    /// the tooltip), the add button at the foot.
    private var sidebar: some View {
        VStack(spacing: AinkradSpacing.md) {
            ScrollView {
                VStack(spacing: AinkradSpacing.sm) {
                    ForEach(store.accounts) { account in
                        let unread = store.unread[account.id] ?? 0
                        let status = store.isLoaded(account.id) ? account.service.name
                                                               : "\(account.service.name) · hibernated"
                        AccountTile(symbol: account.service.icon, unread: unread,
                                    isSelected: account.id == store.selection,
                                    isDimmed: !store.isLoaded(account.id)) { store.selection = account.id }
                            .help("\(account.label) · \(status)")
                            .accessibilityLabel("\(account.label), \(status)\(unread > 0 ? ", \(unread) unread" : "")")
                            .ainkradContextMenu(menu(for: account))
                    }
                }
                .padding(.vertical, AinkradSpacing.md)
            }
            .scrollIndicators(.never)
            AccountTile(symbol: "plus", unread: 0, isSelected: false, isDimmed: true) { open(.add, text: "") }
                .help("Add account")
                .accessibilityLabel("Add account")
                .padding(.bottom, AinkradSpacing.md)
        }
        .frame(width: 60)
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

    @ViewBuilder private var editorForm: some View {
        switch editor {
        case .add: addForm
        case .rename(let account):
            textForm(title: "Rename account", subtitle: "How it is listed in the sidebar.", placeholder: "Name",
                     action: "Save", enabled: !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                store.rename(account.id, to: editorText)
            }
        case .addWebApp:
            textForm(title: "Add a web app", subtitle: "Any chat app with a web client, by its https:// address.",
                     placeholder: "https://chat.example.com", action: "Add", enabled: webAppURL != nil) {
                if let url = webAppURL { store.add(Account(service: .custom, label: url.host ?? "Web", customURL: url)) }
            }
        case nil: EmptyView()
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "Add account", subtitle: "Sign in once inside Whisper; it stays signed in.")
            VStack(spacing: AinkradSpacing.xs) {
                ForEach([Service.slack, .teams, .whatsapp], id: \.self) { service in
                    AinkradListRow(onTap: {
                                       store.add(Account(service: service, label: store.freshLabel(for: service)))
                                       editor = nil
                                   },
                                   leading: { AinkradIconGlyph(systemName: service.icon) },
                                   title: service.name,
                                   trailing: { EmptyView() })
                }
                AinkradListRow(onTap: { open(.addWebApp, text: "https://") },
                               leading: { AinkradIconGlyph(systemName: Service.custom.icon) },
                               title: "Other web app", subtitle: "By its https:// address",
                               trailing: { EmptyView() })
            }
            HStack {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost) { editor = nil }
            }
        }
    }

    private func textForm(title: String, subtitle: String, placeholder: String, action: String,
                          enabled: Bool, commit: @escaping () -> Void) -> some View {
        let save = { guard enabled else { return }; commit(); editor = nil }
        return VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: title, subtitle: subtitle)
            AinkradTextField(text: $editorText, placeholder: placeholder)
                .onSubmit(save)
            HStack(spacing: AinkradSpacing.sm) {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost) { editor = nil }
                AinkradButton(title: action, style: .primary, action: save)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.5)
            }
        }
    }
}

/// One sidebar tile. Drawn in `AinkradListRow`'s vocabulary (chamfered fill,
/// glowing accent edge, hover motion) because the kit has no icon-only row,
/// and the list row's title column does not fit a 60pt sidebar.
// ponytail: belongs in AinkradAppKit as a compact list-row variant; propose it there.
private struct AccountTile: View {
    let symbol: String
    let unread: Int
    let isSelected: Bool
    let isDimmed: Bool
    let onTap: () -> Void

    @State private var hovering = false
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    private var fill: Color {
        if isSelected { return theme.accentPrimary.opacity(0.18) }
        return hovering ? theme.surfaceElevated.opacity(0.6) : .clear
    }

    private var glyphColor: Color {
        if isSelected { return theme.accentSecondary }
        return theme.foreground.opacity(hovering ? 0.9 : (isDimmed ? 0.45 : 0.65))
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(glyphColor)
            .shadow(color: theme.accentSecondary.opacity(isSelected ? 0.5 : 0), radius: 4)
            .frame(width: 42, height: 42)
            .background(ChamferShape(cut: 7).fill(fill))
            .overlay(ChamferShape(cut: 7).strokeBorder(theme.accentSecondary.opacity(isSelected ? 0.35 : 0), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    AinkradBadge(text: unread > 99 ? "99+" : "\(unread)", status: .danger)
                        .fixedSize()
                        .scaleEffect(0.8, anchor: .topTrailing)
                        .offset(x: 5, y: -5)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                // The kit's selection edge: grows in, glows when selected.
                Capsule().fill(theme.accentSecondary)
                    .frame(width: 3, height: isSelected ? 22 : (hovering ? 10 : 0))
                    .shadow(color: theme.accentSecondary.opacity(isSelected ? 0.7 : 0), radius: 3)
            }
            .scaleEffect(hovering && !isSelected && !reduceMotion ? 1.06 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
            .animation(reduceMotion ? nil : AinkradMotion.hover, value: hovering)
            .animation(reduceMotion ? nil : AinkradMotion.hover, value: isSelected)
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
