import AppKit
import Darwin

enum BrowserFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// Explicit cooperative storage context. Environment variables alone are not
/// an isolation boundary. Every owned file is checked against this mount.
final class BrowserWorkspace {
    let root: URL
    let identifier: String
    let home: URL
    let settings: URL
    let cache: URL
    let temporary: URL
    let downloads: URL
    let run: URL

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NOCT_WORKSPACE_ROOT"], let id = env["NOCT_WORKSPACE_ID"] else {
            throw BrowserFailure.message("Open Noct Browser from an unlocked Noct Desktop workspace.")
        }
        root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        identifier = id
        home = root.appendingPathComponent("Apps/NoctBrowser/Home", isDirectory: true)
        settings = root.appendingPathComponent("Apps/NoctBrowser/Settings", isDirectory: true)
        cache = root.appendingPathComponent("Apps/NoctBrowser/Cache", isDirectory: true)
        temporary = root.appendingPathComponent("Apps/NoctBrowser/Temp", isDirectory: true)
        downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        run = root.appendingPathComponent("Run/NoctBrowser", isDirectory: true)
        try validate()
        guard Bundle.main.bundleURL.standardizedFileURL == root.appendingPathComponent("Applications/Noct Browser.app") else {
            throw BrowserFailure.message("The browser executable must be installed in this workspace.")
        }
        for url in [home, settings, cache, temporary, downloads, run] { try check(url) }
    }

    func validate() throws {
        guard root.resolvingSymlinksInPath() == root else { throw BrowserFailure.message("Invalid workspace mount path.") }
        var info = statfs()
        guard statfs(root.path, &info) == 0 else { throw BrowserFailure.message("The encrypted workspace is unavailable.") }
        let mounted = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard mounted == root.path else { throw BrowserFailure.message("The workspace is locked; no host storage fallback is permitted.") }
        let marker = root.appendingPathComponent(".workspace-identity.json")
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
              value["id"] as? String == identifier else { throw BrowserFailure.message("Workspace identity does not match.") }
    }

    func check(_ url: URL) throws {
        try validate()
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == path else {
            throw BrowserFailure.message("A storage path escapes the encrypted workspace.")
        }
    }

    func read(_ url: URL) throws -> Data { try check(url); return try Data(contentsOf: url) }

    /// Use an explicit sibling temporary file; Foundation's replacement-item
    /// directory must never choose an OS temporary directory for settings.
    func write(_ value: Any, to url: URL) throws {
        try check(url)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        let stage = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try check(stage)
        let fd = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw BrowserFailure.message("Could not create a workspace temporary file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try check(url)
            guard rename(stage.path, url.path) == 0 else { throw BrowserFailure.message("Could not save inside the workspace.") }
        } catch {
            try? handle.close(); unlink(stage.path); throw error
        }
    }
}

struct BrowserSettings: Codable {
    var homePage = "about:blank"
    var zoom = 1.0
    var bookmarks: [String] = []

    static func load(_ storage: BrowserWorkspace) throws -> BrowserSettings {
        let path = storage.settings.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return BrowserSettings() }
        let result = try JSONDecoder().decode(BrowserSettings.self, from: storage.read(path))
        guard result.zoom >= 0.5, result.zoom <= 2, allowedURL(result.homePage) != nil,
              result.bookmarks.count <= 1000, result.bookmarks.allSatisfy({ allowedURL($0) != nil }) else {
            throw BrowserFailure.message("Invalid workspace browser settings.")
        }
        return result
    }

    func save(_ storage: BrowserWorkspace) throws {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        try storage.write(value, to: storage.settings.appendingPathComponent("settings.json"))
    }

    static func allowedURL(_ input: String) -> URL? {
        if input == "about:blank" { return URL(string: input) }
        guard let value = URL(string: input), ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host != nil, value.user == nil, value.password == nil else { return nil }
        return value
    }
}

/// Downloads use a data stream, never URLSessionDownloadTask's OS staging
/// location. Both partial bytes and the completed file stay on the vault.
final class WorkspaceDownload: NSObject, URLSessionDataDelegate {
    let storage: BrowserWorkspace
    let request: URLRequest
    let cookies: [HTTPCookie]
    let completion: (Result<URL, Error>) -> Void
    let progress: (Int64) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var partial: URL?
    private var filename = "Download"
    private var count: Int64 = 0
    private var failure: Error?

    init(storage: BrowserWorkspace, request: URLRequest, cookies: [HTTPCookie],
         progress: @escaping (Int64) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.storage = storage; self.request = request; self.cookies = cookies
        self.progress = progress; self.completion = completion
    }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage?.setCookies(cookies, for: request.url, mainDocumentURL: nil)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        task = session!.dataTask(with: request); task!.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try storage.validate()
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw BrowserFailure.message("The download server returned an error.")
            }
            filename = String((response.suggestedFilename ?? "Download").split(separator: "/").last ?? "Download")
                .replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\0", with: "_")
            if filename.isEmpty || filename == "." || filename == ".." { filename = "Download" }
            filename = String(filename.prefix(180))
            let path = storage.temporary.appendingPathComponent(UUID().uuidString + ".partial")
            try storage.check(path)
            let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw BrowserFailure.message("Cannot create a download in the encrypted workspace.") }
            partial = path; file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try storage.validate()
            guard let file = file else { throw BrowserFailure.message("Download storage is unavailable.") }
            try file.write(contentsOf: data); count += Int64(data.count)
            let amount = count; DispatchQueue.main.async { self.progress(amount) }
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { BrowserSettings.allowedURL($0.absoluteString) } == nil ? nil : request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<URL, Error>
        do {
            if let error = failure ?? error { throw error }
            guard let file = file, let partial = partial else { throw BrowserFailure.message("Download did not produce a file.") }
            try file.synchronize(); try file.close(); self.file = nil
            var destination: URL?
            for index in 0..<1000 {
                let name = index == 0 ? filename : "\(index)-\(filename)"
                let path = storage.downloads.appendingPathComponent(name)
                try storage.check(path)
                // link() refuses an existing destination, including symlinks.
                if link(partial.path, path.path) == 0 { destination = path; break }
                if errno != EEXIST { throw BrowserFailure.message("Could not complete the workspace download.") }
            }
            guard let destination = destination else { throw BrowserFailure.message("Too many files with this download name.") }
            unlink(partial.path); self.partial = nil
            result = .success(destination)
        } catch {
            try? file?.close(); file = nil
            if let partial = partial { unlink(partial.path); self.partial = nil }
            result = .failure(error)
        }
        session.invalidateAndCancel(); self.session = nil
        DispatchQueue.main.async { self.completion(result) }
    }
}
