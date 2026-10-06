import AinkradAppKit
import AppKit
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
    private(set) var pages: [UUID: WhisperPage] = [:]

    @ObservationIgnored private let documents: PluginDocumentStore
    @ObservationIgnored private let signals: PluginSignalEmitter
    @ObservationIgnored private var parking: NSWindow?
    @ObservationIgnored private var hibernateTimer: Timer?
    @ObservationIgnored private var noNap: NSObjectProtocol?
    @ObservationIgnored private var presenceObservers: [NSObjectProtocol] = []
    private var canSave = true

    private static let stateKey = "state"
    private struct State: Codable {
        var accounts: [Account] = []
        var hibernateMinutes = 15
    }

    public init(documents: PluginDocumentStore, signals: PluginSignalEmitter) {
        self.documents = documents
        self.signals = signals
        let loaded = loadDocument(State.self, key: Self.stateKey, from: documents, app: "whisper")
        // canSave first: hibernateMinutes's didSet saves, and under @Observable
        // that setter runs even for this init assignment, so the guard must
        // already hold the loaded value before any save can run.
        canSave = loaded.canSave
        accounts = loaded.value?.accounts ?? []
        hibernateMinutes = loaded.value?.hibernateMinutes ?? 15
        selection = accounts.first?.id
        // Kept-connected accounts must be live to notify, pane open or not.
        // Deferred, so building the store (MCP listing, Settings) stays cheap
        // and launch is not held up by three web clients loading at once.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.connectKeptAccounts()
        }
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
        var label = service.name
        var n = 1
        while taken.contains(label) {
            n += 1
            label = "\(service.name) \(n)"
        }
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
        page.onNotify = { [weak self] note in self?.notify(id, note) }
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
        Task { @MainActor in self.refreshPresence() }  // once the view is in its window
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
        if let page = pages.values.first(where: { $0.webView === view }) {
            page.lastUsed = Date()
            page.setPresence(visible: false, focused: false)
        }
    }

    /// Where webviews live while no pane shows them: a window, because WebKit
    /// throttles a view with none, and off screen, because nobody should see it.
    private func parkingWindow() -> NSWindow {
        if let parking { return parking }
        let window = ParkingWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 1200, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // macOS pulls an off-screen window back onto a screen (display or
        // Space changes), so it is also fully transparent.
        window.alphaValue = 0
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
        if presenceObservers.isEmpty {
            let center = NotificationCenter.default
            for name in [
                NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ] {
                presenceObservers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refreshPresence() }
                    })
            }
        }
        guard hibernateTimer == nil else { return }
        hibernateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hibernateIdle() }
        }
    }

    /// Frees pages nobody has looked at for a while, except accounts kept
    /// connected. The data store keeps the login, so selecting the account
    /// reloads it signed in.
    // ponytail: a hibernated account shows no unread count; add a light background poll if missed messages hurt.
    func hibernateIdle(now: Date = Date()) {
        guard hibernateMinutes > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(hibernateMinutes) * 60)
        for (id, page) in pages
        where !(accounts.first { $0.id == id }?.staysConnected ?? true)
            && page.webView.window === parking && page.lastUsed < cutoff && !page.isInCall
        {
            pages.removeValue(forKey: id)?.close()
            unread[id] = nil
        }
    }

    // MARK: Notifications

    /// "Mark as read" handlers, one per notification (a handler cannot see
    /// which event invoked it). Oldest are dropped past 50.
    @ObservationIgnored private var actionTokens: [(id: String, token: AgentActionToken)] = []

    /// What a notification click carries back to Whisper.
    struct NotificationTarget: Codable {
        let account: UUID
        let note: String
        let chat: String
    }

    func notify(_ id: UUID, _ note: PageNotification) {
        guard let account = accounts.first(where: { $0.id == id }), !account.isMuted, !isLooking(at: id) else { return }
        let target = NotificationTarget(account: id, note: note.id, chat: note.title)
        let payload = (try? JSONEncoder().encode(target)) ?? Data(id.uuidString.utf8)
        var actions: [SignalAction] = []
        if !note.isCall {
            let actionID = "read:\(id.uuidString):\(note.id)"
            let token = signals.handleAction(actionID) { [weak self] in await self?.markRead(target) }
            actionTokens.append((actionID, token))
            if actionTokens.count > 50 { signals.removeActionHandler(actionTokens.removeFirst().token) }
            var markRead = SignalAction(id: actionID, label: "Mark as read")
            markRead.symbol = "checkmark.circle"
            actions = [markRead]
        }
        // A person wrote to you: `.urgent` is the host's "interrupt where the
        // user is" (a toast when Ainkrad is in front, a banner and sound when
        // not). `.info` + `.normal` routes to the feed only, so messages
        // arrived silently. The user's Signal rules (mute, quiet hours, Focus)
        // still apply on top. Calls are `.warning` too, so they stand apart.
        // The service is the link's symbol (the toast draws it beside the
        // title), so the title is just the sender. The account's own name is
        // added only when two accounts share a service, e.g. two Slacks.
        var link = SignalDeepLink(appID: WhisperApp.id, payload: payload)
        link.symbol = account.service.icon
        let shared = accounts.filter { $0.service == account.service }.count > 1
        let sender = note.title.isEmpty ? account.label : note.title
        signals.emit(
            kind: note.isCall ? "whisper.call" : "whisper.message",
            severity: note.isCall ? .warning : .info,
            title: shared ? "\(sender) · \(account.label)" : sender,
            body: note.body.isEmpty ? nil : note.body,
            importance: .urgent,
            deepLink: link,
            actions: actions,
            dedupeKey: note.isCall ? nil : note.groupKey(account: id))
    }

    /// The user is already looking at this account: Ainkrad is frontmost and
    /// its webview is on screen in a visible pane, not parked.
    private func isLooking(at id: UUID) -> Bool {
        guard selection == id, let page = pages[id] else { return false }
        return isOnScreen(page)
    }

    private func isOnScreen(_ page: WhisperPage) -> Bool {
        guard NSApp.isActive, let window = page.webView.window, window !== parking, window.isVisible else {
            return false
        }
        return window.occlusionState.contains(.visible)
    }

    /// Keeps every page's idea of visible and focused true to what the user
    /// sees, so each web app decides for itself when to notify.
    func refreshPresence() {
        for page in pages.values {
            let visible = isOnScreen(page)
            page.setPresence(visible: visible, focused: visible && page.webView.window?.isKeyWindow == true)
        }
    }

    /// A notification click: show the account, then have its web app open
    /// the chat, by replaying the click on the page's own notification, or,
    /// when the page no longer has it, opening the conversation it named.
    func open(_ payload: String) {
        guard let target = decodeTarget(payload) else { return }
        selection = target.account
        Task { await openChat(target) }
    }

    /// "Mark as read": the web app opens the chat in its page, which marks
    /// it read, without switching the account Whisper shows.
    private func markRead(_ target: NotificationTarget) async { await openChat(target) }

    private func openChat(_ target: NotificationTarget) async {
        guard let account = accounts.first(where: { $0.id == target.account }), !target.note.isEmpty else { return }
        let page = await loadedPage(for: account)
        if await page.clickNotification(target.note) { return }
        guard !target.chat.isEmpty, let script = ServiceScripts.openFromNotification(account.service) else { return }
        _ = try? await page.run(script, arguments: ["chat": target.chat, "limit": 30])
    }

    /// The JSON target, or a bare account id from a notification raised before targets existed.
    func decodeTarget(_ payload: String) -> NotificationTarget? {
        if let target = try? JSONDecoder().decode(NotificationTarget.self, from: Data(payload.utf8)),
            accounts.contains(where: { $0.id == target.account })
        {
            return target
        }
        guard let id = UUID(uuidString: payload), accounts.contains(where: { $0.id == id }) else { return nil }
        return NotificationTarget(account: id, note: "", chat: "")
    }

    func connectKeptAccounts() {
        for account in accounts where account.staysConnected { _ = page(for: account) }
    }

    public func setKeepConnected(_ id: UUID, _ keep: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].keepConnected = keep == accounts[index].service.connectedByDefault ? nil : keep
        save()
        if keep { _ = page(for: accounts[index]) }
    }

    public func setMuted(_ id: UUID, _ muted: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].muted = muted ? true : nil
        save()
    }

    private func save() {
        guard canSave else {
            AinkradLog.logger(app: "whisper", area: "persistence")
                .error("saving is off: the loaded document did not decode and could not be set aside")
            return
        }
        let state = State(accounts: accounts, hibernateMinutes: hibernateMinutes)
        guard let data = try? JSONEncoder().encode(state) else {
            AinkradLog.logger(app: "whisper", area: "persistence")
                .error("could not encode whisper state; not saving")
            return
        }
        documents.setData(data, forKey: Self.stateKey)
    }
}

/// The parking window, which AppKit may not move back onto a screen.
private final class ParkingWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
