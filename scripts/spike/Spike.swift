// Whisper spike: bare WKWebView per service, to prove the webview approach before building the plugin.
// Every signal the spike needs goes to stdout and ~/Desktop/whisper-spike.log.
import AppKit
import WebKit

let services: [(name: String, url: String, store: String)] = [
    ("WhatsApp", "https://web.whatsapp.com", "0F6B1C8A-1E57-4C1B-9F00-000000000001"),
    ("Slack", "https://app.slack.com/client", "0F6B1C8A-1E57-4C1B-9F00-000000000002"),
    ("Teams", "https://teams.microsoft.com/v2/", "0F6B1C8A-1E57-4C1B-9F00-000000000003"),
]

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/whisper-spike.log")
func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    print(line, terminator: "")
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

// Notification shim (spike items 6) + call audio tap (item 11). Injected before the page's own scripts.
let shim = """
(() => {
  const post = m => { try { webkit.messageHandlers.spike.postMessage(m) } catch (_) {} };
  const notify = (t, o) => post({ kind: 'notify', title: String(t), body: (o && o.body) || '' });
  class N extends EventTarget {
    constructor(t, o) { super(); notify(t, o) }
    static get permission() { return 'granted' }
    static requestPermission(cb) { cb && cb('granted'); return Promise.resolve('granted') }
    close() {}
  }
  window.Notification = N;
  if (window.ServiceWorkerRegistration)
    ServiceWorkerRegistration.prototype.showNotification = function (t, o) { notify(t, o); return Promise.resolve() };

  const tap = (track, side) => {
    if (track.kind !== 'audio' || track.__tapped) return;
    track.__tapped = true;
    let bytes = 0;
    try {
      const rec = new MediaRecorder(new MediaStream([track]));
      rec.ondataavailable = e => { bytes += e.data.size; post({ kind: 'audio', side, bytes }) };
      rec.start(5000);
      track.addEventListener('ended', () => rec.stop());
      post({ kind: 'audio-start', side, mime: rec.mimeType });
    } catch (e) { post({ kind: 'audio-error', side, error: String(e) }) }
  };
  const PC = window.RTCPeerConnection;
  if (PC) window.RTCPeerConnection = class extends PC {
    constructor(...a) { super(...a); this.addEventListener('track', e => tap(e.track, 'remote')); post({ kind: 'rtc-peer' }) }
  };
  const md = navigator.mediaDevices;
  if (md && md.getUserMedia) {
    const gum = md.getUserMedia.bind(md);
    md.getUserMedia = async c => { const s = await gum(c); s.getAudioTracks().forEach(t => tap(t, 'local')); return s };
  }
})();
"""

final class Tab: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let name: String
    let webView: WKWebView
    var popups: [NSWindow] = []
    var titleObs: NSKeyValueObservation?

    init(name: String, url: URL, storeID: UUID) {
        self.name = name
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID) // item 1: login survives restart
        config.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15" // look like Safari, not a bare webview
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "spike")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // Keep hidden pages running: WebKit otherwise freezes them when the window is hidden/occluded (item 10).
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if webView.responds(to: occlusion) { webView.perform(occlusion, with: false) } // SPI; KVC on a missing key throws
        log("[\(name)] occlusion SPI available: \(webView.responds(to: occlusion))")
        webView.isInspectable = true // Safari > Develop menu, for items 8/9
        titleObs = webView.observe(\.title) { wv, _ in log("[\(name)] title: \(wv.title ?? "")") }
        webView.load(URLRequest(url: url))
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        log("[\(name)] \(m.body)")
    }

    // Items 3/4/5: calls need mic + camera.
    func webView(_ w: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        log("[\(name)] media permission \(type.rawValue) for \(origin.host)")
        decisionHandler(.grant)
    }

    // Microsoft/Google login and call windows open as popups that keep window.opener.
    func webView(_ w: WKWebView, createWebViewWith config: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        log("[\(name)] popup \(action.request.url?.host ?? "")")
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        popup.uiDelegate = self
        let win = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.contentView = popup
        win.isReleasedWhenClosed = false
        win.center(); win.makeKeyAndOrderFront(nil)
        popups.append(win)
        return popup
    }

    func webViewDidClose(_ w: WKWebView) {
        popups.removeAll { if $0.contentView === w { $0.close(); return true }; return false }
    }

    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = p.allowsMultipleSelection
        panel.canChooseDirectories = p.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { log("[\(name)] pid \(w.value(forKey: "_webProcessIdentifier") ?? "?") loaded \(w.url.map { ($0.host ?? "") + $0.path } ?? "")") }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { log("[\(name)] WEB CONTENT PROCESS CRASHED"); w.reload() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var tabs: [Tab] = []
    var noNap: NSObjectProtocol?
    let container = NSView()

    func applicationDidFinishLaunching(_ n: Notification) {
        log("spike start")
        // App Nap throttles a hidden app's timers and network; a messenger must opt out.
        noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "messenger stays live")
        // No main menu = no ⌘C/⌘V/⌘Q: AppKit routes those shortcuts through menu items.
        let menu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu()
        appItem.submenu!.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.submenu = NSMenu(title: "Edit")
        for (title, sel, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                  ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editItem.submenu!.addItem(withTitle: title, action: Selector(sel), keyEquivalent: key)
        }
        menu.addItem(appItem); menu.addItem(editItem)
        NSApp.mainMenu = menu
        tabs = services.map { Tab(name: $0.name, url: URL(string: $0.url)!, storeID: UUID(uuidString: $0.store)!) }

        let picker = NSSegmentedControl(labels: tabs.map(\.name), trackingMode: .selectOne, target: self, action: #selector(pick(_:)))
        let root = NSStackView(views: [picker, container])
        root.orientation = .vertical
        root.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 850),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Whisper spike"
        window.contentView = root
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Every webview stays in the window (hidden, not removed) so background tabs keep receiving (item 10).
        for t in tabs {
            t.webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(t.webView)
            NSLayoutConstraint.activate([
                t.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                t.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                t.webView.topAnchor.constraint(equalTo: container.topAnchor),
                t.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        picker.selectedSegment = 0
        pick(picker)

        // Heartbeat: proves the app and each page are alive while hidden (item 10).
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [tabs] _ in
            log("heartbeat app-hidden=\(NSApp.isHidden) " + tabs.map { "\($0.name)=\($0.webView.title ?? "")" }.joined(separator: " "))
        }
        let cmdDir = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("cmd")
        try? FileManager.default.createDirectory(at: cmdDir, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [tabs] _ in
            for t in tabs {
                let f = cmdDir.appendingPathComponent("\(t.name).js")
                guard let js = try? String(contentsOf: f, encoding: .utf8) else { continue }
                try? FileManager.default.removeItem(at: f)
                t.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
                    switch r {
                    case .success(let v): log("[\(t.name)] cmd result: \(String(describing: v).prefix(4000))")
                    case .failure(let e): log("[\(t.name)] cmd error: \(e)")
                    }
                }
            }
        }
    }

    @objc func pick(_ s: NSSegmentedControl) {
        for (i, t) in tabs.enumerated() { t.webView.isHidden = i != s.selectedSegment }
    }

    func applicationWillTerminate(_ n: Notification) { log("spike terminating (normal quit)") }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
