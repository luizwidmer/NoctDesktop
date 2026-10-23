// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import Darwin

// Stream the pinned image into xz through a pipe. Both the expanded image and
// decoder output are vault-local; URLSession has no disk cache or cookie store.
private final class ImageStream: NSObject, URLSessionDataDelegate {
    let pipe: FileHandle
    let guardDisk: () throws -> Void
    let completed = DispatchSemaphore(value: 0)
    var imageDigest = SHA256()
    var received = 0
    var failure: Error?
    init(pipe: FileHandle, guardDisk: @escaping () throws -> Void) { self.pipe = pipe; self.guardDisk = guardDisk }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            failure = WorkspaceFailure("The FreeBSD image server returned an unexpected response."); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try guardDisk(); received += data.count
            guard received <= 1_073_741_824 else { throw WorkspaceFailure("Compressed image exceeds the download budget.") }
            imageDigest.update(data: data); try pipe.write(contentsOf: data)
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil { failure = error }
        try? pipe.close(); completed.signal()
    }
}

extension NativeWorkspace {
    static let imageURL = "https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/aarch64/Latest/FreeBSD-15.1-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz"
    static let imageSHA = "9722aea499610802de9a14bb645707fc4f6df49ff765cd9ce372b783c4693963"
    func installVM() throws -> [String: Any] {
        try diskGuard()
        let fm = FileManager.default
        for name in ["/opt/homebrew/bin/qemu-system-aarch64", "/opt/homebrew/bin/qemu-img", "/opt/homebrew/bin/xz", "/opt/homebrew/share/qemu/edk2-aarch64-code.fd", "/opt/homebrew/share/qemu/edk2-arm-vars.fd"] {
            guard fm.fileExists(atPath: name) else { throw WorkspaceFailure("Install the development runtime dependency: \(name)") }
        }
        guard try vmProcesses().isEmpty else { throw WorkspaceFailure("Stop the VM before installation.") }
        for name in ["", "Run", "Home/Library/Preferences", "Cache", "Temp", "Logs", "Seed", "Keys"] {
            try fm.createDirectory(at: safe(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let disk = try safe("system.qcow2"), installation = try safe("installation.json")
        if fm.fileExists(atPath: disk.path) {
            guard fm.fileExists(atPath: installation.path) else { throw WorkspaceFailure("An incomplete VM installation is present; it was preserved.") }
            return try Self.readJSON(installation)
        }
        let stage = try safe("system.qcow2.part")
        let fd = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WorkspaceFailure("An unfinished image download is present; it was preserved.") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? fm.removeItem(at: stage) }
        let incoming = Pipe(), errors = Pipe(), decoder = Process()
        decoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/xz")
        decoder.arguments = ["--memlimit-decompress=256MiB", "--decompress", "--stdout"]
        decoder.currentDirectoryURL = vm; decoder.environment = try runtimeEnvironment()
        decoder.standardInput = incoming; decoder.standardOutput = output; decoder.standardError = errors
        try decoder.run()
        let stream = ImageStream(pipe: incoming.fileHandleForWriting, guardDisk: { [self] in
            try diskGuard()
            let size = (try fm.attributesOfItem(atPath: stage.path)[.size] as? NSNumber)?.uint64Value ?? 0
            guard size <= 4 * 1_073_741_824 else { throw WorkspaceFailure("Expanded guest image exceeds the prototype budget.") }
        })
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config, delegate: stream, delegateQueue: nil)
        let task = session.dataTask(with: URL(string: Self.imageURL)!)
        task.resume()
        defer { session.invalidateAndCancel() }
        while stream.completed.wait(timeout: .now() + 0.2) == .timedOut {
            if !decoder.isRunning { task.cancel() }
        }
        decoder.waitUntilExit()
        try output.synchronize(); try output.close()
        if let error = stream.failure { throw error }
        let checksum = stream.imageDigest.finalize().map { String(format: "%02x", $0) }.joined()
        guard decoder.terminationStatus == 0, checksum == Self.imageSHA else { throw WorkspaceFailure("The FreeBSD image failed its pinned SHA-256 / XZ integrity check.") }
        let infoData = try NativeCommand.run("/opt/homebrew/bin/qemu-img", ["info", "--output=json", stage.path]).output
        guard let info = try JSONSerialization.jsonObject(with: infoData) as? [String: Any], info["format"] as? String == "qcow2", info["backing-filename"] == nil else { throw WorkspaceFailure("Unexpected guest image format or external backing file.") }
        _ = try NativeCommand.run("/opt/homebrew/bin/qemu-img", ["check", stage.path])
        let diskMiB = try configuration()["disk_mib"] as? Int ?? 7680
        guard [7680, 9216].contains(diskMiB) else { throw WorkspaceFailure("Unsupported guest disk capacity.") }
        _ = try NativeCommand.run("/opt/homebrew/bin/qemu-img", ["resize", stage.path, "\(diskMiB)M"])
        let expanded = (try fm.attributesOfItem(atPath: stage.path)[.size] as? NSNumber)?.uint64Value ?? 0
        try fm.moveItem(at: stage, to: disk)
        try fm.copyItem(at: URL(fileURLWithPath: "/opt/homebrew/share/qemu/edk2-arm-vars.fd"), to: safe("uefi-vars.fd"))
        chmod(try safe("uefi-vars.fd").path, 0o600)
        try makeSeed()
        let result: [String: Any] = ["release": "15.1-RELEASE", "source": Self.imageURL, "compressed_sha256": checksum, "compressed_bytes": stream.received, "extracted_bytes": expanded, "source_virtual_bytes": info["virtual-size"] ?? 0, "virtual_bytes": diskMiB*1_048_576, "installed_at": Date().timeIntervalSince1970, "firmware_sha256": try Self.sha256(URL(fileURLWithPath: "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"))]
        try Self.writeJSON(installation, result); return result
    }
    private func makeSeed() throws {
        let fm = FileManager.default
        let key = try safe("Keys/management_ed25519"), host = try safe("Keys/ssh_host_ed25519_key")
        for path in [key, host] where !fm.fileExists(atPath: path.path) { _ = try NativeCommand.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path.path]) }
        let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let privateHost = try Data(contentsOf: host).base64EncodedString(), publicHost = try Data(contentsOf: host.appendingPathExtension("pub")).base64EncodedString()
        let script = """
        #!/bin/sh
        set -eu
        umask 077
        mkdir -p /root/.ssh
        printf '%s\\n' '\(publicKey)' > /root/.ssh/authorized_keys
        echo '\(privateHost)' | /usr/bin/base64 -d > /etc/ssh/ssh_host_ed25519_key
        echo '\(publicHost)' | /usr/bin/base64 -d > /etc/ssh/ssh_host_ed25519_key.pub
        chmod 600 /root/.ssh/authorized_keys /etc/ssh/ssh_host_ed25519_key
        cat > /etc/ssh/sshd_config <<'SSHD'
        PermitRootLogin prohibit-password
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        HostKey /etc/ssh/ssh_host_ed25519_key
        SSHD
        pw usermod freebsd -w no || true
        sysrc sshd_enable=YES dumpdev=NO savecore_enable=NO sendmail_enable=NONE
        sysrc ntpd_enable=NO growfs_enable=YES hostname=noct-desktop
        swapoff -a || true
        sed -i '' '/gpt\\/swapfs/d' /etc/fstab
        service sshd restart
        touch /root/noct-bootstrap-ready
        echo NOCT_BOOTSTRAP_READY > /dev/console
        """
        try Data((script+"\n").utf8).write(to: safe("Seed/user-data"))
        try Data("instance-id: noct-\(try configuration()["id"]!)\nlocal-hostname: noct-desktop\n".utf8).write(to: safe("Seed/meta-data"))
        _ = try NativeCommand.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", try safe("seed.iso").path, try safe("Seed").path], timeout: 45)
        chmod(try safe("seed.iso").path, 0o600)
    }
}
