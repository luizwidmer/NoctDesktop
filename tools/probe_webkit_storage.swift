import AppKit
import WebKit

/// Query supported export types in a fresh empty, nonpersistent store. This is
/// an API capability probe, not a website persistence or confinement test.
@main struct WebKitStorageProbe {
    static func main() {
        guard #available(macOS 26.0, *) else { print("{\"unavailable\":true}"); return }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let store = WKWebsiteDataStore.nonPersistent()
        let types = [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeCookies, WKWebsiteDataTypeIndexedDBDatabases]
        var pending = types.count
        var results: [String: Any] = ["isPersistent": store.isPersistent,
                                     "scope": "Empty nonpersistent data store; export API capability only",
                                     "os": ProcessInfo.processInfo.operatingSystemVersionString]
        for type in types {
            store.fetchData(of: [type]) { data, error in
                results[type] = ["accepted": error == nil && data != nil,
                                 "bytes": data?.count ?? 0, "error": error?.localizedDescription ?? ""]
                pending -= 1
                if pending == 0 {
                    let json = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    FileHandle.standardOutput.write(json)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                    application.terminate(nil)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if pending != 0 { fputs("WebKit export capability probe timed out.\n", stderr); exit(2) }
        }
        application.run()
    }
}
