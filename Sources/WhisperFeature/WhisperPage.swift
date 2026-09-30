import AppKit
import WebKit

/// One account's live web client. Owned by `WhisperStore`, never by a view:
/// the webview moves between the visible pane and the parking window, so a
/// SwiftUI teardown must not take the session with it.
@MainActor final class WhisperPage: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler,
    WKDownloadDelegate {
    let account: Account
    let webView: WKWebView
    var lastUsed = Date()
    var onTitle: (String) -> Void = { _ in }
    var onNotify: (PageNotification) -> Void = { _ in }

    private var popups: [NSWindow] = []
    private var titleObservation: NSKeyValueObservation?
    private var loaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

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
    var isInCall: Bool { webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none }

    func close() {
        popups.forEach { $0.close() }
        popups.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "whisper")
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    /// Waits for the first finished load, up to `timeout`.
    func waitUntilLoaded(timeout: Duration = .seconds(30)) async {
        guard !loaded else { return }
        await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                self.finishWaiters()
            }
        }
    }

    private func finishWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
        guard let body = message.body as? [String: Any], body["kind"] as? String == "notify" else { return }
        onNotify(PageNotification(id: String((body["id"] as? String ?? "").prefix(40)),
                                  title: String((body["title"] as? String ?? "").prefix(200)),
                                  body: String((body["body"] as? String ?? "").prefix(500)),
                                  tag: String((body["tag"] as? String ?? "").prefix(200))))
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        finishWaiters()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        // A clicked link that leaves the service belongs in the browser.
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true,
           let url = action.request.url, !account.owns(url) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).lastPathComponent
        var url = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        var n = 1
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
        }
        return url
    }

    // MARK: UI

    /// Sign-in flows and WhatsApp's call window are popups that need
    /// `window.opener`, so they get a real webview. Anything else opens in the browser.
    func webView(_ webView: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        if let url, url.scheme?.hasPrefix("http") == true, !account.owns(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
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
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let url = URL(string: "\(origin.protocol)://\(origin.host)")
        decisionHandler(account.owns(url) ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
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
        (try? await run("return JSON.stringify(window.__whisperClick ? window.__whisperClick(id) : false);",
                        arguments: ["id": id])) == "true"
    }

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
