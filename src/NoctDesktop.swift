import AppKit

enum LauncherError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

final class WorkspaceApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let root = RuntimeResources.sourceRoot()
    let isVM = Bundle.main.object(forInfoDictionaryKey: "NoctVMRuntime") as? Bool ?? true
    var workspace: URL!
    var state = "unknown"
    var hasLoaded = false
    var installed = false
    var running = false
    var busy = false
    var quitting = false
    var refreshing = false
    var operation = ""
    var desktopShown = false
    var browserPids: [Int] = []
    let workQueue = DispatchQueue(label: "local.encryptedworkspace.operations", qos: .userInitiated)
    let gate = DesktopWallpaper(frame: .zero)
    let desktop = WorkspaceDesktop(frame: .zero)
    let vmDesktop = VMWorkspaceView(frame: .zero)
    var vmSocket: String?
    var statusTimer: Timer?
    let heading = NSTextField(labelWithString: "Your workspace")
    let status = NSTextField(labelWithString: "Checking the encrypted volume…")
    let browserStatus = NSTextField(labelWithString: "Noct Browser")
    let message = NSTextField(wrappingLabelWithString: "")
    let password = NSSecureTextField()
    let confirmation = NSSecureTextField()
    let passwordLabel = NSTextField(labelWithString: "Workspace password")
    let confirmLabel = NSTextField(labelWithString: "Confirm password")
    let primary = NSButton(title: "Create workspace", target: nil, action: nil)
    let browser = NSButton(title: "Install Noct Browser", target: nil, action: nil)
    let lock = NSButton(title: "Lock workspace", target: nil, action: nil)
    let badge = NSImageView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        umask(0o077)
        signal(SIGPIPE, SIG_IGN)
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &noCore)
        let override = ProcessInfo.processInfo.environment["NOCT_DESKTOP_WORKSPACE"] ?? ProcessInfo.processInfo.environment["PRIVATE_WORKSPACE_FOLDER"]
        workspace = override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Noct Desktop/Workspaces/FreeBSD")
        NSApp.setActivationPolicy(.regular)
        let appMenu = NSMenu()
        let item = NSMenuItem()
        appMenu.addItem(item)
        let submenu = NSMenu(title: "Noct Desktop")
        submenu.addItem(withTitle: "Quit Noct Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Noct Desktop"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 940, height: 700)
        window.collectionBehavior = .fullScreenPrimary
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = WorkspaceStyle.ink
        let content = window.contentView!
        for view in [gate, desktop, vmDesktop] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor), view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        }
        vmDesktop.start = { [weak self] in self?.browserAction() }
        vmDesktop.lock = { [weak self] in self?.lockAction() }
        desktop.launchBrowser = { [weak self] in self?.browserAction() }
        desktop.lockWorkspace = { [weak self] in self?.lockAction() }
        desktop.toggleFullscreen = { [weak self] in self?.window.toggleFullScreen(nil) }
        desktop.focusBrowser = { [weak self] in
            guard let self = self else { return }
            for pid in self.browserPids {
                if let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.activationPolicy == .regular {
                    app.activate(options: []); break
                }
            }
        }
        desktop.desktopCommand = { [weak self] request, completion in
            guard let self = self, self.state == "unlocked", !self.busy else {
                completion(.failure(LauncherError.message("The workspace is busy or locked."))); return
            }
            self.workQueue.async {
                let result = self.execute("desktop", payload: request)
                DispatchQueue.main.async { completion(result) }
            }
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        gate.addSubview(stack)
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalToConstant: 480),
                                     stack.centerXAnchor.constraint(equalTo: gate.centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: gate.centerYAnchor)])
        heading.font = .systemFont(ofSize: 28, weight: .medium)
        let titleRow = NSStackView(views: [badge, heading])
        titleRow.orientation = .vertical
        titleRow.alignment = .centerX
        titleRow.spacing = 18
        badge.contentTintColor = WorkspaceStyle.accent
        badge.imageScaling = .scaleProportionallyUpOrDown
        badge.widthAnchor.constraint(equalToConstant: 46).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stack.addArrangedSubview(titleRow)
        status.font = .systemFont(ofSize: 13)
        status.textColor = WorkspaceStyle.muted
        stack.addArrangedSubview(status)

        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 9
        card.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        card.wantsLayer = true
        card.layer?.backgroundColor = WorkspaceStyle.panel.cgColor
        card.layer?.cornerRadius = 12
        card.addArrangedSubview(label("Your apps. Your private space.", 14, .medium))
        browserStatus.font = .systemFont(ofSize: 13)
        browserStatus.textColor = WorkspaceStyle.muted
        card.addArrangedSubview(browserStatus)
        stack.addArrangedSubview(card)
        card.isHidden = isVM
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        passwordLabel.font = .systemFont(ofSize: 12, weight: .medium)
        passwordLabel.textColor = WorkspaceStyle.muted
        stack.addArrangedSubview(passwordLabel)
        password.placeholderString = "Password"
        password.font = .systemFont(ofSize: 16)
        password.bezelStyle = .roundedBezel
        password.heightAnchor.constraint(equalToConstant: 34).isActive = true
        stack.addArrangedSubview(password)
        password.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        confirmLabel.font = .systemFont(ofSize: 12, weight: .medium)
        confirmLabel.textColor = WorkspaceStyle.muted
        stack.addArrangedSubview(confirmLabel)
        confirmation.placeholderString = "Enter it again"
        confirmation.font = .systemFont(ofSize: 16)
        confirmation.bezelStyle = .roundedBezel
        confirmation.heightAnchor.constraint(equalToConstant: 34).isActive = true
        stack.addArrangedSubview(confirmation)
        confirmation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let actions = NSStackView(views: [primary, browser, lock])
        actions.orientation = .horizontal
        actions.spacing = 12
        for button in [primary, browser, lock] {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        primary.action = #selector(primaryAction)
        primary.keyEquivalent = "\r"
        primary.bezelColor = WorkspaceStyle.accent
        browser.action = #selector(browserAction)
        lock.action = #selector(lockAction)
        stack.addArrangedSubview(actions)
        message.font = .systemFont(ofSize: 13)
        message.maximumNumberOfLines = 3
        message.textColor = WorkspaceStyle.muted
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let footer = label("Research preview", 11, .regular, WorkspaceStyle.muted)
        footer.maximumNumberOfLines = 2
        stack.addArrangedSubview(footer)
        let reportButton = NSButton(title: "About this preview", target: self, action: #selector(openNotes))
        reportButton.isBordered = false
        reportButton.contentTintColor = WorkspaceStyle.muted
        stack.addArrangedSubview(reportButton)
        window.center()
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = WorkspaceStyle.ivory) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    func execute(_ action: String, password: String? = nil, payload: [String: Any]? = nil) -> Result<[String: Any], Error> {
        do {
            if isVM { return .success(try NativeWorkspace(folder: workspace, root: root).perform(action, password: password)) }
            // Archived native-app experiments retain their separate research
            // adapter. The Noct Desktop Xcode target always uses the Swift VM.
            guard let python = Bundle.main.object(forInfoDictionaryKey: "PythonExecutable") as? String else {
                throw LauncherError.message("This bundle does not include the archived native-app research adapter.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [root.appendingPathComponent(isVM ? "src/freebsd_vm.py" : "src/workspace.py").path, "--workspace", workspace.path]
            if password != nil { process.arguments!.append("--password-stdin") }
            process.arguments!.append(action)
            let output = Pipe(), errors = Pipe(), input = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = input
            try process.run()
            if let password = password { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8)) }
            if let payload = payload { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload)) }
            try input.fileHandleForWriting.close()
            let resultData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let data = process.terminationStatus == 0 ? resultData : errorData
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw LauncherError.message("Engine exit \(process.terminationStatus), output \(resultData.count) bytes. Lock state is unknown. " + String(detail.suffix(700)))
            }
            if process.terminationStatus != 0 {
                throw LauncherError.message(parsed["error"] as? String ?? "The operation failed. Check the verification notes.")
            }
            return .success(parsed)
        } catch { return .failure(error) }
    }

    func render() {
        let created = state != "not_created"
        let unlocked = state == "unlocked"
        let known = state != "unknown"
        let showWorkspace = unlocked && known && !(busy && operation == "lock")
        let showDesktop = showWorkspace && !isVM
        desktop.isHidden = !showDesktop
        vmDesktop.isHidden = !(showWorkspace && isVM)
        gate.isHidden = showWorkspace
        if showWorkspace && isVM { vmDesktop.update(running: running, installed: installed, socket: vmSocket) }
        else { vmDesktop.clear() }
        desktop.update(installed: installed, running: running)
        if showDesktop && !desktopShown { desktop.activate() }
        if !showDesktop && desktopShown { desktop.clear() }
        desktopShown = showDesktop
        heading.stringValue = !created ? "Create your workspace" : unlocked ? "Workspace is unlocked" : "Your workspace is locked"
        status.stringValue = !created ? "Choose a password for a new encrypted volume." : unlocked ? "Noct Browser can access the mounted volume." : "The encrypted volume is unmounted."
        badge.image = NSImage(systemSymbolName: unlocked ? "lock.open.fill" : "lock.fill", accessibilityDescription: unlocked ? "Unlocked" : "Locked")
        badge.contentTintColor = unlocked ? WorkspaceStyle.warning : WorkspaceStyle.success
        browserStatus.stringValue = !unlocked ? "Noct Browser is available after unlock" : !installed ? "Noct Browser is ready to install inside this volume" : running ? "Workspace Noct Browser is running" : "Noct Browser is installed · browser is closed"
        primary.title = created ? "Unlock workspace" : "Create workspace"
        primary.isEnabled = !busy && !unlocked && known
        password.isEnabled = !busy && !unlocked
        password.isHidden = unlocked
        passwordLabel.isHidden = unlocked
        confirmation.isHidden = created
        confirmLabel.isHidden = created
        browser.title = installed ? "Launch Noct Browser" : "Install Noct Browser"
        if isVM {
            status.stringValue = !created ? "Choose a password for your private desktop." : unlocked ? "Your desktop is ready to open." : "Your apps are stopped and the encrypted disk is unmounted."
            browserStatus.stringValue = "Private apps · workspace storage · resizable desktop"
            browser.title = installed ? "Open desktop" : "Set up desktop"
        }
        browser.isEnabled = !busy && unlocked && !running
        lock.isEnabled = !busy && (unlocked || !known)
        if isVM {
            heading.stringValue = created ? "Noct Desktop" : "Create workspace"
            status.stringValue = unlocked ? "Ready" : created ? "Encrypted · locked" : "A private place for your apps."
            passwordLabel.stringValue = "Password"
            primary.title = created ? "Unlock" : "Create"
            primary.isHidden = unlocked || busy
            browser.isHidden = !unlocked || busy
            lock.isHidden = (!unlocked && known) || busy
        }
        if !known {
            heading.stringValue = hasLoaded ? "Volume state unavailable" : "Opening Noct Desktop…"
            status.stringValue = hasLoaded ? "The workspace lock state could not be verified." : "Checking the encrypted workspace volume."
            badge.contentTintColor = WorkspaceStyle.warning
            badge.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "State unknown")
        }
        if busy {
            heading.stringValue = operation == "lock" ? "Locking…" : "Preparing…"
            status.stringValue = operation == "lock" ? "Closing your apps." : "One moment."
            badge.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Working")
        }
    }

    func refresh() {
        guard !busy && !refreshing else { return }
        refreshing = true
        workQueue.async { [self] in
            let result = execute("status")
            DispatchQueue.main.async { [self] in
                refreshing = false
                guard !busy else { return }
                hasLoaded = true
                if case let .success(value) = result {
                    let wasRunning = running
                    state = value["state"] as? String ?? "not_created"
                    installed = value[isVM ? "vm_configured" : "webkit_installed"] as? Bool ?? false
                    browserPids = value[isVM ? "vm_pids" : "webkit_processes"] as? [Int] ?? []
                    vmSocket = value["display_socket"] as? String
                    running = !browserPids.isEmpty
                    if isVM && wasRunning && !running && state == "unlocked" {
                        perform("lock")
                        return
                    }
                } else if case let .failure(error) = result {
                    state = "unknown"
                    message.textColor = WorkspaceStyle.warning
                    message.stringValue = error.localizedDescription
                }
                render()
            }
        }
    }

    func perform(_ action: String, secret: String? = nil) {
        guard !busy else { return }
        busy = true
        operation = action
        message.textColor = WorkspaceStyle.muted
        message.stringValue = isVM ? "" : action == "lock" ? "Closing Noct Browser and unmounting…" : "Working…"
        render()
        if desktopShown { desktop.showMessage(action == "install-webkit" ? "Installing Noct Browser in the encrypted workspace…" : "Opening workspace Noct Browser…") }
        workQueue.async { [self] in
            let result = execute(action, password: secret)
            DispatchQueue.main.async { [self] in
                password.stringValue = ""
                confirmation.stringValue = ""
                busy = false
                operation = ""
                switch result {
                case .success:
                    message.textColor = WorkspaceStyle.muted
                    message.stringValue = isVM ? "" : action == "create" ? "Workspace created. Unlock it to install Noct Browser." : action == "lock" ? "Encrypted volume unmounted." : "Done."
                case let .failure(error):
                    message.textColor = WorkspaceStyle.warning
                    message.stringValue = error.localizedDescription
                }
                if desktopShown { desktop.showMessage(message.stringValue) }
                refresh()
            }
        }
    }

    @objc func primaryAction() {
        let secret = password.stringValue
        guard !secret.isEmpty else { message.stringValue = "Enter the workspace password."; return }
        if state == "not_created" {
            guard secret.utf8.count >= 12 else { message.stringValue = "Use at least 12 characters for the new password."; return }
            guard secret == confirmation.stringValue else { message.stringValue = "The passwords do not match."; return }
        }
        perform(state == "not_created" ? "create" : "unlock", secret: secret)
    }
    @objc func browserAction() { perform(isVM ? (installed ? "launch-vm" : "setup-vm") : (installed ? "launch-webkit" : "install-webkit")) }
    @objc func lockAction() { perform("lock") }
    @objc func openNotes() { NSWorkspace.shared.open(Bundle.main.resourceURL?.appendingPathComponent("README.md") ?? root.appendingPathComponent("README.md")) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        guard !busy else { message.stringValue = "Wait for the current operation before quitting."; return .terminateCancel }
        busy = true
        operation = "lock"
        render()
        message.stringValue = isVM ? "" : "Locking before quitting…"
        workQueue.async { [self] in
            let result = execute("lock")
            DispatchQueue.main.async { [self] in
                busy = false
                operation = ""
                switch result {
                case .success: quitting = true; sender.reply(toApplicationShouldTerminate: true)
                case let .failure(error):
                    message.stringValue = "Quit cancelled: " + error.localizedDescription
                    message.textColor = WorkspaceStyle.warning
                    sender.reply(toApplicationShouldTerminate: false)
                    refresh()
                }
            }
        }
        return .terminateLater
    }
}

@main struct NoctDesktopMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = WorkspaceApp()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
