import AppKit
import SwiftUI
import AinkradAppKit

/// Slack, Teams and WhatsApp in one pane, each through its official web client.
public struct WhisperApp: AinkradApp {
    public static let id = "whisper"
    public static let displayName = "Whisper"
    public static let icon = "bubble.left.and.bubble.right"

    /// One store per process, not per pane — see `WhisperStore`. The first
    /// host to ask supplies the document store and signal emitter; every
    /// instance of this app shares both, so any host would do.
    @MainActor static var sharedStore: WhisperStore?
    @MainActor static func store(for host: HostServices) -> WhisperStore {
        if let sharedStore { return sharedStore }
        let store = WhisperStore(documents: host.documents, signals: host.signals)
        sharedStore = store
        return store
    }

    @MainActor private static var server: MCPAppServer?
    @MainActor private static let draft = AccountDraft()

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(WhisperRootView(store: store(for: host), launcher: host.apps))
    }

    public static func makeSettingsView(host: HostServices) -> AnyView { AnyView(EmptyView()) }

    public static func chromeFill(host: HostServices) -> Color? { host.theme.tokens.background }

    public static func settingsCatalog(host: HostServices) -> SettingsPage? {
        let store = store(for: host)
        let root = SettingsPath(["app", id])
        let accounts = root.appending("accounts")
        let general = root.appending("general")

        var accountFields = store.accounts.map { account in
            SettingsField(
                path: accounts.appending(account.id.uuidString), label: account.label,
                help: "\(account.service.name) · \(store.isLoaded(account.id) ? "connected" : "not loaded")",
                keywords: [account.service.name.lowercased(), "account"],
                kind: .action(title: "Remove…") { confirmRemove(account, store) })
        }
        accountFields += addAccountFields(accounts, store)

        return SettingsPage(
            path: root, title: displayName, icon: icon, group: .installedApps, order: 0,
            groups: [
                SettingsGroup(path: accounts, title: "Accounts", fields: accountFields),
                SettingsGroup(path: general, title: "General", fields: [
                    SettingsField(
                        path: general.appending("hibernate"), label: "Hibernate idle accounts",
                        help: "Frees Slack, Teams and Meet after this long unseen. WhatsApp stays connected.",
                        keywords: ["hibernate", "memory", "idle", "sleep"],
                        kind: .select(
                            options: [0, 5, 15, 30, 60].map {
                                SettingsOption(id: "\($0)", title: $0 == 0 ? "Never" : "After \($0) min")
                            },
                            selection: Binding(get: { "\(store.hibernateMinutes)" },
                                               set: { store.hibernateMinutes = Int($0) ?? 15 })),
                        defaultDescription: "After 15 min",
                        isModified: { store.hibernateMinutes != 15 },
                        reset: { store.hibernateMinutes = 15 }),
                ]),
            ],
            appID: id)
    }

    private static func addAccountFields(_ group: SettingsPath, _ store: WhisperStore) -> [SettingsField] {
        let draft = draft
        var fields = [
            SettingsField(
                path: group.appending("new-service"), label: "Add account",
                help: "Sign in inside Whisper once it is added.",
                keywords: ["add", "slack", "teams", "whatsapp", "meet", "google"],
                kind: .select(options: Service.allCases.map { SettingsOption(id: $0.rawValue, title: $0.name) },
                              selection: Binding(get: { draft.service.rawValue },
                                                 set: { draft.service = Service(rawValue: $0) ?? .slack }))),
            SettingsField(path: group.appending("new-label"), label: "Name",
                          help: "How it is listed, e.g. \"Acme Slack\".",
                          kind: .text(Binding(get: { draft.label }, set: { draft.label = $0 }))),
        ]
        if draft.service == .custom {
            fields.append(SettingsField(path: group.appending("new-url"), label: "URL", help: "https://…",
                                        kind: .text(Binding(get: { draft.url }, set: { draft.url = $0 }))))
        }
        let problem = draft.problem
        fields.append(SettingsField(
            path: group.appending("new-add"), label: "Add",
            help: problem ?? "Adds \(draft.resolvedLabel) and opens it in Whisper.",
            kind: .action(title: "Add") {
                guard let account = draft.account else { return }
                store.add(account)
                draft.reset()
            }))
        return fields
    }

    static func confirmRemove(_ account: Account, _ store: WhisperStore) {
        let alert = NSAlert()
        alert.messageText = "Remove \(account.label)?"
        alert.informativeText = "This signs Whisper out of the account and deletes its local data."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.remove(account.id) }
    }
}

extension WhisperApp: AinkradAppMCP {
    public static func makeMCPServer(host: HostServices) -> MCPAppServer {
        if let server { return server }
        let made = WhisperMCP.make(store: store(for: host), log: host.log)
        server = made
        return made
    }
}

/// The Settings "Add account" editor's draft.
@MainActor @Observable final class AccountDraft {
    var service: Service = .slack
    var label = ""
    var url = ""

    var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? service.name : trimmed
    }

    private var customURL: URL? {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    var problem: String? { service == .custom && customURL == nil ? "Enter an https:// URL." : nil }

    var account: Account? {
        guard problem == nil else { return nil }
        return Account(service: service, label: resolvedLabel, customURL: service == .custom ? customURL : nil)
    }

    func reset() {
        label = ""
        url = ""
    }
}
