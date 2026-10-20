#!/usr/bin/env python3
"""Exercise real Chromium on an encrypted macOS disk image using synthetic data.

FSEvents has no process attribution; lsof is sampled. This harness must never
describe the combination as a complete syscall trace or a proof of no leakage.
"""
from __future__ import annotations
import base64
import contextlib
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import secrets
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from workspace import Workspace, WorkspaceError, ARCHIVE, REVISION, write_json


class CDP:
    """Small RFC 6455 client; no external Python packages or browser extensions."""
    def __init__(self, url):
        from urllib.parse import urlsplit
        u = urlsplit(url)
        self.socket = socket.create_connection((u.hostname, u.port), timeout=15)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        request = (f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\n"
                   f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                   "Sec-WebSocket-Version: 13\r\n\r\n")
        self.socket.sendall(request.encode())
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            header.extend(self.socket.recv(1))
            if len(header) > 65536:
                raise RuntimeError("Oversized websocket handshake")
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        if b" 101 " not in header.split(b"\r\n", 1)[0] or expected.lower() not in header.lower():
            raise RuntimeError("Invalid websocket handshake")
        self.seq = 0
        self.events = []

    def exact(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = self.socket.recv(size - len(result))
            if not chunk:
                raise EOFError("Browser websocket closed")
            result.extend(chunk)
        return bytes(result)

    def send(self, payload, opcode=1):
        data = payload if isinstance(payload, bytes) else payload.encode()
        size = len(data)
        header = bytes([0x80 | opcode])
        if size < 126:
            header += bytes([0x80 | size])
        elif size < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", size)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", size)
        mask = secrets.token_bytes(4)
        self.socket.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def receive(self):
        data = bytearray()
        while True:
            first, second = self.exact(2)
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", self.exact(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.exact(8))[0]
            mask = self.exact(4) if second & 128 else None
            payload = self.exact(size)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            opcode = first & 15
            if opcode == 8:
                raise EOFError("Browser websocket closed")
            if opcode == 9:
                self.send(payload, opcode=10)
                continue
            if opcode in [0, 1]:
                data.extend(payload)
                if first & 128:
                    return json.loads(data)

    def call(self, method, params=None):
        self.seq += 1
        self.send(json.dumps({"id": self.seq, "method": method, "params": params or {}}))
        while True:
            message = self.receive()
            if message.get("id") == self.seq:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message.get("result", {})
            self.events.append(message)

    def evaluate(self, expression):
        reply = self.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True,
                                               "returnByValue": True})
        if "exceptionDetails" in reply:
            raise RuntimeError(reply["exceptionDetails"])
        return reply.get("result", {}).get("value")

    def close(self):
        self.socket.close()


def wait_for(fn, *, timeout=30):
    until = time.monotonic() + timeout
    last = None
    while time.monotonic() < until:
        try:
            result = fn()
            if result:
                return result
        except (OSError, ValueError, RuntimeError, EOFError) as error:
            last = error
        time.sleep(0.2)
    raise TimeoutError(f"Condition did not become true; last error: {last}")


def http_json(url):
    with urllib.request.urlopen(url, timeout=3) as response:
        return json.load(response)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def disk_inventory(root):
    entries = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != "Applications"]
        for name in files:
            p = Path(base) / name
            with contextlib.suppress(OSError):
                entries.append({"path": str(p.relative_to(root)), "size": p.stat().st_size})
    return entries


def host_snapshot(darwin_temp, darwin_cache):
    home = Path.home()
    roots = [home / "Library/Application Support/Chromium", home / "Library/Caches/Chromium",
             home / "Library/Caches/org.chromium.Chromium", home / "Library/Saved Application State/org.chromium.Chromium.savedState"]
    entries = {}
    for root in roots:
        if root.exists():
            for base, dirs, files in os.walk(root):
                for name in files:
                    p = Path(base) / name
                    with contextlib.suppress(OSError):
                        s = p.stat()
                        entries[str(p)] = [s.st_size, s.st_mtime_ns]
    for directory in [home / "Library/Preferences", Path(darwin_temp), Path(darwin_cache), Path("/private/tmp")]:
        if directory.exists():
            for p in directory.iterdir():
                if "chromium" in p.name.lower():
                    with contextlib.suppress(OSError):
                        s = p.stat()
                        entries[str(p)] = [s.st_size, s.st_mtime_ns]
                        if p.is_dir():
                            for base, dirs, files in os.walk(p):
                                for name in files:
                                    child = Path(base) / name
                                    with contextlib.suppress(OSError):
                                        cs = child.stat()
                                        entries[str(child)] = [cs.st_size, cs.st_mtime_ns]
    return entries


def main():
    os.umask(0o077)
    runid = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    evidence = ROOT / "evidence" / runid
    evidence.mkdir(parents=True, mode=0o700)
    ws = Workspace(ROOT / "workspaces" / ("Verification-" + runid))
    password = secrets.token_urlsafe(40).encode()
    token = "WORKSPACE_CANARY_" + secrets.token_hex(16)
    report = {"started_at": time.time(), "workspace": str(ws.folder), "chromium_revision": REVISION,
              "checks": {}, "coverage": ["Real GUI Chromium; sandbox enabled", "FSEvents file changes without PID attribution",
                                          "Repeated lsof writable-file samples of this workspace's processes",
                                          "Before/after snapshots of known host Chromium paths", "Synthetic audit mode uses Chromium's mock Keychain"],
              "limitations": ["No privileged syscall trace: sudo unavailable and Endpoint Security entitlement unavailable.",
                              "FSEvents and sampled handles cannot rule out every short-lived write or service-mediated write.",
                              "Synthetic loopback workload; no real accounts, extensions, media devices, or crash recovery workload.",
                              "The vault password is generated only in this process and is not persisted; the verification vault is disposable."]}
    events, handles, dropped_events = [], [], []
    stop = threading.Event()
    darwin_temp = subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()
    darwin_cache = subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip()
    baseline = host_snapshot(darwin_temp, darwin_cache)
    watcher = server = page = browser = None
    watch_thread = sample_thread = None
    requests = {}
    downloaded = threading.Event()
    try:
        print("Creating AES-256 encrypted workspace", flush=True)
        ws.create(password)
        report["checks"]["created_locked"] = ws.status()["state"] == "locked"
        encrypted = subprocess.run(["/usr/bin/hdiutil", "isencrypted", str(ws.image)], capture_output=True, text=True)
        report["encryption_tool_output"] = (encrypted.stdout + encrypted.stderr).strip()
        report["checks"]["image_reports_encryption"] = encrypted.returncode == 0 and "YES" in encrypted.stdout.upper()
        try:
            ws.unlock(b"intentionally-incorrect-workspace-password")
            report["checks"]["wrong_password_rejected"] = False
        except WorkspaceError:
            report["checks"]["wrong_password_rejected"] = ws.attached() is None
        ws.unlock(password)
        print("Installing Chromium inside the encrypted workspace", flush=True)
        report["installation"] = ws.install(ARCHIVE)

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                route = self.path.split("?", 1)[0]
                requests[route] = requests.get(route, 0) + 1
                if route == "/download.bin":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Disposition", 'attachment; filename="workspace-download.bin"')
                    self.send_header("Content-Length", str(8 * 1024 * 1024))
                    self.end_headers()
                    block = (token.encode() + b"\n") * 8192
                    block = block[:262144].ljust(262144, b"x")
                    try:
                        for _ in range(32):
                            self.wfile.write(block)
                            self.wfile.flush()
                            time.sleep(0.15)
                        downloaded.set()
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                if route == "/cache.txt":
                    data = (token + " cache-body\n").encode() * 2048
                    kind = "text/plain"
                elif route == "/worker.js":
                    data = b"self.addEventListener('install',e=>self.skipWaiting());self.addEventListener('activate',e=>e.waitUntil(clients.claim()));"
                    kind = "text/javascript"
                else:
                    html = (ROOT / "src" / "proof.html").read_text().replace("__CANARY__", token)
                    data, kind = html.encode(), "text/html"
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "public, max-age=3600" if route == "/cache.txt" else "no-store")
                self.end_headers()
                self.wfile.write(data)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        origin = f"http://127.0.0.1:{server.server_port}"
        report["origin"] = origin
        with urllib.request.urlopen(origin + "/cache.txt", timeout=3) as response:
            report["checks"]["loopback_server_responds"] = response.status == 200
        requests.clear()
        roots = [str(ws.mount), str(Path.home() / "Library"), darwin_temp, darwin_cache,
                 "/private/tmp", str(Path.home() / "Downloads")]
        watcher = subprocess.Popen([str(ROOT / "build/watch-files"), *roots], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)
        ready = watcher.stderr.readline().strip()
        if ready != "READY":
            raise RuntimeError(f"FSEvents observer could not start: {ready}")

        def consume_events():
            for line in watcher.stdout:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                path = e["path"]
                if e["flags"] & (1 | 2 | 4):
                    # Capture stream health even if the event names an
                    # unrelated path. Do not retain that unrelated path.
                    dropped_events.append({"flags": e["flags"], "time": e["time"]})
                # Discard unrelated user paths without recording them.
                if path.startswith(str(ws.mount)) or "chromium" in path.lower():
                    events.append(e)

        watch_thread = threading.Thread(target=consume_events, daemon=True)
        watch_thread.start()

        def sample_handles():
            while not stop.is_set():
                pids = list(ws.active_processes())
                if pids:
                    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", ",".join(map(str, pids)),
                                             "-F", "pftna"], capture_output=True, text=True)
                    pid, item = None, {}
                    for line in result.stdout.splitlines():
                        if not line:
                            continue
                        kind, value = line[0], line[1:]
                        if kind in "pf":
                            if item.get("type") == "REG" and item.get("access") in ["w", "u"] and "path" in item:
                                handles.append({"pid": pid, **item, "time": time.time()})
                            item = {}
                            if kind == "p":
                                pid = int(value)
                            else:
                                item["fd"] = value
                        elif kind == "a": item["access"] = value
                        elif kind == "t": item["type"] = value
                        elif kind == "n": item["path"] = value
                    if item.get("type") == "REG" and item.get("access") in ["w", "u"] and "path" in item:
                        handles.append({"pid": pid, **item, "time": time.time()})
                stop.wait(0.15)

        sample_thread = threading.Thread(target=sample_handles, daemon=True)
        sample_thread.start()
        port = free_port()
        print("Launching real GUI Chromium and exercising persistent storage", flush=True)
        report["launch"] = ws.launch(origin, audit_port=port)
        endpoint = f"http://127.0.0.1:{port}"
        browser_info = wait_for(lambda: http_json(endpoint + "/json/version"))
        report["browser_version"] = browser_info["Browser"]
        browser = CDP(browser_info["webSocketDebuggerUrl"])
        targets = wait_for(lambda: [p for p in http_json(endpoint + "/json/list") if p.get("url", "").startswith(origin)])
        report["targets"] = targets
        page = CDP(targets[0]["webSocketDebuggerUrl"])
        page.call("Network.enable")
        page.call("Page.enable")
        report["navigation"] = page.call("Page.navigate", {"url": origin + "/?explicit=1"})
        report["stage"] = "waiting_for_web_storage_workload"
        proof = wait_for(lambda: page.evaluate("window.proof || null"))
        report["workload"] = proof
        if proof.get("error"):
            raise RuntimeError(proof["error"])
        report["checks"]["local_storage_written"] = proof.get("localStorage") == token
        report["checks"]["indexeddb_written"] = proof.get("indexedDB") == token
        report["checks"]["cache_storage_written"] = proof.get("cacheStorage") == token
        report["checks"]["service_worker_active"] = proof.get("serviceWorker") is True
        report["checks"]["cookie_written"] = token in proof.get("cookie", "")
        report["checks"]["http_cache_reused"] = requests.get("/cache.txt") == 1

        # This creates a real browser-managed .crdownload temporary file.
        page.evaluate("document.querySelector('#download').click(); true")
        partials = wait_for(lambda: list((ws.mount / "Downloads").glob("*.crdownload")), timeout=15)
        report["download_temporary_files"] = [str(p.relative_to(ws.mount)) for p in partials]
        report["checks"]["partial_download_inside_vault"] = bool(partials)
        wait_for(lambda: downloaded.is_set() and (ws.mount / "Downloads/workspace-download.bin").exists(), timeout=20)
        report["checks"]["completed_download_inside_vault"] = (ws.mount / "Downloads/workspace-download.bin").stat().st_size == 8 * 1024 * 1024
        time.sleep(3)
        screenshot = page.call("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
        (evidence / "chromium-proof.png").write_bytes(base64.b64decode(screenshot["data"]))
        if (ws.mount / "Logs/preferences-trace.log").exists():
            (evidence / "preferences-trace.log").write_bytes((ws.mount / "Logs/preferences-trace.log").read_bytes())
        inventory = disk_inventory(ws.mount)
        write_json(evidence / "vault-files.json", inventory)
        prefs = json.loads((ws.profile / "Default/Preferences").read_text())
        report["download_preference"] = prefs.get("download", {}).get("default_directory")
        report["checks"]["profile_inside_vault"] = (ws.profile / "Default/History").exists() and (ws.profile / "Local State").exists()
        report["checks"]["disk_cache_inside_vault"] = any(p.is_file() for p in (ws.mount / "Cache/Chromium").rglob("*"))
        report["checks"]["no_disable_sandbox_flag"] = "--no-sandbox" not in (ws.mount / "Run/browser.json").read_text()
        report["launch_configuration"] = json.loads((ws.mount / "Run/browser.json").read_text())
        # Check the actual process sandbox on macOS, not only the launch flags.
        import ctypes
        sandbox = ctypes.CDLL("/usr/lib/libsandbox.dylib")
        sandbox.sandbox_check.restype = ctypes.c_int
        table = ws.active_processes()
        renderers = [pid for pid, row in table.items() if "--type=renderer" in row["command"]]
        sandbox_checks = {pid: sandbox.sandbox_check(pid, None, 0) for pid in renderers}
        report["renderer_sandbox_checks"] = sandbox_checks
        report["checks"]["renderer_sandbox_active"] = bool(sandbox_checks) and all(v > 0 for v in sandbox_checks.values())
        print("Closing Chromium and checking encrypted lock behavior", flush=True)
        page.close(); page = None
        browser.call("Browser.close"); browser.close(); browser = None
        wait_for(lambda: not ws.active_processes(), timeout=20)
        ws.lock()
        report["checks"]["lock_unmounted_volume"] = ws.attached() is None and not os.path.ismount(ws.mount)
        report["checks"]["profile_unavailable_when_locked"] = not ws.profile.exists()
        report["checks"]["app_unavailable_when_locked"] = not ws.binary.exists()
        try:
            ws.launch()
            report["checks"]["launch_while_locked_rejected"] = False
        except WorkspaceError:
            report["checks"]["launch_while_locked_rejected"] = True
        ws.unlock(password)
        # Verify actual persistent web state after a full stop/unmount/remount.
        ws.launch(origin + "/?reopen=1", audit_port=port)
        wait_for(lambda: http_json(endpoint + "/json/version"))
        target = wait_for(lambda: [p for p in http_json(endpoint + "/json/list") if p.get("url", "").startswith(origin)])[0]
        page = CDP(target["webSocketDebuggerUrl"])
        restored = wait_for(lambda: page.evaluate("window.proof || null"))
        report["checks"]["data_survives_encrypted_reopen"] = restored.get("previousLocalStorage") == token and restored.get("previousIndexedDB") == token
        page.close(); page = None
        ws.lock()
        report["checks"]["launcher_can_close_browser_and_lock"] = not ws.active_processes() and ws.attached() is None
        ws.unlock(password)
        busy = (ws.mount / "Data/busy-lock-test.txt").open("w+")
        busy.write("Synthetic lock test\n"); busy.flush()
        try:
            try:
                ws.lock()
                report["checks"]["busy_volume_lock_reports_failure"] = False
            except WorkspaceError:
                report["checks"]["busy_volume_lock_reports_failure"] = ws.status()["state"] == "unlocked"
        finally:
            busy.close()
        ws.lock()
        report["checks"]["final_state_locked"] = ws.status()["state"] == "locked"
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        report["server_requests"] = dict(requests)
        if page:
            report["page_events"] = page.events[-80:]
            with contextlib.suppress(Exception):
                report["page_diagnostic"] = page.evaluate("({url:location.href,title:document.title,status:document.querySelector('#status')?.textContent,html:document.documentElement.outerHTML.slice(-6000),proof:window.proof})")
                screenshot = page.call("Page.captureScreenshot", {"format": "png"})
                (evidence / "chromium-diagnostic.png").write_bytes(base64.b64decode(screenshot["data"]))
        if ws.attached():
            with contextlib.suppress(Exception):
                (evidence / "browser-stderr.log").write_bytes((ws.mount / "Logs/browser-stderr.log").read_bytes())
        print(report["error"], flush=True)
    finally:
        if page:
            page.close()
        if browser:
            browser.close()
        stop.set()
        if sample_thread:
            sample_thread.join(timeout=5)
        time.sleep(1)
        if watcher:
            watcher.terminate()
            try: watcher.wait(timeout=5)
            except subprocess.TimeoutExpired: watcher.kill()
        if watch_thread:
            watch_thread.join(timeout=3)
        if server:
            server.shutdown()
        # Always try to seal synthetic data even after failed verification.
        try:
            ws.lock()
        except Exception as error:
            report["cleanup_error"] = str(error)
        password = b""
        after = host_snapshot(darwin_temp, darwin_cache)
        report["host_known_paths_changed"] = {p: v for p, v in after.items() if baseline.get(p) != v}
        report["host_known_paths_removed"] = [p for p in baseline if p not in after]
        report["outside_writable_file_handles"] = sorted({h["path"] for h in handles if not h["path"].startswith(str(ws.mount) + "/")})
        report["outside_chromium_path_events"] = sorted({e["path"] for e in events if e["path"] != str(ws.mount) and not e["path"].startswith(str(ws.mount) + "/")})
        report["event_count"] = len(events)
        report["writable_handle_sample_count"] = len(handles)
        report["checks"]["temp_activity_observed_inside_vault"] = any(e["path"].startswith(str(ws.mount / "Temp") + "/") for e in events)
        report["observer_drop_events"] = dropped_events
        report["checks"]["no_event_drop_flags"] = not dropped_events
        report["checks"]["no_observed_outside_writable_handles"] = not report["outside_writable_file_handles"]
        report["checks"]["no_changes_in_known_host_chromium_paths"] = not report["host_known_paths_changed"]
        report["checks"]["no_outside_chromium_path_events"] = not report["outside_chromium_path_events"]
        report["finished_at"] = time.time()
        report["all_checks_passed"] = bool(report["checks"]) and all(report["checks"].values()) and "error" not in report
        lifecycle = ["created_locked", "image_reports_encryption", "wrong_password_rejected", "local_storage_written",
                     "indexeddb_written", "cache_storage_written", "service_worker_active", "cookie_written",
                     "http_cache_reused", "partial_download_inside_vault", "completed_download_inside_vault",
                     "profile_inside_vault", "disk_cache_inside_vault", "no_disable_sandbox_flag", "renderer_sandbox_active",
                     "lock_unmounted_volume", "profile_unavailable_when_locked", "app_unavailable_when_locked",
                     "launch_while_locked_rejected", "data_survives_encrypted_reopen", "launcher_can_close_browser_and_lock",
                     "busy_volume_lock_reports_failure", "final_state_locked", "temp_activity_observed_inside_vault"]
        report["storage_lifecycle_passed"] = all(report["checks"].get(k, False) for k in lifecycle)
        report["observed_write_confinement_passed"] = all(report["checks"].get(k, False) for k in [
            "no_event_drop_flags", "no_observed_outside_writable_handles", "no_changes_in_known_host_chromium_paths",
            "no_outside_chromium_path_events"]) and "error" not in report
        write_json(evidence / "filesystem-events.json", events)
        write_json(evidence / "writable-file-handles.json", handles)
        write_json(evidence / "report.json", report)
        write_json(ROOT / "evidence/latest.json", {"report": str(evidence / "report.json")})
        print(json.dumps({"report": str(evidence / "report.json"), "all_checks_passed": report["all_checks_passed"],
                          "failed_checks": [k for k, v in report["checks"].items() if not v],
                          "error": report.get("error"), "outside_writable_handles": report["outside_writable_file_handles"],
                          "host_changes": list(report["host_known_paths_changed"]),
                          "outside_path_events": report["outside_chromium_path_events"]}, indent=2), flush=True)
    return 0 if report["all_checks_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
