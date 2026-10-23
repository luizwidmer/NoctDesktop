// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import Darwin

struct WorkspaceFailure: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
struct CommandResult {
    let output: Data
    let error: Data
    let status: Int32
    var text: String { String(decoding: output, as: UTF8.self) }
    var diagnostic: String { String(decoding: output + error, as: UTF8.self) }
}
enum NativeCommand {
    // Anonymous pipes only: credentials and captured guest output never use
    // NSTemporaryDirectory or a host-side staging file.
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    environment: [String: String]? = nil, directory: URL? = nil,
                    timeout: TimeInterval = 90, check: Bool = true,
                    periodic: (() throws -> Void)? = nil) throws -> CommandResult {
        let process = Process(), out = Pipe(), err = Pipe(), incoming = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = directory
        process.standardOutput = out; process.standardError = err; process.standardInput = incoming
        try process.run()
        let group = DispatchGroup(), mutex = NSLock()
        var stdout = Data(), stderr = Data()
        for (pipe, isError) in [(out, false), (err, true)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    mutex.lock()
                    // Bound diagnostics even when a guest command is noisy.
                    if isError { stderr.append(chunk); if stderr.count > 4_194_304 { stderr.removeFirst(stderr.count - 4_194_304) } }
                    else { stdout.append(chunk); if stdout.count > 8_388_608 { stdout.removeFirst(stdout.count - 8_388_608) } }
                    mutex.unlock()
                }
                group.leave()
            }
        }
        DispatchQueue.global(qos: .utility).async {
            if let input { try? incoming.fileHandleForWriting.write(contentsOf: input) }
            try? incoming.fileHandleForWriting.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var monitorError: Error?, nextCheck = ProcessInfo.processInfo.systemUptime
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            if let periodic, ProcessInfo.processInfo.systemUptime >= nextCheck {
                do { try periodic() } catch { monitorError = error; break }
                nextCheck = ProcessInfo.processInfo.systemUptime + 1
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let timedOut = process.isRunning && monitorError == nil
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit(); group.wait()
        if let monitorError { throw monitorError }
        if timedOut { throw WorkspaceFailure("\(URL(fileURLWithPath: executable).lastPathComponent) timed out. Workspace state must be checked before retrying.") }
        let result = CommandResult(output: stdout, error: stderr, status: process.terminationStatus)
        if check && result.status != 0 {
            throw WorkspaceFailure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(result.status)): " + String(result.diagnostic.suffix(2500)))
        }
        return result
    }
}

struct RuntimeResources {
    static func sourceRoot() -> URL {
        if let value = ProcessInfo.processInfo.environment["NOCT_DEVELOPMENT_ROOT"] ?? Bundle.main.object(forInfoDictionaryKey: "PrototypeRoot") as? String { return URL(fileURLWithPath: value) }
        var candidate = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("NoctDesktop.xcodeproj/project.pbxproj").path) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return Bundle.main.bundleURL.deletingLastPathComponent()
    }
    let root: URL
    let guest: URL
    let gpuRuntime: URL
    let gpuBroker: URL
    let sandbox: URL
    init(root: URL) {
        self.root = root
        let resources = Bundle.main.resourceURL ?? root
        let bundledGuest = resources.appendingPathComponent("Guest")
        guest = FileManager.default.fileExists(atPath: bundledGuest.path) ? bundledGuest : root.deletingLastPathComponent().appendingPathComponent("NoctBSD/overlay/opt/noct")
        let bundledGPU = resources.appendingPathComponent("GPU")
        gpuRuntime = FileManager.default.fileExists(atPath: bundledGPU.appendingPathComponent("manifest.json").path) ? bundledGPU : root.appendingPathComponent("build/virgl-host")
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NoctGPUBroker")
        gpuBroker = FileManager.default.isExecutableFile(atPath: helper.path) ? helper : root.appendingPathComponent("build/NoctGPUBroker")
        let profile = resources.appendingPathComponent("gpu-helper.sb")
        sandbox = FileManager.default.fileExists(atPath: profile.path) ? profile : root.appendingPathComponent("tools/gpu-helper.sb")
    }
}

final class NativeWorkspace {
    static let reserve: UInt64 = 15 * 1_073_741_824
    let folder: URL
    let resources: RuntimeResources
    private let fm = FileManager.default
    var metadata: URL { folder.appendingPathComponent("workspace.json") }
    var image: URL { folder.appendingPathComponent("Workspace.sparsebundle") }
    var mount: URL {
        if let config = try? configuration(), let id = config["short_mount_id"] as? String,
           id.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil {
            return fm.homeDirectoryForCurrentUser.appendingPathComponent(".ew-mounts/\(id)")
        }
        return folder.appendingPathComponent("Mounted")
    }
    var vm: URL { mount.appendingPathComponent("VM/FreeBSD") }
    init(folder: URL, root: URL) {
        self.folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        resources = RuntimeResources(root: root)
    }
    static func readJSON(_ path: URL) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else { throw WorkspaceFailure("Invalid workspace metadata.") }
        return result
    }
    static func writeJSON(_ path: URL, _ value: [String: Any]) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = path.deletingLastPathComponent().appendingPathComponent(".\(path.lastPathComponent).\(UUID().uuidString).new")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        guard FileManager.default.createFile(atPath: stage.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw WorkspaceFailure("Cannot stage workspace metadata.") }
        defer { try? FileManager.default.removeItem(at: stage) }
        let fd = Darwin.open(stage.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceFailure("Cannot open workspace metadata.") }
        let synced = fsync(fd); close(fd)
        guard synced == 0, rename(stage.path, path.path) == 0 else { throw WorkspaceFailure("Cannot commit workspace metadata.") }
    }
    func configuration() throws -> [String: Any] { try Self.readJSON(metadata) }
    @discardableResult func diskGuard() throws -> UInt64 {
        let attrs = try fm.attributesOfFileSystem(forPath: folder.path)
        let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard free >= Self.reserve else { throw WorkspaceFailure(String(format: "Disk reserve reached (%.1f GiB free). Keep at least 15 GiB free.", Double(free) / 1_073_741_824)) }
        return free
    }
    func perform(_ action: String, password: String? = nil) throws -> [String: Any] {
        // A read-only status poll must not contend with the GUI's mutation lock.
        if action == "status" { return try status() }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(folder.appendingPathComponent(".operation.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WorkspaceFailure("Cannot open the workspace operation lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceFailure("Another workspace operation is running.") }
        defer { flock(fd, LOCK_UN) }
        switch action {
        case "status": return try status()
        case "create": try create(password: password ?? ""); return try status()
        case "unlock": try unlock(password: password ?? ""); return try status()
        case "lock": return try lock()
        case "launch-vm": return try launchVM()
        case "stop-vm": return try stopVM()
        case "install-vm": return try installVM()
        case "setup-vm": return try setupVM()
        case "enable-browser-gpu": return try enableBrowserGPU()
        case "disable-browser-gpu": return try disableBrowserGPU()
        default: throw WorkspaceFailure("Unsupported native workspace operation: \(action)")
        }
    }
    private func attached() throws -> [String: Any]? {
        let data = try NativeCommand.run("/usr/bin/hdiutil", ["info", "-plist"]).output
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return (info?["images"] as? [[String: Any]] ?? []).first { entry in
            guard let path = entry["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath() == image
        }
    }
    func requireMounted() throws {
        guard let info = try attached() else { throw WorkspaceFailure("The workspace is locked. Unlock it first.") }
        let matching = (info["system-entities"] as? [[String: Any]] ?? []).filter { ($0["mount-point"] as? String) == mount.path }
        var m = stat(), p = stat()
        guard matching.count == 1, lstat(mount.path, &m) == 0, stat(mount.deletingLastPathComponent().path, &p) == 0,
              m.st_mode & S_IFMT == S_IFDIR, m.st_dev != p.st_dev,
              try Self.readJSON(mount.appendingPathComponent(".workspace-identity.json"))["id"] as? String == configuration()["id"] as? String else {
            throw WorkspaceFailure("The attached workspace has an unexpected mount or filesystem identity.")
        }
    }
    func safe(_ relative: String) throws -> URL {
        try requireMounted()
        let path = vm.appendingPathComponent(relative).standardizedFileURL
        guard path.path.hasPrefix(mount.path + "/") else { throw WorkspaceFailure("A VM path leaves the encrypted workspace.") }
        // resolvingSymlinksInPath can leave a link unresolved when the final
        // child does not exist. Inspect each existing component explicitly.
        var cursor = mount
        for component in path.pathComponents.dropFirst(mount.pathComponents.count) {
            cursor.appendPathComponent(component)
            var entry = stat()
            if lstat(cursor.path, &entry) == 0 {
                guard entry.st_mode & S_IFMT != S_IFLNK else { throw WorkspaceFailure("A symlink appears in private VM storage.") }
            } else if errno != ENOENT { throw WorkspaceFailure("Cannot validate a private VM path.") }
        }
        return path
    }
    private func hdiPassword(_ value: String) throws -> Data {
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\0") else { throw WorkspaceFailure("Use a nonempty password without a newline or NUL.") }
        return Data(value.utf8) + Data([0])
    }
    func create(password: String, size: String = "8g", diskMiB: Int = 7680) throws {
        try diskGuard()
        guard password.utf8.count >= 12 else { throw WorkspaceFailure("Use at least 12 characters for a new workspace password.") }
        guard (size == "8g" && diskMiB == 7680) || (size == "12g" && diskMiB == 9216) else { throw WorkspaceFailure("Unsupported workspace capacity pair.") }
        guard !fm.fileExists(atPath: image.path), !fm.fileExists(atPath: metadata.path) else { throw WorkspaceFailure("This workspace already exists; it will not be overwritten.") }
        _ = try NativeCommand.run("/usr/bin/hdiutil", ["create", "-size", size, "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", "Noct Desktop Workspace", "-encryption", "AES-256", "-stdinpass", image.path], input: hdiPassword(password), timeout: 180)
        try Self.writeJSON(metadata, ["format": 1, "id": UUID().uuidString.lowercased(), "short_mount_id": String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)), "created_at": Date().timeIntervalSince1970, "encryption": "AES-256 disk image", "runtime": "freebsd-vm", "release": "15.1-RELEASE", "memory_mib": 1536, "vcpus": 2, "noct_gpu": false, "disk_mib": diskMiB])
        try unlock(password: password, initializing: true); _ = try lock()
    }
    func unlock(password: String, initializing: Bool = false) throws {
        let config = try configuration()
        if try attached() != nil {
            guard !initializing else { throw WorkspaceFailure("An image unexpectedly attached during creation.") }
            try requireMounted(); return
        }
        let parent = mount.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath() == parent else { throw WorkspaceFailure("The mount parent must not be a symlink.") }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var s = stat(); guard lstat(parent.path, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFDIR else { throw WorkspaceFailure("The mount parent must belong to the current user.") }
        chmod(parent.path, 0o700)
        if !fm.fileExists(atPath: mount.path) { try fm.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        var mountInfo = stat()
        guard lstat(mount.path, &mountInfo) == 0, mountInfo.st_mode & S_IFMT == S_IFDIR, mountInfo.st_uid == getuid(), mount.resolvingSymlinksInPath() == mount, try fm.contentsOfDirectory(atPath: mount.path).isEmpty else { throw WorkspaceFailure("The mount location must be an empty directory owned by you, without symlinks.") }
        chmod(mount.path, 0o700)
        _ = try NativeCommand.run("/usr/bin/hdiutil", ["attach", image.path, "-stdinpass", "-nobrowse", "-owners", "on", "-mountpoint", mount.path, "-plist"], input: hdiPassword(password))
        if initializing { chmod(mount.path, 0o700); try Self.writeJSON(mount.appendingPathComponent(".workspace-identity.json"), ["id": config["id"]!]) }
        try requireMounted()
        for name in ["Run", "Logs", "Temp", "Home/Library/Preferences"] { try fm.createDirectory(at: mount.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        fm.createFile(atPath: mount.appendingPathComponent(".metadata_never_index").path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }
    private func processTable() throws -> [(Int32, String)] {
        try NativeCommand.run("/bin/ps", ["-axo", "pid=,command="]).text.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }; return (pid, String(parts[1]))
        }
    }
    func vmProcesses() throws -> [Int32] {
        let names = ["/opt/homebrew/bin/qemu-system-aarch64", resources.gpuRuntime.appendingPathComponent("bin/qemu-system-aarch64").path]
        let marker = vm.appendingPathComponent("Run/qmp.sock").path
        return try processTable().filter { row in names.contains { row.1.hasPrefix($0 + " ") } && row.1.contains(marker) }.map(\.0)
    }
    private func gpuProcesses() throws -> [Int32] {
        let names = [resources.gpuBroker.path, resources.root.appendingPathComponent("build/NoctGPUBroker").path]
        return try processTable().filter { row in names.contains { row.1.hasPrefix($0 + " ") } && row.1.contains(vm.appendingPathComponent("Run/gpu.sock").path) }.map(\.0)
    }
    private func stopGPU() throws {
        for pid in try gpuProcesses() { Darwin.kill(pid, SIGTERM) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(try gpuProcesses()).isEmpty && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard try gpuProcesses().isEmpty else { throw WorkspaceFailure("Lock incomplete: the workspace GPU helper did not exit.") }
    }
    func qmp(_ command: String) throws -> Any {
        let path = try safe("Run/qmp.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw WorkspaceFailure("Cannot create VM control socket.") }; defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw WorkspaceFailure("VM control socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); bytes.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw WorkspaceFailure("Cannot connect to VM control socket.") }
        func readReply() throws -> [String: Any] {
            var line = Data(); var byte: UInt8 = 0
            while line.count < 65_536 { guard Darwin.read(fd, &byte, 1) == 1 else { throw WorkspaceFailure("VM control socket closed or timed out.") }; if byte == 10 { break }; line.append(byte) }
            guard line.count < 65_536, let j = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw WorkspaceFailure("Invalid VM control reply.") }; return j
        }
        _ = try readReply()
        func request(_ name: String) throws -> Any {
            let data = try JSONSerialization.data(withJSONObject: ["execute": name]) + Data([10])
            try data.withUnsafeBytes { bytes in var offset = 0; while offset < data.count { let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count-offset); guard n > 0 else { throw WorkspaceFailure("VM control write failed.") }; offset += n } }
            for _ in 0..<64 { let reply = try readReply(); if let error = reply["error"] { throw WorkspaceFailure("VM control failed: \(error)") }; if let value = reply["return"] { return value } }
            throw WorkspaceFailure("Too many VM control events.")
        }
        _ = try request("qmp_capabilities"); return try request(command)
    }
    func status() throws -> [String: Any] {
        if !fm.fileExists(atPath: metadata.path) { return ["state": "not_created", "mounted": false, "vm_running": false, "vm_pids": []] }
        let mounted = try attached() != nil
        let pids = try vmProcesses()
        var result: [String: Any] = ["state": mounted ? "unlocked" : "locked", "mounted": mounted, "folder": folder.path, "mount": mount.path, "image": image.path, "runtime": "freebsd-vm", "controller": "swift", "vm_pids": pids.map(Int.init), "vm_running": !pids.isEmpty]
        if mounted {
            try requireMounted()
            result["vm_installed"] = fm.fileExists(atPath: try safe("installation.json").path)
            result["vm_configured"] = fm.fileExists(atPath: try safe("desktop.json").path)
            result["graphics"] = try configuration()["graphics"] ?? "software"
            result["memory_mib"] = try configuration()["memory_mib"] ?? 1536
            result["display_socket"] = vm.appendingPathComponent("Run/display.sock").path
            result["gpu_pids"] = try gpuProcesses().map(Int.init)
            if !pids.isEmpty { result["qmp"] = try qmp("query-status") }
        }
        return result
    }
    func stopVM(timeout: TimeInterval = 60) throws -> [String: Any] {
        if try vmProcesses().isEmpty { try stopGPU(); return ["shutdown_seconds": 0, "already_stopped": true] }
        try requireMounted(); let start = ProcessInfo.processInfo.systemUptime
        _ = try qmp("system_powerdown")
        while !(try vmProcesses()).isEmpty && ProcessInfo.processInfo.systemUptime-start < timeout { Thread.sleep(forTimeInterval: 0.2) }
        guard try vmProcesses().isEmpty else { throw WorkspaceFailure("Lock incomplete: FreeBSD did not shut down. The vault remains mounted.") }
        try stopGPU()
        return ["shutdown_seconds": ProcessInfo.processInfo.systemUptime-start, "shutdown_method": "ACPI system_powerdown"]
    }
    func lock() throws -> [String: Any] {
        if try !vmProcesses().isEmpty && attached() == nil { throw WorkspaceFailure("VM state is inconsistent: a process is running without its mounted vault.") }
        let stopped = try stopVM()
        if try attached() != nil {
            try requireMounted()
            _ = try NativeCommand.run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 45)
            guard try attached() == nil else { throw WorkspaceFailure("Detach did not complete; the workspace remains unlocked.") }
        }
        var result = try status(); result.merge(stopped) { _, new in new }; return result
    }
    func runtimeEnvironment() throws -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8", "HOME": try safe("Home").path, "CFFIXED_USER_HOME": try safe("Home").path, "TMPDIR": try safe("Temp").path + "/", "XDG_CACHE_HOME": try safe("Cache").path, "XDG_CONFIG_HOME": try safe("Home").path, "XDG_RUNTIME_DIR": try safe("Run").path]
    }
    private func spawn(_ executable: String, _ arguments: [String], log: URL) throws -> Process {
        // The app sets RLIMIT_CORE=0 before any helper is spawned.
        let fd = Darwin.open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WorkspaceFailure("Cannot open private helper log.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.environment = try runtimeEnvironment(); p.currentDirectoryURL = vm
        p.standardInput = FileHandle.nullDevice; p.standardOutput = handle; p.standardError = handle
        p.terminationHandler = { _ in }
        try p.run(); return p
    }
    private func verifyGPU() throws {
        let manifest = try Self.readJSON(resources.gpuRuntime.appendingPathComponent("manifest.json"))
        let required: Set<String> = ["bin/qemu-system-aarch64", "lib/libEGL.dylib", "lib/libGLESv2.dylib", "lib/libGLESv1_CM.dylib", "lib/libepoxy.0.dylib", "lib/libvirglrenderer.1.dylib"]
        guard manifest["prepared_by"] as? String == "noct.browser-gpu@1", let binaries = manifest["binaries"] as? [String: String], required.isSubset(of: Set(binaries.keys)) else { throw WorkspaceFailure("Incomplete browser GPU runtime manifest.") }
        for (relative, expected) in binaries {
            let path = resources.gpuRuntime.appendingPathComponent(relative).standardizedFileURL
            guard path.resolvingSymlinksInPath().path.hasPrefix(resources.gpuRuntime.resolvingSymlinksInPath().path + "/"), try Self.sha256(path) == expected else { throw WorkspaceFailure("GPU runtime checksum mismatch.") }
        }
    }
    static func sha256(_ path: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: path); defer { try? file.close() }; var hash = SHA256()
        while let part = try file.read(upToCount: 1_048_576), !part.isEmpty { hash.update(data: part) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func launchGPU() throws {
        try stopGPU(); let socket = try safe("Run/gpu.sock"); if fm.fileExists(atPath: socket.path) { try fm.removeItem(at: socket) }
        let p = try spawn("/usr/bin/sandbox-exec", ["-D", "VAULT="+vm.path, "-f", resources.sandbox.path, resources.gpuBroker.path, "--socket", socket.path], log: safe("Logs/gpu.log"))
        let deadline = ProcessInfo.processInfo.systemUptime+10
        while p.isRunning && ProcessInfo.processInfo.systemUptime < deadline { if fm.fileExists(atPath: socket.path) { return }; Thread.sleep(forTimeInterval: 0.05) }
        try stopGPU(); throw WorkspaceFailure("The experimental Metal helper did not become ready.")
    }
    func launchVM() throws -> [String: Any] {
        try diskGuard(); guard fm.fileExists(atPath: try safe("installation.json").path) else { throw WorkspaceFailure("Set up FreeBSD first.") }
        if try !vmProcesses().isEmpty { return try status() }
        for name in ["Run/qmp.sock", "Run/display.sock", "Run/qemu.pid"] { let path = try safe(name); if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) } }
        let config = try configuration(); let graphics = config["graphics"] as? String ?? "software"
        guard ["software", "virgl-metal"].contains(graphics) else { throw WorkspaceFailure("Unknown VM graphics backend.") }
        let virgl = graphics == "virgl-metal"; if virgl { try verifyGPU() }
        let reservation = socket(AF_INET, SOCK_STREAM, 0); guard reservation >= 0 else { throw WorkspaceFailure("Cannot reserve private management port.") }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(reservation, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(reservation, $0, &length) } }
        close(reservation); guard bound == 0, named == 0 else { throw WorkspaceFailure("Cannot allocate private management port.") }
        let port = UInt16(bigEndian: address.sin_port)
        let hostKey = try String(contentsOf: safe("Keys/ssh_host_ed25519_key.pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("[127.0.0.1]:\(port) \(hostKey)\n".utf8).write(to: safe("Keys/known_hosts"))
        let firmware = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
        var arguments = ["-L", "/opt/homebrew/share/qemu", "-name", "Noct Desktop FreeBSD", "-machine", "virt", "-accel", "hvf", "-cpu", "host", "-smp", "2", "-m", "\(config["memory_mib"] as? Int ?? 1536)", "-nodefaults", "-no-user-config", "-no-reboot",
            "-drive", "if=pflash,format=raw,unit=0,file=\(firmware),readonly=on", "-drive", "if=pflash,format=raw,unit=1,file=\(try safe("uefi-vars.fd").path)",
            "-drive", "if=none,id=system,format=qcow2,file=\(try safe("system.qcow2").path),cache=writethrough,discard=unmap,detect-zeroes=unmap", "-device", "virtio-blk-pci,drive=system",
            "-drive", "if=none,id=seed,format=raw,file=\(try safe("seed.iso").path),readonly=on", "-device", "virtio-blk-pci,drive=seed",
            "-netdev", "user,id=network,hostfwd=tcp:127.0.0.1:\(port)-:22,hostfwd=unix:\(try safe("Run/display.sock").path)-:5900", "-device", "virtio-net-pci,netdev=network", "-device", "virtio-rng-pci", "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
            "-display", virgl ? "egl-headless,gl=es" : "none", "-serial", "file:\(try safe("Logs/serial.log").path)", "-qmp", "unix:\(try safe("Run/qmp.sock").path),server=on,wait=off", "-pidfile", try safe("Run/qemu.pid").path]
        if !virgl { arguments += ["-device", "ramfb"] }
        if config["noct_gpu"] as? Bool == true { try launchGPU(); arguments += ["-device", "virtio-serial-pci", "-chardev", "socket,id=noctgpu,path=\(try safe("Run/gpu.sock").path),reconnect-ms=1000", "-device", "virtserialport,chardev=noctgpu,nr=1,name=org.noctdesktop.gpu"] }
        let executable: String
        if virgl { arguments += ["-device", "virtio-gpu-gl-pci,xres=640,yres=480"]; executable = "/usr/bin/sandbox-exec"; arguments = ["-D", "VAULT="+vm.path, "-f", resources.sandbox.path, "/usr/bin/env", "DYLD_LIBRARY_PATH="+resources.gpuRuntime.appendingPathComponent("lib").path, resources.gpuRuntime.appendingPathComponent("bin/qemu-system-aarch64").path] + arguments }
        else { executable = "/opt/homebrew/bin/qemu-system-aarch64" }
        let p = try spawn(executable, arguments, log: safe("Logs/qemu.log"))
        try Self.writeJSON(safe("Run/process.json"), ["pid": p.processIdentifier, "ssh_port": port, "started_at": Date().timeIntervalSince1970, "argv": [executable]+arguments, "accelerator": "hvf", "graphics": graphics])
        let deadline = ProcessInfo.processInfo.systemUptime+15
        while p.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            if fm.fileExists(atPath: try safe("Run/qmp.sock").path), let result = try? status() { return result }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw WorkspaceFailure("QEMU did not become ready; the vault remains mounted. Check its private log.")
    }
    func ssh(_ command: String, input: Data? = nil, timeout: TimeInterval = 60, check: Bool = true, monitorDisk: Bool = false) throws -> CommandResult {
        let info = try Self.readJSON(safe("Run/process.json")); guard let port = info["ssh_port"] as? Int else { throw WorkspaceFailure("Missing management port.") }
        let args = ["-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10", "-o", "IdentityAgent=none", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile="+(try safe("Keys/known_hosts").path), "-o", "GlobalKnownHostsFile=/dev/null", "-i", try safe("Keys/management_ed25519").path, "-p", "\(port)", "root@127.0.0.1", command]
        let result = try NativeCommand.run("/usr/bin/ssh", args, input: input, timeout: timeout, check: false, periodic: monitorDisk ? { _ = try self.diskGuard() } : nil)
        if check && result.status != 0 { throw WorkspaceFailure("Guest command failed: " + String(result.diagnostic.suffix(2500))) }
        return result
    }
    func waitReady(timeout: TimeInterval = 600, initial: Bool = false) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try diskGuard()
            if try vmProcesses().isEmpty { if initial { _ = try launchVM() } else { throw WorkspaceFailure("FreeBSD stopped before becoming ready.") } }
            if let result = try? ssh("test -f /root/noct-bootstrap-ready", timeout: 6, check: false), result.status == 0 { return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw WorkspaceFailure("FreeBSD did not become ready before the deadline.")
    }
    func syncGuest() throws {
        // tar travels through an anonymous pipe; the guest tree is public code.
        let archive = try NativeCommand.run("/usr/bin/tar", ["--no-xattrs", "--no-mac-metadata", "-cf", "-", "--exclude=bin", "--exclude=__pycache__", "--exclude=*.py", "-C", resources.guest.path, "."]).output
        _ = try ssh("mkdir -p /opt/noct; tar -xf - -C /opt/noct && chmod 755 /opt/noct/*.sh", input: archive)
    }
    func setupVM() throws -> [String: Any] {
        do {
            _ = try installVM(); _ = try launchVM(); try waitReady(initial: true); try syncGuest()
            _ = try ssh("/bin/sh /opt/noct/provision.sh; s=$?; tail -30 /var/log/noct-provision.log; exit $s", timeout: 1800, monitorDisk: true)
            try Self.writeJSON(safe("desktop.json"), ["runtime": 2, "desktop": "Noct C++", "browser": "WebKitGTK", "installed_at": Date().timeIntervalSince1970])
            _ = try ssh("/usr/sbin/daemon -f -o /var/log/noct-desktop.log /opt/noct/start-desktop.sh")
            return try status()
        } catch {
            // ACPI shutdown also stops guest package writes when setup reaches
            // the disk reserve. A shutdown failure keeps the vault mounted.
            _ = try? stopVM()
            throw error
        }
    }
    func enableBrowserGPU() throws -> [String: Any] {
        try requireMounted(); try verifyGPU()
        guard fm.fileExists(atPath: try safe("desktop.json").path) else { throw WorkspaceFailure("Set up the desktop first.") }
        do {
            _ = try launchVM(); try waitReady(); try syncGuest()
            _ = try ssh("/bin/sh /opt/noct/build-native.sh && /bin/sh /opt/noct/install-browser-gpu.sh; s=$?; tail -12 /var/log/noct-browser-gpu-install.log; exit $s", timeout: 1200, monitorDisk: true)
            _ = try stopVM()
            var config = try configuration(); config["graphics"] = "virgl-metal"; try Self.writeJSON(metadata, config)
            _ = try launchVM(); try waitReady()
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while ProcessInfo.processInfo.systemUptime < deadline {
                if try ssh("test -c /dev/dri/renderD128 && pgrep -x Xvnc >/dev/null", check: false).status == 0 { return try status() }
                Thread.sleep(forTimeInterval: 0.5)
            }
            throw WorkspaceFailure("The GPU desktop did not start. Check the private guest log.")
        } catch { _ = try? stopVM(); throw error }
    }
    func disableBrowserGPU() throws -> [String: Any] {
        _ = try launchVM(); try waitReady()
        _ = try ssh("rm -f /etc/noct/gpu.json"); _ = try stopVM()
        var config = try configuration(); config["graphics"] = "software"; try Self.writeJSON(metadata, config)
        _ = try launchVM(); try waitReady(); return try status()
    }
}
