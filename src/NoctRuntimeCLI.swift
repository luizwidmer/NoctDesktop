// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

@main struct NoctRuntimeCLI {
    static func main() {
        umask(0o077); signal(SIGPIPE, SIG_IGN); var limit = rlimit(rlim_cur: 0, rlim_max: 0); setrlimit(RLIMIT_CORE, &limit)
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            let forwardInput = args.contains("--stdin")
            args.removeAll { $0 == "--stdin" }
            func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i+1 < args.count else { return nil }; let value = args[i+1]; args.removeSubrange(i...i+1); return value }
            let root = URL(fileURLWithPath: option("--root") ?? FileManager.default.currentDirectoryPath)
            guard let path = option("--workspace"), let action = args.first else { throw WorkspaceFailure("Usage: NoctRuntime --workspace PATH [--root SOURCE_ROOT] ACTION [COMMAND]") }
            let ws = NativeWorkspace(folder: URL(fileURLWithPath: path), root: root)
            let result: [String: Any]
            if action == "ssh" {
                guard args.count == 2 else { throw WorkspaceFailure("Provide one quoted guest command.") }
                var input: Data?
                if forwardInput {
                    var bytes = Data()
                    while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
                        guard bytes.count + chunk.count <= 8_388_608 else { throw WorkspaceFailure("Guest input exceeds 8 MiB.") }
                        bytes.append(chunk)
                    }
                    input = bytes
                }
                let reply = try ws.ssh(args[1], input: input, timeout: 1200, check: false)
                FileHandle.standardOutput.write(reply.output); FileHandle.standardError.write(reply.error); exit(reply.status)
            } else if action == "sync-guest" { try ws.syncGuest(); result = ["synced": true] }
            else if action == "wait-ready" { try ws.waitReady(); result = ["ready": true] }
            else { result = try ws.perform(action, password: ["create", "unlock"].contains(action) ? readLine(strippingNewline: true) : nil) }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data+Data([10]))
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])) ?? Data()
            FileHandle.standardError.write(data+Data([10])); exit(1)
        }
    }
}
