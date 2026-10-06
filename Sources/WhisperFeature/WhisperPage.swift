import AppKit
import WebKit

/// One account's live web client. Owned by `WhisperStore`, never by a view:
/// the webview moves between the visible pane and the parking window, so a
/// SwiftUI teardown must not take the session with it.
@MainActor
final class WhisperPage: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler,
    WKDownloadDelegate
{
    let account: Account
    let webView: WKWebView
    var lastUsed = Date()
    var onTitle: (String) -> Void = { _ in }
    var onNotify: (PageNotification) -> Void = { _ in }

    private var popups: [NSWindow] = []
    private var titleObservation: NSKeyValueObservation?
    private var loaded = false
    private var loadWaiters: [UUID: (continuation: CheckedContinuation<Void, Never>, timeout: Task<Void, Never>)] =
        [:]

    init(account: Account) {
        self.account = account
        let config = WKWebViewConfiguration()
        // One persistent store per account: logins survive restarts, and two
        // Slack workspaces never share cookies.
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.id)
        // WhatsApp Web refuses unknown WebKit agents; look like Safari.
        config.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(
            WKUserScript(source: Self.notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.presenceShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "whisper")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // Hidden pages otherwise get frozen. SPI: only through responds(to:) —
        // KVC on a missing key throws, and that once hung launch silently.
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if webView.responds(to: occlusion) { webView.perform(occlusion, with: false) }
        #if DEBUG
        webView.isInspectable = true
        #endif
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            let title = (change.newValue ?? nil) ?? ""
            Task { @MainActor in self?.onTitle(title) }
        }
        if let url = account.url { webView.load(URLRequest(url: url)) }
    }

    /// A call is live while the page holds the camera or microphone; such a
    /// page must never hibernate, or switching accounts would hang up.
    var isInCall: Bool {
        inCallForTesting ?? (webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none)
    }
    /// Tests only: WebKit's capture state cannot be faked.
    var inCallForTesting: Bool?

    func close() {
        popups.forEach { $0.close() }
        popups.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "whisper")
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    /// Waits for the first finished load, up to `timeout`.
    /// Each waiter's own timeout releases only that waiter; the load releases
    /// them all and cancels their timeouts.
    func waitUntilLoaded(timeout: Duration = .seconds(30)) async {
        guard !loaded else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            let timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self.loadWaiters.removeValue(forKey: id)?.continuation.resume()
            }
            loadWaiters[id] = (continuation, timer)
        }
    }

    private func finishWaiters() {
        let waiters = loadWaiters.values
        loadWaiters.removeAll()
        for waiter in waiters {
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    /// Runs an async JS function body in the page. `arguments` arrive as JS
    /// variables, never spliced into source, so chat names and message text
    /// cannot inject code. The body must `return JSON.stringify(…)`.
    func run(_ body: String, arguments: [String: Any] = [:]) async throws -> String {
        lastUsed = Date()
        let value = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        return value as? String ?? "null"
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let note = Self.notification(from: message.body) { onNotify(note) }
    }

    /// The shim's `notify` message, each field capped so a page cannot flood a signal.
    static func notification(from message: Any) -> PageNotification? {
        guard let body = message as? [String: Any], body["kind"] as? String == "notify" else { return nil }
        return PageNotification(
            id: String((body["id"] as? String ?? "").prefix(40)),
            title: String((body["title"] as? String ?? "").prefix(200)),
            body: String((body["body"] as? String ?? "").prefix(500)),
            tag: String((body["tag"] as? String ?? "").prefix(200)))
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        finishWaiters()
        applyPresence()  // a reload starts from the shim's default
    }

    // MARK: Presence

    private var presence: (visible: Bool, focused: Bool)?

    /// Tells the page whether the user can see it and is using it. WebKit
    /// reports a parked webview as visible and focused (occlusion detection
    /// is off so it keeps running), and Teams then shows its own in-page toast
    /// instead of a notification, so it never notified at all.
    func setPresence(visible: Bool, focused: Bool) {
        guard presence?.visible != visible || presence?.focused != focused else { return }
        presence = (visible, focused)
        applyPresence()
    }

    private func applyPresence() {
        guard let presence else { return }
        webView.evaluateJavaScript(
            "window.__whisperPresence && window.__whisperPresence(\(presence.visible), \(presence.focused))")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        // A clicked link that leaves the service belongs in the browser.
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true,
            let url = action.request.url, !account.owns(url)
        {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        Self.downloadDestination(
            for: suggestedFilename, in: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
    }

    /// `folder/<name>`, or "<stem> 2.<ext>", "<stem> 3.<ext>"… when taken. Only
    /// the last path component of the page's suggestion is used.
    nonisolated static func downloadDestination(for suggestedFilename: String, in folder: URL) -> URL {
        let name = (suggestedFilename as NSString).lastPathComponent
        var url = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        var n = 1
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
        }
        return url
    }

    // MARK: UI

    /// Sign-in flows and WhatsApp's call window are popups that need
    /// `window.opener`, so they get a real webview. Anything else opens in the browser.
    func webView(
        _ webView: WKWebView, createWebViewWith config: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = action.request.url
        if let url, url.scheme?.hasPrefix("http") == true, !account.owns(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let window = NSWindow(
            contentRect: popup.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = account.label
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeAll { window in
            guard window.contentView === webView else { return false }
            window.close()
            return true
        }
    }

    /// Calls: camera and mic for the service's own origin only.
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let url = URL(string: "\(origin.protocol)://\(origin.host)")
        decisionHandler(account.owns(url) ? .grant : .deny)
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    /// Clicks the page's own notification object, so the web app runs its own
    /// click handler, which opens the chat that notified. False when the page
    /// no longer holds it (reloaded, or a service-worker notification).
    func clickNotification(_ id: String) async -> Bool {
        (try? await run(
            "return JSON.stringify(window.__whisperClick ? window.__whisperClick(id) : false);",
            arguments: ["id": id])) == "true"
    }

    /// `document.visibilityState`, `hidden` and `hasFocus()` as Whisper knows
    /// them, not as WebKit reports a parked view. Starts hidden, since pages
    /// load parked; `setPresence` updates it and fires the events a browser
    /// fires when a tab is shown, hidden, focused or blurred.
    static let presenceShim = """
        (() => {
          let visible = false, focused = false;
          Object.defineProperty(Document.prototype, 'visibilityState', { configurable: true, get: () => visible ? 'visible' : 'hidden' });
          Object.defineProperty(Document.prototype, 'hidden', { configurable: true, get: () => !visible });
          Document.prototype.hasFocus = function () { return focused };
          window.__whisperPresence = (v, f) => {
            const shown = v !== visible, focus = f !== focused;
            visible = v; focused = f;
            if (shown) document.dispatchEvent(new Event('visibilitychange'));
            if (focus) window.dispatchEvent(new Event(f ? 'focus' : 'blur'));
          };
        })();
        """

    /// Replaces the web Notification API (a WKWebView has none) and forwards
    /// each notification to the host as a signal. Each one is kept (the last
    /// 50) under an id, so a later click on the banner can be replayed into the
    /// page as a click on the notification the web app created.
    static let notificationShim = """
        (() => {
          const post = m => { try { webkit.messageHandlers.whisper.postMessage(m) } catch (_) {} };
          const notes = new Map();
          let seq = 0;
          const notify = (t, o, n) => {
            const id = Date.now().toString(36) + '-' + (++seq);
            if (n) { notes.set(id, n); if (notes.size > 50) notes.delete(notes.keys().next().value) }
            post({ kind: 'notify', id, title: String(t), body: String((o && o.body) || ''), tag: String((o && o.tag) || '') });
          };
          class N extends EventTarget {
            constructor(t, o) {
              super();
              this.title = String(t); this.body = (o && o.body) || ''; this.tag = (o && o.tag) || ''; this.data = o && o.data;
              this.onclick = null; this.onclose = null; this.onshow = null; this.onerror = null;
              notify(t, o, this);
            }
            static get permission() { return 'granted' }
            static requestPermission(cb) { cb && cb('granted'); return Promise.resolve('granted') }
            addEventListener(type, fn, o) { if (type === 'click') this.__clickListeners = (this.__clickListeners || 0) + 1; super.addEventListener(type, fn, o) }
            close() {}
          }
          window.Notification = N;
          // True only when the web app's own click handling ran; a notification
          // it never listened to must fall through to opening the chat by name.
          window.__whisperClick = id => {
            const n = notes.get(id);
            if (!n || !(n.onclick || n.__clickListeners)) return false;
            notes.delete(id);
            const e = new Event('click', { cancelable: true });
            try { n.onclick && n.onclick.call(n, e) } catch (_) {}
            n.dispatchEvent(e);
            return true;
          };
          if (window.ServiceWorkerRegistration)
            ServiceWorkerRegistration.prototype.showNotification = function (t, o) { notify(t, o, null); return Promise.resolve() };
        })();
        """
}

/// `WKUserContentController` retains its handlers; this breaks the page ↔
/// controller cycle so a hibernated page is actually freed.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
