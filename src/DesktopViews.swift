import AppKit

enum WorkspaceStyle {
    // Noctweave's public visual design system: plum, ivory and coral.
    static let ink = NSColor(srgbRed: 18/255, green: 11/255, blue: 15/255, alpha: 1)
    static let panel = NSColor(srgbRed: 42/255, green: 27/255, blue: 33/255, alpha: 1)
    static let accent = NSColor(srgbRed: 201/255, green: 106/255, blue: 97/255, alpha: 1)
    static let ivory = NSColor(srgbRed: 250/255, green: 243/255, blue: 234/255, alpha: 1)
    static let muted = NSColor(srgbRed: 189/255, green: 169/255, blue: 170/255, alpha: 1)
    static let success = NSColor(srgbRed: 121/255, green: 198/255, blue: 163/255, alpha: 1)
    static let warning = NSColor(srgbRed: 227/255, green: 168/255, blue: 93/255, alpha: 1)
    static let mint = accent
    static func text(_ value: String, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
    static func symbol(_ name: String, size: CGFloat = 24) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }
}

class DesktopWallpaper: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [WorkspaceStyle.ink,
                           NSColor(srgbRed: 27/255, green: 18/255, blue: 23/255, alpha: 1),
                           NSColor(srgbRed: 62/255, green: 26/255, blue: 34/255, alpha: 1)])!
            .draw(in: bounds, angle: 28)
        for index in 0..<3 {
            let circle = NSBezierPath(ovalIn: NSRect(x: bounds.width * (0.22 + Double(index) * 0.15), y: -bounds.height * (0.62 + Double(index) * 0.05),
                                                    width: bounds.width * 1.24, height: bounds.height * 1.24))
            WorkspaceStyle.accent.withAlphaComponent(0.055).setFill()
            circle.fill()
        }
    }
}

/// A real keyboard-accessible desktop shortcut. Positions are saved only on the
/// encrypted filesystem. A click selects; a double click or Return opens it.
final class WorkspaceIcon: NSView {
    let identifierName: String
    var open: (() -> Void)?
    var moved: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    private let imageView = NSImageView()
    private let caption = WorkspaceStyle.text("", 12, .medium)
    override var acceptsFirstResponder: Bool { true }

    init(id: String, title: String, image: NSImage?, tint: NSColor) {
        identifierName = id
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 104))
        imageView.image = image
        imageView.contentTintColor = tint
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 23, y: 38, width: 54, height: 54)
        caption.stringValue = title
        caption.alignment = .center
        caption.frame = NSRect(x: 2, y: 8, width: 96, height: 22)
        addSubview(imageView); addSubview(caption)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp("Double click to open. Drag to move.")
        toolTip = "Open \(title)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.white.withAlphaComponent(0.12).setFill()
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 12, yRadius: 12)
            shape.fill()
            NSColor.white.withAlphaComponent(0.2).setStroke(); shape.lineWidth = 1; shape.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        for case let icon as WorkspaceIcon in superview?.subviews ?? [] { icon.selected = icon === self }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { open?(); return }
        guard let parent = superview, let window = window else { return }
        let origin = frame.origin
        let start = parent.convert(event.locationInWindow, from: nil)
        var didMove = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = parent.convert(next.locationInWindow, from: nil)
            let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
            if abs(delta.x) + abs(delta.y) < 4 && !didMove { continue }
            didMove = true
            frame.origin = NSPoint(x: min(max(18, origin.x + delta.x), parent.bounds.width - frame.width - 18),
                                   y: min(max(120, origin.y + delta.y), parent.bounds.height - frame.height - 76))
        }
        if didMove { moved?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { open?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { open?(); return true }
}

final class WorkspaceFiles: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var command: (([String: Any], @escaping (Result<[String: Any], Error>) -> Void) -> Void)?
    var notify: ((String) -> Void)?
    var didClose: (() -> Void)?
    var entries: [[String: Any]] = []
    var folder = "Home/Desktop"
    private let table = NSTableView()
    private let location = WorkspaceStyle.text("Desktop", 14, .semibold)
    private let count = WorkspaceStyle.text("", 11, color: .secondaryLabelColor)
    private let empty = WorkspaceStyle.text("This folder is ready for your files.", 14, color: .secondaryLabelColor)
    private var history: [String] = []
    private var controls: [NSButton] = []
    private var loading = false
    private var generation = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = WorkspaceStyle.panel.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        shadow = NSShadow(); shadow?.shadowBlurRadius = 28; shadow?.shadowOffset = NSSize(width: 0, height: -12)
        shadow?.shadowColor = .black.withAlphaComponent(0.35)
        let header = NSStackView()
        header.orientation = .horizontal; header.spacing = 12
        let close = NSButton(image: WorkspaceStyle.symbol("xmark.circle.fill", size: 16)!, target: self, action: #selector(closePanel))
        close.isBordered = false; close.contentTintColor = .secondaryLabelColor
        close.setAccessibilityLabel("Close Files")
        let back = button("", symbol: "chevron.left", action: #selector(backAction))
        back.setAccessibilityLabel("Back")
        header.addArrangedSubview(close); header.addArrangedSubview(back); header.addArrangedSubview(location)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(button("New folder", symbol: "folder.badge.plus", action: #selector(newFolder)))
        header.addArrangedSubview(button("Import files", symbol: "square.and.arrow.down", action: #selector(importFiles)))
        header.translatesAutoresizingMaskIntoConstraints = false; addSubview(header)
        let sidebar = NSStackView()
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 10
        sidebar.addArrangedSubview(WorkspaceStyle.text("FAVORITES", 10, .semibold, color: .secondaryLabelColor))
        for (title, symbol, value) in [("Desktop", "menubar.dock.rectangle", "Home/Desktop"),
                                       ("Documents", "doc.on.doc", "Home/Documents"),
                                       ("Downloads", "arrow.down.circle", "Downloads")] {
            let item = button(title, symbol: symbol, action: #selector(favorite(_:)))
            item.identifier = NSUserInterfaceItemIdentifier(value)
            sidebar.addArrangedSubview(item)
        }
        let info = NSTextField(wrappingLabelWithString: "Stored in your\nencrypted workspace")
        info.font = .systemFont(ofSize: 11); info.textColor = .secondaryLabelColor
        sidebar.addArrangedSubview(info)
        sidebar.translatesAutoresizingMaskIntoConstraints = false; addSubview(sidebar)
        table.headerView = NSTableHeaderView()
        for (id, title, width) in [("name", "Name", 320.0), ("kind", "Kind", 90.0), ("size", "Size", 85.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width
            if id == "name" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self
        table.rowHeight = 36; table.style = .fullWidth; table.backgroundColor = .clear
        table.target = self; table.doubleAction = #selector(openSelection)
        table.setAccessibilityLabel("Workspace files")
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        empty.translatesAutoresizingMaskIntoConstraints = false; addSubview(empty)
        count.translatesAutoresizingMaskIntoConstraints = false; addSubview(count)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14), header.heightAnchor.constraint(equalToConstant: 32),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22), sidebar.widthAnchor.constraint(equalToConstant: 140),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -38),
            count.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 8),
            count.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.image = WorkspaceStyle.symbol(symbol, size: 13); result.imagePosition = .imageLeading
        result.bezelStyle = .inline; controls.append(result)
        return result
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let key = tableColumn?.identifier.rawValue ?? "name"
        let kind = entry["kind"] as? String ?? "file"
        if key == "name" {
            let cell = NSTableCellView()
            let icon = NSImageView()
            icon.image = WorkspaceStyle.symbol(kind == "folder" ? "folder.fill" : kind == "link" ? "link" : "doc", size: 16)
            icon.contentTintColor = kind == "folder" ? WorkspaceStyle.mint : .secondaryLabelColor
            let text = WorkspaceStyle.text(entry["name"] as? String ?? "")
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(icon); cell.addSubview(text)
            icon.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20), text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.textField = text; cell.imageView = icon
            return cell
        }
        let value = key == "kind" ? kind.capitalized : kind == "folder" ? "—" : ByteCountFormatter.string(fromByteCount: (entry["size"] as? NSNumber)?.int64Value ?? 0, countStyle: .file)
        return WorkspaceStyle.text(value, 12, color: .secondaryLabelColor)
    }
    func show(folder path: String, remember: Bool = true) {
        guard !loading else { return }
        if remember && path != folder { history.append(folder) }
        folder = path
        request(["action": "list", "folder": path])
    }
    private func request(_ payload: [String: Any]) {
        guard !loading else { return }
        loading = true; controls.forEach { $0.isEnabled = false }
        let epoch = generation
        command?(payload) { [weak self] result in
            guard let self = self, self.generation == epoch else { return }
            self.loading = false; self.controls.forEach { $0.isEnabled = true }
            switch result {
            case let .success(value):
                self.entries = value["entries"] as? [[String: Any]] ?? []
                self.folder = value["folder"] as? String ?? self.folder
                self.location.stringValue = self.folder.replacingOccurrences(of: "Home/", with: "").replacingOccurrences(of: "/", with: "  /  ")
                self.table.reloadData(); self.empty.isHidden = !self.entries.isEmpty
                self.count.stringValue = "\(self.entries.count) item\(self.entries.count == 1 ? "" : "s") · Encrypted volume"
                if payload["action"] as? String == "import" { self.notify?("Files copied into the workspace. The originals stay in their folders.") }
            case let .failure(error): self.notify?(error.localizedDescription)
            }
        }
    }
    func clear() {
        generation += 1; loading = false; entries.removeAll(); history.removeAll()
        folder = "Home/Desktop"; location.stringValue = "Files"; count.stringValue = ""
        table.reloadData(); isHidden = true
    }
    @objc private func favorite(_ sender: NSButton) { show(folder: sender.identifier!.rawValue) }
    @objc private func closePanel() { isHidden = true; didClose?() }
    @objc private func backAction() { if let last = history.popLast() { show(folder: last, remember: false) } }
    @objc private func openSelection() {
        guard table.clickedRow >= 0, table.clickedRow < entries.count else { return }
        let entry = entries[table.clickedRow]
        if entry["kind"] as? String == "folder", let path = entry["path"] as? String { show(folder: path) }
        else { notify?("File stored in the workspace. File editing and external app assignment are not available in this prototype yet.") }
    }
    @objc private func newFolder() {
        guard !loading, let window = window else { return }
        let alert = NSAlert(); alert.messageText = "New folder"
        alert.informativeText = "Create a folder in \(folder.replacingOccurrences(of: "Home/", with: ""))."
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        name.placeholderString = "Folder name"; alert.accessoryView = name
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let self = self, !self.isHidden else { return }
            self.request(["action": "mkdir", "folder": self.folder, "name": name.stringValue])
            name.stringValue = ""
        }
    }
    @objc private func importFiles() {
        guard !loading, let window = window else { return }
        let panel = NSOpenPanel(); panel.title = "Copy files into the encrypted workspace"
        panel.prompt = "Copy into workspace"; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.resolvesAliases = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self = self, !self.isHidden else { return }
            self.request(["action": "import", "folder": self.folder, "sources": panel.urls.map(\.path)])
        }
    }
}

final class WorkspaceDesktop: DesktopWallpaper {
    var launchBrowser: (() -> Void)?
    var lockWorkspace: (() -> Void)?
    var toggleFullscreen: (() -> Void)?
    var desktopCommand: (([String: Any], @escaping (Result<[String: Any], Error>) -> Void) -> Void)?
    var focusBrowser: (() -> Void)?
    private var icons: [WorkspaceIcon] = []
    private var positions: [String: [CGFloat]] = [:]
    private let files = WorkspaceFiles()
    private let clock = WorkspaceStyle.text("", 12, .medium, color: .secondaryLabelColor)
    private let toast = WorkspaceStyle.text("", 12, color: .secondaryLabelColor)
    private let browserCaption = WorkspaceStyle.text("Install Noct Browser", 11)
    private let runningDot = NSView()
    private var installed = false, running = false
    private var toastWork: DispatchWorkItem?
    private var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let top = NSStackView()
        top.orientation = .horizontal; top.spacing = 12
        let mark = NSImageView(image: WorkspaceStyle.symbol("square.stack.3d.up.fill", size: 16)!)
        mark.contentTintColor = WorkspaceStyle.mint
        top.addArrangedSubview(mark); top.addArrangedSubview(WorkspaceStyle.text("Noct Desktop", 13, .semibold))
        let indicator = WorkspaceStyle.text("●  Unlocked", 11, .medium, color: WorkspaceStyle.mint)
        top.addArrangedSubview(indicator)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); top.addArrangedSubview(spacer)
        top.addArrangedSubview(clock)
        let fullscreen = NSButton(image: WorkspaceStyle.symbol("arrow.up.left.and.arrow.down.right", size: 13)!, target: self, action: #selector(fullscreenAction))
        fullscreen.isBordered = false; fullscreen.setAccessibilityLabel("Toggle full screen")
        top.addArrangedSubview(fullscreen)
        let lock = NSButton(title: "Lock", target: self, action: #selector(lockAction))
        lock.image = WorkspaceStyle.symbol("lock.fill", size: 12); lock.imagePosition = .imageLeading; lock.bezelStyle = .inline
        lock.setAccessibilityLabel("Lock workspace"); top.addArrangedSubview(lock)
        top.translatesAutoresizingMaskIntoConstraints = false; addSubview(top)
        let dock = NSStackView()
        dock.orientation = .horizontal; dock.spacing = 28; dock.edgeInsets = NSEdgeInsets(top: 12, left: 28, bottom: 10, right: 28)
        dock.wantsLayer = true; dock.layer?.backgroundColor = WorkspaceStyle.panel.cgColor
        dock.layer?.cornerRadius = 22; dock.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor; dock.layer?.borderWidth = 1
        for (id, title, symbol, tint) in [("browser", "Noct Browser", "globe.americas.fill", WorkspaceStyle.accent),
                                          ("files", "Files", "folder.fill", WorkspaceStyle.mint),
                                          ("lock", "Lock", "lock.fill", NSColor.white)] {
            let button = NSButton(image: WorkspaceStyle.symbol(symbol, size: 29)!, target: self, action: #selector(dockAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(id); button.isBordered = false
            button.contentTintColor = tint; button.setAccessibilityLabel(id == "lock" ? "Lock workspace from dock" : "\(title) in dock")
            button.toolTip = title; button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            let column = NSStackView(); column.orientation = .vertical; column.spacing = 4
            column.addArrangedSubview(button)
            if id == "browser" { column.addArrangedSubview(browserCaption) }
            else { column.addArrangedSubview(WorkspaceStyle.text(title, 11)) }
            dock.addArrangedSubview(column)
        }
        dock.translatesAutoresizingMaskIntoConstraints = false; addSubview(dock)
        let disclaimer = WorkspaceStyle.text("RESEARCH BUILD  ·  Synthetic data only", 10, .medium, color: NSColor.white.withAlphaComponent(0.42))
        disclaimer.translatesAutoresizingMaskIntoConstraints = false; addSubview(disclaimer)
        toast.translatesAutoresizingMaskIntoConstraints = false; toast.alignment = .center
        toast.maximumNumberOfLines = 2; addSubview(toast)
        runningDot.wantsLayer = true; runningDot.layer?.cornerRadius = 2; runningDot.layer?.backgroundColor = WorkspaceStyle.mint.cgColor
        runningDot.translatesAutoresizingMaskIntoConstraints = false; addSubview(runningDot); runningDot.isHidden = true
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 14), top.heightAnchor.constraint(equalToConstant: 28),
            dock.centerXAnchor.constraint(equalTo: centerXAnchor), dock.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            dock.heightAnchor.constraint(equalToConstant: 84),
            disclaimer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26), disclaimer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            toast.centerXAnchor.constraint(equalTo: centerXAnchor), toast.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -16),
            toast.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -60),
            runningDot.widthAnchor.constraint(equalToConstant: 4), runningDot.heightAnchor.constraint(equalToConstant: 4),
            runningDot.centerXAnchor.constraint(equalTo: browserCaption.centerXAnchor), runningDot.topAnchor.constraint(equalTo: browserCaption.bottomAnchor, constant: 3)
        ])
        for (id, title, symbol, tint) in [("browser", "Noct Browser", "globe.americas.fill", WorkspaceStyle.accent),
                                          ("files", "Files", "folder.fill", WorkspaceStyle.mint),
                                          ("documents", "Documents", "doc.on.doc.fill", WorkspaceStyle.accent),
                                          ("downloads", "Downloads", "arrow.down.circle.fill", WorkspaceStyle.accent)] {
            let icon = WorkspaceIcon(id: id, title: title, image: WorkspaceStyle.symbol(symbol, size: 48), tint: tint)
            icon.open = { [weak self] in self?.open(id) }
            icon.moved = { [weak self, weak icon] in
                guard let self = self, let icon = icon else { return }
                self.positions[id] = [icon.frame.minX, icon.frame.minY]
                self.desktopCommand?(["action": "layout", "positions": self.positions]) { [weak self] result in
                    if case let .failure(error) = result { self?.showMessage(error.localizedDescription) }
                }
            }
            addSubview(icon); icons.append(icon)
        }
        files.command = { [weak self] request, completion in self?.desktopCommand?(request, completion) }
        files.notify = { [weak self] message in self?.showMessage(message) }
        files.translatesAutoresizingMaskIntoConstraints = false; addSubview(files); files.isHidden = true
        NSLayoutConstraint.activate([
            files.centerXAnchor.constraint(equalTo: centerXAnchor), files.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 25),
            files.widthAnchor.constraint(equalTo: widthAnchor, constant: -100), files.heightAnchor.constraint(equalTo: heightAnchor, constant: -240)
        ])
        update(installed: false, running: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        for (index, icon) in icons.enumerated() {
            let position = positions[icon.identifierName] ?? [30 + CGFloat(index / 3) * 120, bounds.height - 192 - CGFloat(index % 3) * 122]
            icon.frame.origin = NSPoint(x: min(max(18, position[0]), bounds.width - 118),
                                       y: min(max(140, position[1]), bounds.height - 180))
        }
    }
    func activate() {
        let epoch = generation
        desktopCommand?(["action": "layout"]) { [weak self] result in
            guard let self = self, self.generation == epoch else { return }
            if case let .success(value) = result { self.positions = value["positions"] as? [String: [CGFloat]] ?? [:]; if let old = self.positions.removeValue(forKey: "chromium"), self.positions["browser"] == nil { self.positions["browser"] = old }; self.needsLayout = true }
        }
    }
    func update(installed: Bool, running: Bool) {
        self.installed = installed; self.running = running
        browserCaption.stringValue = running ? "Noct Browser •" : installed ? "Noct Browser" : "Install Noct Browser"
        runningDot.isHidden = !running
        clock.stringValue = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
    }
    func clear() {
        generation += 1; files.clear(); positions.removeAll(); toastWork?.cancel(); toast.stringValue = ""
        icons.forEach { $0.selected = false }
    }
    func showMessage(_ text: String) {
        toastWork?.cancel(); toast.stringValue = text
        let task = DispatchWorkItem { [weak self] in self?.toast.stringValue = "" }
        toastWork = task; DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: task)
    }
    private func open(_ id: String) {
        if id == "browser" {
            if running { focusBrowser?() } else { launchBrowser?() }
        } else {
            files.isHidden = false
            files.show(folder: id == "documents" ? "Home/Documents" : id == "downloads" ? "Downloads" : "Home/Desktop")
        }
    }
    @objc private func dockAction(_ sender: NSButton) {
        let id = sender.identifier!.rawValue
        if id == "lock" { lockWorkspace?() } else { open(id) }
    }
    @objc private func lockAction() { lockWorkspace?() }
    @objc private func fullscreenAction() { toggleFullscreen?() }
}
