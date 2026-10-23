// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import Darwin

@main struct NativeRuntimeChecks {
    static func main() {
        umask(0o077); signal(SIGPIPE, SIG_IGN)
        var limit = rlimit(rlim_cur: 0, rlim_max: 0); setrlimit(RLIMIT_CORE, &limit)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixture = root.appendingPathComponent("workspaces/NativeRuntimeVerification-" + UUID().uuidString)
        let ws = NativeWorkspace(folder: fixture, root: root)
        var checks = [String: Bool]()
        func require(_ condition: Bool, _ name: String) throws { checks[name] = condition; if !condition { throw WorkspaceFailure("Native runtime check failed: " + name) } }
        func rejects(_ name: String, _ action: () throws -> Void) throws { var rejected = false; do { try action() } catch { rejected = true }; try require(rejected, name) }
        do {
            let password = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }).base64EncodedString()
            let result = try ws.perform("create", password: password)
            try require(result["state"] as? String == "locked", "create_finishes_locked")
            let encryption = try NativeCommand.run("/usr/bin/hdiutil", ["isencrypted", ws.image.path]).text
            try require(encryption.contains("encrypted: YES"), "disk_image_is_encrypted")
            try rejects("wrong_password_rejected") { _ = try ws.perform("unlock", password: "incorrect synthetic password") }
            try require(try ws.status()["mounted"] as? Bool == false, "wrong_password_stays_locked")
            _ = try ws.perform("unlock", password: password)
            try ws.requireMounted()
            let marker = ws.mount.appendingPathComponent("Temp/native-verification.txt")
            try Data("synthetic-private-marker".utf8).write(to: marker)
            try rejects("escape_path_rejected") { _ = try ws.safe("../../../outside") }
            try FileManager.default.createDirectory(at: ws.vm, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let link = ws.vm.appendingPathComponent("outside")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            try rejects("symlink_path_rejected") { _ = try ws.safe("outside/file") }
            try FileManager.default.removeItem(at: link)
            let identity = ws.mount.appendingPathComponent(".workspace-identity.json")
            let original = try Data(contentsOf: identity)
            try NativeWorkspace.writeJSON(identity, ["id": "wrong-synthetic-identity"])
            try rejects("wrong_filesystem_identity_rejected") { try ws.requireMounted() }
            try original.write(to: identity)
            let locked = try ws.perform("lock")
            try require(locked["state"] as? String == "locked" && locked["mounted"] as? Bool == false, "detach_verified")
            try require(!FileManager.default.fileExists(atPath: marker.path), "private_file_unavailable_while_locked")
            _ = try ws.perform("unlock", password: password)
            try require(try String(contentsOf: marker, encoding: .utf8) == "synthetic-private-marker", "private_state_survives_reopen")
            _ = try ws.perform("lock")
            try require(try ws.vmProcesses().isEmpty, "no_workspace_vm_after_lock")
            let testMount = ws.mount
            try FileManager.default.removeItem(at: fixture)
            // Only remove the mount directory created by this disposable test.
            if FileManager.default.fileExists(atPath: testMount.path), (try? FileManager.default.contentsOfDirectory(atPath: testMount.path).isEmpty) == true { try FileManager.default.removeItem(at: testMount) }
            let data = try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "controller": "swift"], options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            _ = try? ws.lock()
            FileHandle.standardError.write(Data((error.localizedDescription + "\nPreserved fixture: " + fixture.path + "\n").utf8)); exit(1)
        }
    }
}
