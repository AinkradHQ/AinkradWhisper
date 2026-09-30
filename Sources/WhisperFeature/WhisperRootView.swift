import AppKit
import SwiftUI
import AinkradAppKit

/// A slim account rail and the selected account's live web client.
struct WhisperRootView: View {
    let store: WhisperStore
    let launcher: PluginAppLauncher

    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            rail
            if let account = store.accounts.first(where: { $0.id == store.selection }) {
                WhisperWebHost(store: store, account: account)
                    .clipShape(RoundedRectangle(cornerRadius: AinkradRadius.md, style: .continuous))
                    .padding([.vertical, .trailing], AinkradSpacing.sm)
            } else {
                AinkradEmptyState(icon: WhisperApp.icon, title: "No accounts yet",
                                  message: "Add Slack, Teams or WhatsApp with the + in the rail, then sign in once.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .onAppear {
            // A notification click that opened this pane names its account.
            if let id = launcher.takePendingLaunch().flatMap(UUID.init(uuidString:)),
               store.accounts.contains(where: { $0.id == id }) {
                store.selection = id
            }
        }
    }

    private var rail: some View {
        VStack(spacing: AinkradSpacing.sm) {
            ScrollView {
                VStack(spacing: AinkradSpacing.sm) {
                    ForEach(store.accounts) { account in
                        AccountTile(account: account, unread: store.unread[account.id] ?? 0,
                                    isSelected: account.id == store.selection,
                                    isLoaded: store.isLoaded(account.id)) { store.selection = account.id }
                            .ainkradContextMenu(menu(for: account))
                    }
                }
                .padding(.vertical, AinkradSpacing.sm)
            }
            .scrollIndicators(.never)
            AinkradMenuButton(items: addItems) { AddTile() }
                .padding(.bottom, AinkradSpacing.md)
        }
        .frame(width: 60)
    }

    private var addItems: [AinkradMenuItem] {
        [Service.slack, .teams, .whatsapp].map { service in
            AinkradMenuItem(title: service.name, systemName: service.icon) {
                store.add(Account(service: service, label: store.freshLabel(for: service)))
            }
        } + [AinkradMenuItem(title: "Other web app…", systemName: Service.custom.icon) { addCustom() }]
    }

    private func menu(for account: Account) -> [AinkradMenuItem] {
        [
            AinkradMenuItem(title: "Rename…", systemName: "pencil") {
                if let name = Prompt.text("Rename \(account.label)", value: account.label) {
                    store.rename(account.id, to: name)
                }
            },
            AinkradMenuItem(title: "Reload", systemName: "arrow.clockwise") { store.reload(account.id) },
            AinkradMenuItem(title: "Remove…", systemName: "trash", isDestructive: true) {
                WhisperApp.confirmRemove(account, store)
            },
        ]
    }

    private func addCustom() {
        guard let raw = Prompt.text("Add a web app", message: "Its https:// address, e.g. https://chat.example.com"),
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host else { return }
        store.add(Account(service: .custom, label: host, customURL: url))
    }
}

/// One account: a monogram tile with an unread badge. The name is in the
/// tooltip, so two Slack workspaces read "A" and "B", not "Slack" twice.
private struct AccountTile: View {
    let account: Account
    let unread: Int
    let isSelected: Bool
    let isLoaded: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    private var tint: Color {
        switch account.service {
        case .slack: theme.accentPrimary
        case .teams: theme.accentSecondary
        case .whatsapp: theme.accentTertiary
        case .custom: theme.foreground
        }
    }

    var body: some View {
        Button(action: onSelect) {
            Text(String(account.label.prefix(1)).uppercased())
                .font(AinkradFontResolver.font(.headline, weight: .semibold, typography: typo))
                .foregroundStyle(isSelected ? theme.foreground : theme.foreground.opacity(isLoaded ? 0.85 : 0.5))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: AinkradRadius.sm, style: .continuous)
                        .fill(tint.opacity(isSelected ? 0.55 : (isHovered ? 0.35 : 0.2))))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: account.service.icon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.foreground.opacity(0.8))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(theme.surfaceElevated))
                        .offset(x: 4, y: 4)
                }
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        AinkradBadge(text: unread > 99 ? "99+" : "\(unread)", tint: theme.accentPrimary)
                            .fixedSize()
                            .offset(x: 8, y: -6)
                    }
                }
                .scaleEffect(isHovered && !isSelected ? 1.05 : 1)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.accentSecondary)
                        .frame(width: 3, height: isSelected ? 22 : (isHovered ? 8 : 0))
                        .opacity(isSelected || isHovered ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isHovered)
        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isSelected)
        .onHover { isHovered = $0 }
        .help(isLoaded ? "\(account.label) · \(account.service.name)"
                       : "\(account.label) · \(account.service.name) · hibernated, loads when opened")
        .accessibilityLabel("\(account.label), \(account.service.name), \(unread > 0 ? "\(unread) unread" : "nothing unread")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct AddTile: View {
    @State private var isHovered = false
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.foreground.opacity(isHovered ? 0.95 : 0.55))
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: AinkradRadius.sm, style: .continuous)
                .fill(theme.surfaceElevated.opacity(isHovered ? 0.8 : 0.35)))
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : AinkradMotion.hover, value: isHovered)
            .onHover { isHovered = $0 }
            .help("Add an account")
            .accessibilityLabel("Add an account")
    }
}

/// A one-field NSAlert: enough for a rename or a URL, without a sheet stack.
@MainActor enum Prompt {
    static func text(_ title: String, message: String = "", value: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
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
