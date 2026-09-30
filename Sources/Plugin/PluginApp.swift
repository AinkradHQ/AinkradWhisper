import SwiftUI
import AinkradAppKit

/// Your app. Rename `MyApp`, the id, name, and icon. Read theme via
/// `host.theme.tokens` and persist via `host.documents` — never host internals.
struct MyApp: AinkradApp {
    static let id = "myplugin"
    static let displayName = "My Plugin"
    static let icon = "puzzlepiece.extension"

    static func makeRootView(host: HostServices) -> AnyView {
        AnyView(
            Text("Hello from My Plugin 👋")
                .foregroundStyle(host.theme.tokens.accentPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(host.theme.tokens.background)
        )
    }

    static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(Text("My Plugin settings"))
    }

    /// Worked example of the additive settings contract: declare the fields
    /// you can as real descriptors (searchable, deep-linkable, laid out with
    /// every other setting), and leave anything bespoke as a single
    /// `.custom` field wrapping your own view. Returning `nil` here (the
    /// protocol default) is also valid — it just falls back to rendering
    /// `makeSettingsView(host:)` as-is, searchable by app name only.
    static func settingsCatalog(host: HostServices) -> SettingsPage? {
        let root = SettingsPath(["app", id])
        let general = root.appending("general")

        return SettingsPage(
            path: root, title: displayName, icon: icon,
            group: .installedApps, order: 0,
            groups: [
                SettingsGroup(path: general, title: "General", fields: [
                    // A real, declared field: shows up in search and gets
                    // the shared toggle UI for free.
                    SettingsField(
                        path: general.appending("greeting"),
                        label: "Show greeting",
                        help: "Show the \"Hello from My Plugin\" banner.",
                        keywords: ["greeting", "hello", "banner"],
                        kind: .toggle(Binding(
                            get: { showGreeting(host) },
                            set: { setShowGreeting($0, host) })),
                        defaultDescription: "On",
                        isModified: { showGreeting(host) != true },
                        reset: { setShowGreeting(true, host) }),
                    // The escape hatch: anything that isn't a toggle/select/
                    // slider/text field can still be indexed and found by
                    // wrapping your existing view in `.custom`.
                    SettingsField(
                        path: general.appending("advanced"),
                        label: "Advanced",
                        help: "The plugin's own settings pane.",
                        keywords: ["advanced", "custom"],
                        kind: .custom(makeSettingsView(host: host)))
                ])
            ],
            appID: id)
    }

    /// Small `Codable` state through the host's key→data store — see
    /// `HostServices.documents`. Swap `SettingsDocument` for whatever your
    /// plugin actually needs to remember.
    private static let settingsKey = "settings"

    private static func showGreeting(_ host: HostServices) -> Bool {
        guard let data = host.documents.data(forKey: settingsKey),
              let doc = try? JSONDecoder().decode(SettingsDocument.self, from: data)
        else { return true }
        return doc.showGreeting
    }

    private static func setShowGreeting(_ value: Bool, _ host: HostServices) {
        var doc = SettingsDocument()
        if let data = host.documents.data(forKey: settingsKey),
           let existing = try? JSONDecoder().decode(SettingsDocument.self, from: data) {
            doc = existing
        }
        doc.showGreeting = value
        host.documents.setData(try? JSONEncoder().encode(doc), forKey: settingsKey)
    }
}

/// Example persisted document for the settings above.
private struct SettingsDocument: Codable {
    var showGreeting: Bool = true
}
