import AppKit
import SwiftUI
import AinkradAppKit

/// The account rail and the selected account's live web client.
struct WhisperRootView: View {
    let store: WhisperStore
    let launcher: PluginAppLauncher

    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        Group {
            if let account = store.accounts.first(where: { $0.id == store.selection }) {
                HStack(spacing: 0) {
                    rail
                    WhisperWebHost(store: store, account: account)
                        .clipShape(ChamferShape(cut: AinkradRadius.md))
                        .padding([.vertical, .trailing], AinkradSpacing.sm)
                }
            } else {
                AinkradEmptyState(icon: WhisperApp.icon, title: "No accounts yet",
                                  message: "Add Slack, Teams or WhatsApp and sign in once. Add more, and rename them, in Settings.")
                    .overlay(alignment: .bottom) { quickAdd.padding(.bottom, AinkradSpacing.xxl) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(store.accounts) { account in
                    AccountRow(account: account, unread: store.unread[account.id] ?? 0,
                               isSelected: account.id == store.selection,
                               isLoaded: store.isLoaded(account.id)) { store.selection = account.id }
                }
            }
            .padding(AinkradSpacing.xs + 2)
        }
        .scrollIndicators(.never)
        .frame(width: 176)
    }

    private var quickAdd: some View {
        HStack(spacing: AinkradSpacing.sm) {
            ForEach([Service.slack, .teams, .whatsapp], id: \.self) { service in
                AinkradButton(title: service.name, style: .secondary, icon: service.icon) {
                    store.add(Account(service: service, label: service.name))
                }
            }
        }
    }
}

/// One rail row; owns its hover so rows light up one at a time. Same shape as
/// the SDK's `SignalSourceRail` row: chamfered fill, an accent edge, no rules.
private struct AccountRow: View {
    let account: Account
    let unread: Int
    let isSelected: Bool
    let isLoaded: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    private var fillOpacity: Double { isSelected ? 0.9 : (isHovered ? 0.45 : 0) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AinkradSpacing.sm) {
                Image(systemName: account.service.icon)
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? theme.accentSecondary : theme.foreground.opacity(isLoaded ? 0.72 : 0.4))
                Text(account.label)
                    .font(AinkradFontResolver.font(.body, weight: isSelected ? .semibold : .regular, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(isSelected ? 1 : (isHovered ? 0.9 : 0.72)))
                    .lineLimit(1)
                Spacer(minLength: AinkradSpacing.xs)
                if unread > 0 {
                    AinkradBadge(text: unread > 99 ? "99+" : "\(unread)", tint: theme.accentPrimary)
                }
            }
            .padding(.horizontal, AinkradSpacing.sm)
            .padding(.vertical, AinkradSpacing.xs + 2)
            .background(ChamferShape(cut: AinkradRadius.sm).fill(theme.surfaceElevated.opacity(fillOpacity)))
            .overlay(alignment: .leading) {
                Capsule().fill(theme.accentSecondary)
                    .frame(width: 2)
                    .padding(.vertical, 5)
                    .scaleEffect(y: isSelected ? 1 : 0, anchor: .center)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(ChamferShape(cut: AinkradRadius.sm))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isHovered)
        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isSelected)
        .onHover { isHovered = $0 }
        .help(isLoaded ? account.service.name : "\(account.service.name) · hibernated, loads when opened")
        .accessibilityLabel("\(account.label), \(unread > 0 ? "\(unread) unread" : "nothing unread")")
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
        MainActor.assumeIsolated { WhisperApp.detach(from: container) }
    }
}

extension WhisperApp {
    /// `dismantleNSView` is static and has no store; the store is process-wide anyway.
    @MainActor static func detach(from container: NSView) {
        guard let store = sharedStore else { return }
        store.detach(from: container)
    }
}
