import AppKit
import Darwin

/// Minimal local RFB viewer. The only transport is a Unix socket inside the
/// encrypted workspace. There is no clipboard, file transfer or TCP listener.
final class VMDisplayClient {
    var onFrame: ((CGImage) -> Void)?
    var onFailure: ((String) -> Void)?
    var onResizeSupport: (() -> Void)?
    private var descriptor: Int32 = -1
    private let writeLock = NSLock()
    private let frameLock = NSLock()
    private let sizeLock = NSLock()
    private var resizeSupported = false
    private var screenID: UInt32 = 0, screenFlags: UInt32 = 0
    private var requestedSize = NSSize.zero
    private var pendingFrame: CGImage?
    private var frameDeliveryScheduled = false
    private var pixels = Data()
    private var width = 0, height = 0

    func connect(_ path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do { try self.receive(path) }
            catch { DispatchQueue.main.async { self.onFailure?(error.localizedDescription) } }
        }
    }
    func close() {
        writeLock.lock(); defer { writeLock.unlock() }
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { close() }
    private func failure(_ message: String) -> Error { LauncherError.message(message) }
    private func read(_ fd: Int32, _ count: Int) throws -> Data {
        guard count >= 0 && count <= 64 * 1024 * 1024 else { throw failure("Invalid guest display size.") }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { pointer in
            var offset = 0
            while offset < count {
                let amount = Darwin.read(fd, pointer.baseAddress!.advanced(by: offset), count - offset)
                if amount <= 0 { throw failure("Guest display disconnected.") }
                offset += amount
            }
        }
        return result
    }
    private func send(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard descriptor >= 0 else { throw failure("Guest display is closed.") }
        try data.withUnsafeBytes { pointer in
            var offset = 0
            while offset < data.count {
                let amount = Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), data.count - offset)
                if amount <= 0 { throw failure("Could not send guest input.") }
                offset += amount
            }
        }
    }
    private func u16(_ data: Data, _ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
    private func resize(_ w: Int, _ h: Int) throws {
        guard w > 0 && h > 0 && w <= 4096 && h <= 4096 else { throw failure("Unsupported guest resolution.") }
        sizeLock.lock(); width = w; height = h; sizeLock.unlock()
        pixels = Data(count: w * h * 4)
    }
    func requestSize(_ size: NSSize) {
        let w = Int(size.width), h = Int(size.height)
        guard w >= 800 && h >= 500 && w <= 1920 && h <= 1200 else { return }
        sizeLock.lock()
        guard resizeSupported, requestedSize != size, (width != w || height != h) else { sizeLock.unlock(); return }
        requestedSize = size
        let id = screenID, flags = screenFlags
        sizeLock.unlock()
        let fields: [UInt32] = [id, flags]
        var data = Data([251,0,UInt8(w >> 8),UInt8(w & 255),UInt8(h >> 8),UInt8(h & 255),1,0])
        data.append(contentsOf: [UInt8((fields[0] >> 24) & 255), UInt8((fields[0] >> 16) & 255), UInt8((fields[0] >> 8) & 255), UInt8(fields[0] & 255),
            0,0,0,0,UInt8(w >> 8),UInt8(w & 255),UInt8(h >> 8),UInt8(h & 255),
            UInt8((fields[1] >> 24) & 255),UInt8((fields[1] >> 16) & 255),UInt8((fields[1] >> 8) & 255),UInt8(fields[1] & 255)])
        try? send(data)
    }
    private func updateRequest(_ incremental: Bool) throws {
        try send(Data([3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)]))
    }
    // Keep one pending frame. A busy main thread must not accumulate full
    // framebuffer snapshots or replay stale frames after an input event.
    private func publish(_ image: CGImage) {
        frameLock.lock(); pendingFrame = image
        if frameDeliveryScheduled { frameLock.unlock(); return }
        frameDeliveryScheduled = true; frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            let newest = self.pendingFrame
            self.pendingFrame = nil; self.frameDeliveryScheduled = false
            self.frameLock.unlock()
            if let newest { self.onFrame?(newest) }
        }
    }
    private func receive(_ path: String) throws {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw failure("Guest socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("Cannot create the local guest display socket.") }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        writeLock.lock(); descriptor = fd; writeLock.unlock()
        defer { close() }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw failure("The guest display is not ready. Start FreeBSD first.") }
        let version = try read(fd, 12)
        guard String(data: version, encoding: .ascii)?.hasPrefix("RFB 003.") == true else { throw failure("Invalid guest display handshake.") }
        try send(Data("RFB 003.008\n".utf8))
        let count = Int(try read(fd, 1)[0]); let types = try read(fd, count)
        guard types.contains(1) else { throw failure("Unsupported local display authentication.") }
        try send(Data([1])); guard u32(try read(fd, 4), 0) == 0 else { throw failure("Guest display refused the connection.") }
        try send(Data([1]))
        let header = try read(fd, 24)
        try resize(u16(header, 0), u16(header, 2))
        let nameBytes = Int(u32(header, 20)); guard nameBytes < 65536 else { throw failure("Invalid guest display name.") }
        _ = try read(fd, nameBytes)
        // 32-bit little-endian true color: B G R padding, raw rectangles only.
        try send(Data([0,0,0,0,32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0]))
        try send(Data([2,0,0,3,0,0,0,0,255,255,255,33,255,255,254,204])) // Raw, DesktopSize, ExtendedDesktopSize
        try updateRequest(false)
        while true {
            let kind = try read(fd, 1)[0]
            if kind == 0 {
                let update = try read(fd, 3)
                var changed = false
                for _ in 0..<u16(update, 1) {
                    let rectangle = try read(fd, 12)
                    let x = u16(rectangle, 0), y = u16(rectangle, 2), w = u16(rectangle, 4), h = u16(rectangle, 6)
                    let encoding = Int32(bitPattern: u32(rectangle, 8))
                    if encoding == -223 { try resize(w, h); changed = true; continue }
                    if encoding == -308 {
                        let layout = try read(fd, 4), count = Int(layout[0])
                        guard count > 0 && count <= 16 else { throw failure("Unsupported guest screen layout.") }
                        let screens = try read(fd, count * 16)
                        if x == 1 && y != 0 { continue } // Resize was refused; preserve the old framebuffer.
                        if w != width || h != height { try resize(w, h) }
                        sizeLock.lock(); resizeSupported = count == 1
                        screenID = u32(screens,0); screenFlags = u32(screens,12); sizeLock.unlock()
                        if count == 1 { DispatchQueue.main.async { self.onResizeSupport?() } }
                        continue
                    }
                    guard encoding == 0, x + w <= width, y + h <= height else { throw failure("Unsupported guest display rectangle.") }
                    let incoming = try read(fd, w * h * 4)
                    changed = changed || (w > 0 && h > 0)
                    pixels.withUnsafeMutableBytes { destination in
                        incoming.withUnsafeBytes { source in
                            for row in 0..<h {
                                memcpy(destination.baseAddress!.advanced(by: ((y + row) * width + x) * 4),
                                       source.baseAddress!.advanced(by: row * w * 4), w * 4)
                            }
                        }
                    }
                }
                if changed, let provider = CGDataProvider(data: pixels as CFData),
                   let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                    publish(image)
                }
                try updateRequest(true)
            } else if kind == 2 { continue }
            else if kind == 3 {
                let cut = try read(fd, 7); let amount = Int(u32(cut, 3))
                guard amount <= 1024 * 1024 else { throw failure("Oversized guest clipboard message.") }
                _ = try read(fd, amount) // Deliberately discard; never touch macOS's pasteboard.
            } else { throw failure("Unsupported guest display message.") }
        }
    }
    func pointer(x: Int, y: Int, buttons: UInt8) {
        sizeLock.lock(); let w = width, h = height; sizeLock.unlock()
        guard x >= 0 && y >= 0 && x < w && y < h else { return }
        try? send(Data([5, buttons, UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255)]))
    }
    func key(_ value: UInt32, down: Bool) {
        try? send(Data([4, down ? 1 : 0, 0, 0, UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]))
    }
}

final class VMCanvas: NSView {
    var client: VMDisplayClient?
    private var metalSurface: NoctMetalSurface?
    var image: CGImage? { didSet { metalSurface?.update(image); needsDisplay = true } }
    private var modifiers: NSEvent.ModifierFlags = []
    private var resizeWork: DispatchWorkItem?
    override init(frame: NSRect) {
        super.init(frame: frame)
        if let renderer = try? NoctMetal() {
            let surface = NoctMetalSurface(renderer: renderer)
            surface.frame = bounds; surface.autoresizingMask = [.width,.height]
            addSubview(surface); metalSurface = surface
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); fitGuest()
    }
    func fitGuest() {
        resizeWork?.cancel()
        guard bounds.width >= 800 && bounds.height >= 500 else { return }
        let scale = min(1, 1920 / bounds.width, 1200 / bounds.height)
        let size = NSSize(width: floor(bounds.width * scale / 8) * 8, height: floor(bounds.height * scale / 8) * 8)
        let work = DispatchWorkItem { [weak self] in self?.client?.requestSize(size) }
        resizeWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    var imageRect: NSRect {
        guard let image else { return bounds }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        WorkspaceStyle.ink.setFill(); bounds.fill()
        if metalSurface == nil, let image { NSImage(cgImage: image, size: .zero).draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil) }
    }
    private func pointer(_ event: NSEvent, _ buttons: UInt8) {
        window?.makeFirstResponder(self)
        guard let image else { return }
        let p = convert(event.locationInWindow, from: nil), rect = imageRect
        client?.pointer(x: Int((p.x - rect.minX) * CGFloat(image.width) / rect.width),
                        y: Int((p.y - rect.minY) * CGFloat(image.height) / rect.height), buttons: buttons)
    }
    override func mouseDown(with event: NSEvent) { pointer(event, 1) }
    override func mouseUp(with event: NSEvent) { pointer(event, 0) }
    override func mouseDragged(with event: NSEvent) { pointer(event, 1) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, 4) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, 0) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, 4) }
    override func scrollWheel(with event: NSEvent) { pointer(event, event.scrollingDeltaY > 0 ? 8 : 16); pointer(event, 0) }
    private func keysym(_ event: NSEvent) -> UInt32? {
        let special: [UInt16: UInt32] = [36:0xff0d, 76:0xff0d, 48:0xff09, 51:0xff08, 53:0xff1b,
            123:0xff51, 124:0xff53, 125:0xff54, 126:0xff52, 115:0xff50, 119:0xff57, 116:0xff55, 121:0xff56, 117:0xffff]
        if let value = special[event.keyCode] { return value }
        guard let value = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return nil }
        return value < 256 ? value : 0x01000000 | value
    }
    override func keyDown(with event: NSEvent) { if let value = keysym(event) { client?.key(value, down: true) } }
    override func keyUp(with event: NSEvent) { if let value = keysym(event) { client?.key(value, down: false) } }
    override func flagsChanged(with event: NSEvent) {
        for (flag, key): (NSEvent.ModifierFlags, UInt32) in [(.shift,0xffe1), (.control,0xffe3), (.option,0xffe9), (.command,0xffeb)] {
            if modifiers.contains(flag) != event.modifierFlags.contains(flag) { client?.key(key, down: event.modifierFlags.contains(flag)) }
        }
        modifiers = event.modifierFlags
    }
}

final class VMWorkspaceView: NSView {
    let canvas = VMCanvas()
    let detail = NSTextField(labelWithString: "Private workspace")
    let startButton = NSButton(title: "Open desktop", target: nil, action: nil)
    var start: (() -> Void)?
    var lock: (() -> Void)?
    private var socketPath: String?
    private var client: VMDisplayClient?
    private var generation = UUID()
    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "Noct Desktop")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        detail.font = .systemFont(ofSize: 11); detail.textColor = WorkspaceStyle.muted
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        let lockButton = NSButton(title: "Lock workspace", target: self, action: #selector(lockAction)); lockButton.bezelStyle = .rounded
        startButton.target = self; startButton.action = #selector(startAction); startButton.bezelStyle = .rounded
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [labels, spacer, startButton, lockButton]); header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false; addSubview(header)
        canvas.translatesAutoresizingMaskIntoConstraints = false; addSubview(canvas)
        canvas.setAccessibilityElement(true); canvas.setAccessibilityRole(.image); canvas.setAccessibilityLabel("FreeBSD workspace display")
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18), header.topAnchor.constraint(equalTo: topAnchor, constant: 10), header.heightAnchor.constraint(equalToConstant: 48),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor), canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10), canvas.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func startAction() { start?() }
    @objc private func lockAction() { lock?() }
    func clear() {
        generation = UUID(); client?.close(); client = nil; canvas.client = nil; canvas.image = nil; socketPath = nil
    }
    func update(running: Bool, installed: Bool, socket: String?) {
        startButton.title = installed ? "Open desktop" : "Set up desktop"
        startButton.isHidden = running; startButton.isEnabled = !running
        guard running, let socket else {
            clear(); detail.stringValue = installed ? "Ready to open · workspace unlocked" : "Prepare your encrypted workspace"
            return
        }
        guard socketPath != socket else { return }
        clear(); socketPath = socket; let epoch = generation
        let connection = VMDisplayClient(); client = connection; canvas.client = connection
        detail.stringValue = "Opening your desktop…"
        connection.onFrame = { [weak self] image in
            guard let self, self.generation == epoch else { return }
            self.canvas.image = image
            if self.detail.stringValue != "Private workspace · unlocked" {
                self.detail.stringValue = "Private workspace · unlocked"
            }
        }
        connection.onFailure = { [weak self] message in
            guard let self, self.generation == epoch else { return }
            self.detail.stringValue = message; self.socketPath = nil
        }
        connection.onResizeSupport = { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.canvas.fitGuest()
        }
        connection.connect(socket)
    }
}
