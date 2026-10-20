import AppKit
import WebKit
import Darwin

final class NoctBrowserApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    var storage: BrowserWorkspace!
    var settings = BrowserSettings()
    var window: NSWindow!
    var web: WKWebView!
    let address = NSTextField()
    let status = NSTextField(labelWithString: "Web sessions clear when the workspace locks")
    let back = NSButton(), forward = NSButton()
    let settingsPanel = NSStackView()
    let homeField = NSTextField()
    let zoom = NSPopUpButton()
    var downloads: [UUID: WorkspaceDownload] = [:]
    var downloadResults: [[String: Any]] = []
    var shutdownTimer: DispatchSourceSignal?
    var auditTimer: Timer?
    var lastAuditID = 0
    var shuttingDown = false
    var permittedAuditOrigin: URL?
    var heartbeat: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            storage = try BrowserWorkspace()
            setenv("TMPDIR", storage.temporary.path + "/", 1)
            settings = try BrowserSettings.load(storage)
            try settings.save(storage)
            URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
            setupWindow()
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { [weak self] in self?.beginShutdown() }
            source.resume(); shutdownTimer = source
            heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                do { try self.storage.validate() } catch { self.beginShutdown() }
            }
            let initial = ProcessInfo.processInfo.environment["NOCT_BROWSER_URL"] ?? settings.homePage
            if ProcessInfo.processInfo.environment["NOCT_BROWSER_AUDIT"] == "1" {
                guard let url = URL(string: initial), url.host == "127.0.0.1", url.scheme == "http",
                      storage.root.appendingPathComponent("Run/NoctBrowser/audit-enabled").path.withCString({ access($0, F_OK) }) == 0 else {
                    throw BrowserFailure.message("Audit mode requires a disposable loopback fixture.")
                }
                permittedAuditOrigin = url
                auditTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollAudit() }
            }
            navigate(initial)
            try storage.write(["pid": getpid(), "persistentWebsiteData": false,
                               "temporaryDirectory": NSTemporaryDirectory(), "homeDirectory": NSHomeDirectory(),
                               "tmpdirEnvironment": String(cString: getenv("TMPDIR")), "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                               "settings": storage.settings.path, "cache": storage.cache.path,
                               "temp": storage.temporary.path, "downloads": storage.downloads.path,
                               "auditEnabled": permittedAuditOrigin != nil], to: storage.run.appendingPathComponent("ready.json"))
        } catch {
            // Refuse operation. No UserDefaults, host log or host profile fallback.
            fputs("Noct Browser: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func setupWindow() {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu(title: "Noct Browser")
        menu.addItem(item); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Noct Browser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu!.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Noct Browser"; window.delegate = self; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 600); window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        let content = window.contentView!
        let column = NSStackView(); column.orientation = .vertical; column.spacing = 0; column.alignment = .width
        column.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 9
        toolbar.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        configure(back, "Back", "chevron.left", #selector(goBack)); configure(forward, "Forward", "chevron.right", #selector(goForward))
        toolbar.addArrangedSubview(back); toolbar.addArrangedSubview(forward)
        toolbar.addArrangedSubview(button("Reload", "arrow.clockwise", #selector(reload)))
        toolbar.addArrangedSubview(button("Home", "house", #selector(home)))
        address.placeholderString = "Enter a website address"; address.font = .systemFont(ofSize: 14)
        address.target = self; address.action = #selector(openAddress); address.setAccessibilityLabel("Website address")
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(address)
        toolbar.addArrangedSubview(button("Bookmark this page", "star", #selector(bookmark)))
        toolbar.addArrangedSubview(button("Downloads", "arrow.down.circle", #selector(showDownloads)))
        toolbar.addArrangedSubview(button("Browser settings", "slider.horizontal.3", #selector(showSettings)))
        column.addArrangedSubview(toolbar)
        settingsPanel.orientation = .horizontal; settingsPanel.spacing = 12
        settingsPanel.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        settingsPanel.addArrangedSubview(NSTextField(labelWithString: "Home page"))
        homeField.setAccessibilityLabel("Home page setting"); homeField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        settingsPanel.addArrangedSubview(homeField)
        zoom.addItems(withTitles: ["75%", "100%", "125%", "150%", "200%"]); zoom.setAccessibilityLabel("Page zoom setting")
        settingsPanel.addArrangedSubview(zoom)
        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings)); save.bezelStyle = .rounded
        settingsPanel.addArrangedSubview(save); column.addArrangedSubview(settingsPanel); settingsPanel.isHidden = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self; web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true; web.pageZoom = settings.zoom
        column.addArrangedSubview(web)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [NSTextField(labelWithString: "◈  Noct workspace"), NSView(), status])
        footer.spacing = 14; footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        column.addArrangedSubview(footer)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func configure(_ button: NSButton, _ title: String, _ symbol: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.target = self; button.action = action; button.bezelStyle = .rounded
        button.toolTip = title; button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    }
    func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let value = NSButton(); configure(value, title, symbol, action); return value
    }
    func auditAllows(_ url: URL) -> Bool {
        guard let allowed = permittedAuditOrigin else { return true }
        return url.host == allowed.host && url.port == allowed.port && url.scheme == allowed.scheme
    }
    func navigate(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains(":") ? trimmed : "https://" + trimmed
        guard let url = BrowserSettings.allowedURL(candidate), auditAllows(url), !shuttingDown else {
            status.stringValue = "Enter an HTTP or HTTPS website address."; return
        }
        if url.absoluteString == "about:blank" {
            web.loadHTMLString("<html><meta name='color-scheme' content='dark light'><style>body{font:17px -apple-system;background:#101c25;color:#e7f5ef;margin:12vh 12vw}h1{font-size:42px;font-weight:600}p{line-height:1.7;color:#b0c6c3}small{color:#8aaba5}</style><h1>Your window to the web.</h1><p>Enter a website address above.<br>Bookmarks, settings and downloads live in your encrypted workspace.</p><small>Website sessions are memory-only and reset when the browser closes.</small></html>", baseURL: nil)
        } else { web.load(URLRequest(url: url)) }
    }
    @objc func openAddress() { navigate(address.stringValue) }
    @objc func goBack() { web.goBack() }
    @objc func goForward() { web.goForward() }
    @objc func reload() { web.reload() }
    @objc func home() { navigate(settings.homePage) }
    @objc func bookmark() {
        guard let url = web.url, BrowserSettings.allowedURL(url.absoluteString) != nil else { return }
        if !settings.bookmarks.contains(url.absoluteString) { settings.bookmarks.append(url.absoluteString) }
        do { try settings.save(storage); status.stringValue = "Bookmark saved in your workspace" }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc func showSettings() {
        homeField.stringValue = settings.homePage
        let choices = [0.75, 1, 1.25, 1.5, 2]
        zoom.selectItem(at: choices.firstIndex(of: settings.zoom) ?? 1)
        settingsPanel.isHidden.toggle()
    }
    @objc func saveSettings() {
        do {
            guard BrowserSettings.allowedURL(homeField.stringValue) != nil else { throw BrowserFailure.message("Use an HTTP or HTTPS home page, or about:blank.") }
            var proposed = settings; proposed.homePage = homeField.stringValue
            proposed.zoom = [0.75, 1, 1.25, 1.5, 2][max(0, zoom.indexOfSelectedItem)]
            try proposed.save(storage); settings = proposed; web.pageZoom = proposed.zoom
            settingsPanel.isHidden = true; status.stringValue = "Settings saved in your encrypted workspace"
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc func showDownloads() {
        status.stringValue = downloads.isEmpty ? "\(downloadResults.count) completed downloads · Workspace / Downloads" : "\(downloads.count) downloads in progress · Workspace temporary storage"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, BrowserSettings.allowedURL(url.absoluteString) != nil,
              auditAllows(url), !shuttingDown else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel); startDownload(navigationAction.request)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
        if !navigationResponse.canShowMIMEType || attachment {
            decisionHandler(.cancel)
            if let url = navigationResponse.response.url { startDownload(URLRequest(url: url)) }
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        address.stringValue = webView.url?.absoluteString == "about:blank" ? "" : webView.url?.absoluteString ?? ""
        back.isEnabled = webView.canGoBack; forward.isEnabled = webView.canGoForward
        window.title = (webView.title ?? "Noct Browser") + " — Noct Browser"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { status.stringValue = error.localizedDescription }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { navigate(url.absoluteString) }; return nil
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    func startDownload(_ request: URLRequest) {
        guard let url = request.url, BrowserSettings.allowedURL(url.absoluteString) != nil, auditAllows(url), !shuttingDown else { return }
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, !self.shuttingDown else { return }
            let id = UUID()
            let download = WorkspaceDownload(storage: self.storage, request: request, cookies: cookies, progress: { [weak self] amount in
                self?.status.stringValue = "Downloading \(ByteCountFormatter.string(fromByteCount: amount, countStyle: .file)) into workspace…"
            }, completion: { [weak self] result in
                guard let self = self else { return }
                self.downloads.removeValue(forKey: id)
                switch result {
                case .success(let path):
                    self.downloadResults.append(["path": path.path, "bytes": (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0])
                    self.status.stringValue = "Saved \(path.lastPathComponent) in Workspace / Downloads"
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            })
            self.downloads[id] = download; download.start()
        }
    }

    func beginShutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true; heartbeat?.invalidate(); auditTimer?.invalidate()
        web?.stopLoading(); window?.orderOut(nil)
        for value in downloads.values { value.cancel() }
        // Exit the whole WebKit UI client, releasing its nonpersistent store and
        // XPC connections. The launcher also waits for its helper processes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { beginShutdown(); return .terminateCancel }
    func windowShouldClose(_ sender: NSWindow) -> Bool { beginShutdown(); return false }

    /// A file-pipe test harness restricted to a disposable loopback fixture.
    /// No website native bridge or externally reachable debugging port exists.
    func pollAudit() {
        let path = storage.run.appendingPathComponent("request.json")
        guard let data = try? storage.read(path), let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = request["id"] as? Int, id > lastAuditID else { return }
        lastAuditID = id
        let reply: (Any?, Error?) -> Void = { [weak self] value, error in
            guard let self = self else { return }
            var result: [String: Any] = ["id": id]
            if let error = error { result["error"] = error.localizedDescription } else { result["value"] = value ?? NSNull() }
            try? self.storage.write(result, to: self.storage.run.appendingPathComponent("response.json"))
        }
        switch request["action"] as? String {
        case "evaluate":
            web.callAsyncJavaScript(request["script"] as? String ?? "return null", arguments: [:], in: nil, in: .page) { result in
                switch result { case .success(let value): reply(value, nil); case .failure(let error): reply(nil, error) }
            }
        case "settings":
            do {
                if let home = request["homePage"] as? String {
                    guard BrowserSettings.allowedURL(home) != nil else { throw BrowserFailure.message("Invalid home page") }
                    settings.homePage = home
                }
                if let zoom = request["zoom"] as? Double, zoom >= 0.5, zoom <= 2 { settings.zoom = zoom; web.pageZoom = zoom }
                try settings.save(storage)
                reply(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)), nil)
            } catch { reply(nil, error) }
        case "diagnostics":
            reply(["isPersistent": web.configuration.websiteDataStore.isPersistent, "downloads": downloadResults,
                   "activeDownloads": downloads.count, "url": web.url?.absoluteString ?? "", "zoom": settings.zoom], nil)
        case "bookmark": bookmark(); reply(settings.bookmarks, nil)
        default: reply(nil, BrowserFailure.message("Unknown audit action"))
        }
    }
}

@main struct NoctBrowserMain {
    static func main() {
        if let root = getenv("NOCT_WORKSPACE_ROOT") {
            setenv("TMPDIR", String(cString: root) + "/Apps/NoctBrowser/Temp/", 1)
        }
        let application = NSApplication.shared
        let delegate = NoctBrowserApp(); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
