import AppKit
import AinkradAppKit
import Observation
import WebKit

/// Accounts, their live pages, and unread counts. Process-wide rather than per
/// pane: a messenger has to keep receiving after its pane closes, and the
/// assistant must reach the same session the user signed in to.
///
/// Building the store does no work (MCP listing and Settings build it); the
/// first webview is created when a view or a tool asks for an account.
@MainActor @Observable public final class WhisperStore {
    public private(set) var accounts: [Account] = []
    public private(set) var unread: [UUID: Int] = [:]
    public var selection: UUID?
    public var hibernateMinutes: Int = 15 { didSet { save() } }
    public var sidebarExpanded = false { didSet { save() } }
    private(set) var pages: [UUID: WhisperPage] = [:]

    @ObservationIgnored private let documents: PluginDocumentStore
    @ObservationIgnored private let signals: PluginSignalEmitter
    @ObservationIgnored private var parking: NSWindow?
    @ObservationIgnored private var hibernateTimer: Timer?
    @ObservationIgnored private var noNap: NSObjectProtocol?

    private static let stateKey = "state"
    private struct State: Codable {
        var accounts: [Account] = []
        var hibernateMinutes = 15
        var sidebarExpanded: Bool? = nil
    }

    public init(documents: PluginDocumentStore, signals: PluginSignalEmitter) {
        self.documents = documents
        self.signals = signals
        if let data = documents.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            accounts = state.accounts
            hibernateMinutes = state.hibernateMinutes
            sidebarExpanded = state.sidebarExpanded ?? false
        }
        selection = accounts.first?.id
    }

    public var totalUnread: Int { unread.values.reduce(0, +) }

    public func add(_ account: Account) {
        accounts.append(account)
        selection = account.id
        save()
    }

    public func rename(_ id: UUID, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = trimmed
        save()
    }

    /// A label that does not collide: "Slack", then "Slack 2", "Slack 3"…
    func freshLabel(for service: Service) -> String {
        let taken = Set(accounts.map(\.label))
        var label = service.name, n = 1
        while taken.contains(label) { n += 1; label = "\(service.name) \(n)" }
        return label
    }

    func reload(_ id: UUID) { pages[id]?.webView.reload() }

    public func remove(_ id: UUID) {
        pages.removeValue(forKey: id)?.close()
        unread[id] = nil
        accounts.removeAll { $0.id == id }
        if selection == id { selection = accounts.first?.id }
        save()
        // The login lives in the data store; removing the account signs it out.
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
    }

    /// "slack", "Work Slack" or an id — whatever the assistant was told.
    public func resolve(_ reference: String) -> Account? {
        let ref = reference.trimmingCharacters(in: .whitespaces).lowercased()
        if let byID = accounts.first(where: { $0.id.uuidString.lowercased() == ref }) { return byID }
        if let byLabel = accounts.first(where: { $0.label.lowercased() == ref }) { return byLabel }
        let byService = accounts.filter { $0.service.rawValue == ref || $0.service.name.lowercased() == ref }
        return byService.count == 1 ? byService[0] : nil
    }

    // MARK: Pages

    func isLoaded(_ id: UUID) -> Bool { pages[id] != nil }

    /// The account's page, created (and parked off screen) on first use.
    func page(for account: Account) -> WhisperPage {
        if let page = pages[account.id] { return page }
        startBackgroundSupport()
        let page = WhisperPage(account: account)
        let id = account.id
        page.onTitle = { [weak self] title in self?.unread[id] = unreadCount(fromTitle: title) }
        page.onNotify = { [weak self] title, body in self?.notify(id, title: title, body: body) }
        pages[id] = page
        park(page.webView)
        return page
    }

    /// A page that has finished loading, for tools that script it.
    func loadedPage(for account: Account) async -> WhisperPage {
        let page = page(for: account)
        await page.waitUntilLoaded()
        return page
    }

    /// Shows the account's webview in `container`, taking it from wherever it was.
    func attach(_ account: Account, to container: NSView) {
        let webView = page(for: account).webView
        pages[account.id]?.lastUsed = Date()
        guard webView.superview !== container else { return }
        container.subviews.forEach { park($0) }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    /// Moves every webview out of `container` so it keeps running once the pane is gone.
    func detach(from container: NSView) {
        container.subviews.forEach { park($0) }
    }

    private func park(_ view: NSView) {
        let window = parkingWindow()
        guard view.window !== window else { return }
        view.removeFromSuperview()
        view.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(view)
        if let page = pages.values.first(where: { $0.webView === view }) { page.lastUsed = Date() }
    }

    /// Where webviews live while no pane shows them: a window, because WebKit
    /// throttles a view with none, and off screen, because nobody should see it.
    private func parkingWindow() -> NSWindow {
        if let parking { return parking }
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1200, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.orderBack(nil)
        parking = window
        return window
    }

    // MARK: Background

    private func startBackgroundSupport() {
        // App Nap freezes a hidden app's pages (WhatsApp stuck mid-sync in the
        // spike). Idle system sleep is still allowed.
        if noNap == nil {
            noNap = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Whisper keeps messengers connected")
        }
        guard hibernateTimer == nil else { return }
        hibernateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hibernateIdle() }
        }
    }

    /// Frees Slack and Teams pages nobody has looked at for a while. The data
    /// store keeps the login, so selecting the account reloads it signed in.
    // ponytail: a hibernated account shows no unread count; add a light background poll if missed messages hurt.
    func hibernateIdle(now: Date = Date()) {
        guard hibernateMinutes > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(hibernateMinutes) * 60)
        for (id, page) in pages where page.account.service.hibernates
            && page.webView.window === parking && page.lastUsed < cutoff {
            pages.removeValue(forKey: id)?.close()
            unread[id] = nil
        }
    }

    private func notify(_ id: UUID, title: String, body: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        signals.emit(kind: "whisper.message", severity: .info,
                     title: title.isEmpty ? account.label : "\(account.label) · \(title)",
                     body: body.isEmpty ? nil : body,
                     deepLink: SignalDeepLink(appID: WhisperApp.id, payload: Data(id.uuidString.utf8)))
    }

    private func save() {
        let state = State(accounts: accounts, hibernateMinutes: hibernateMinutes, sidebarExpanded: sidebarExpanded)
        documents.setData(try? JSONEncoder().encode(state), forKey: Self.stateKey)
    }
}
