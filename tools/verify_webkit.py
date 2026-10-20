#!/usr/bin/env python3
"""Bounded real WebKit storage verification. Not a privileged syscall trace."""
from __future__ import annotations
import contextlib
import ctypes
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from workspace import Workspace, WorkspaceError, process_table, write_json
from verify_workspace import wait_for, disk_inventory


class Audit:
    def __init__(self, ws):
        self.ws, self.sequence = ws, 0

    def call(self, action, **values):
        self.sequence += 1
        folder = self.ws.mount / "Run/NoctBrowser"
        write_json(folder / "request.json", {"id": self.sequence, "action": action, **values})
        def response():
            try:
                value = json.loads((folder / "response.json").read_text())
                return value if value.get("id") == self.sequence else None
            except (OSError, ValueError):
                return None
        result = wait_for(response, timeout=25)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result.get("value")

    def evaluate(self, script):
        return self.call("evaluate", script=script)


def main():
    os.umask(0o077)
    runid = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    evidence = ROOT / "evidence" / ("webkit-" + runid)
    evidence.mkdir(parents=True)
    ws = Workspace(ROOT / "workspaces" / ("WebKitVerification-" + runid))
    password = secrets.token_urlsafe(40).encode()
    token = "NOCT_WEBKIT_CANARY_" + secrets.token_hex(16)
    report = {"workspace": str(ws.folder), "started_at": time.time(), "checks": {},
              "coverage": ["Real WKWebView, nonpersistent website store", "Settings, bookmarks, cookies, localStorage, IndexedDB, HTTP cache, CacheStorage and downloads", "File-level FSEvents and repeated writable-handle samples", "Known app/WebKit host paths before and after", "Actual WebKit helper sandbox checks"],
              "limitations": ["FSEvents has no process attribution and lsof is sampled; short-lived or service-mediated writes can be missed.", "No Endpoint Security entitlement or privileged syscall trace is available.", "Synthetic loopback workload; no real accounts, crashes, extensions, media devices or every website feature.", "Website sessions are intentionally not persisted across browser close or workspace lock."]}
    events, ambiguous_events, handles, drops = [], [], [], []
    stop = threading.Event()
    watcher = server = sampler = consumer = desktop = None
    browser_pid = None
    helper_pids, process_records = set(), {}
    requests = {}
    temp = Path(subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())
    cache = Path(subprocess.check_output(["getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip())
    keywords = ("local.noctdesktop.browser", "noctbrowser", "noct browser")
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    responsible = lib.responsibility_get_pid_responsible_for_pid
    responsible.argtypes = [ctypes.c_int]; responsible.restype = ctypes.c_int
    # Read-only process attribution in this research harness, not a product API.
    report["helper_attribution_method"] = "New WebKit PIDs plus read-only macOS responsibility_get_pid_responsible_for_pid; ambiguity retained explicitly"
    initial_webkit = {pid for pid, row in process_table().items() if "/com.apple.WebKit." in row["command"]}

    def host_snapshot():
        result = {}
        for root in [Path.home() / "Library/WebKit", Path.home() / "Library/Preferences", Path.home() / "Library/Caches", Path.home() / "Library/HTTPStorages", Path.home() / "Library/Saved Application State", temp, cache, Path("/private/tmp")]:
            if not root.exists(): continue
            for base, dirs, files in os.walk(root):
                # Avoid walking unrelated application stores or recording them.
                if Path(base) == root and root.name not in {"Preferences", "T", "C", "tmp"}:
                    dirs[:] = [d for d in dirs if any(k in d.lower() for k in (*keywords, "webkit"))]
                for name in files:
                    path = Path(base) / name
                    if not any(k in str(path).lower() for k in (*keywords, "webkit")): continue
                    with contextlib.suppress(OSError):
                        s = path.stat(); result[str(path)] = [s.st_size, s.st_mtime_ns]
        return result

    baseline = host_snapshot()

    def observed_processes():
        table = process_table()
        own = ws.active_processes()
        for pid, row in table.items():
            if "/com.apple.WebKit." not in row["command"] or pid in initial_webkit: continue
            owner = responsible(pid)
            if browser_pid and (row["ppid"] == browser_pid or owner == browser_pid or any(k in row["command"].lower() for k in keywords)):
                helper_pids.add(pid)
                process_records[pid] = {**row, "responsible_pid": owner, "attribution": "browser"}
            else:
                process_records.setdefault(pid, {**row, "responsible_pid": owner, "attribution": "new WebKit process; unconfirmed"})
        return sorted(set(own) | {pid for pid in helper_pids if pid in table})

    def sample():
        while not stop.is_set():
            pids = observed_processes()
            if pids:
                output = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", ",".join(map(str, pids)), "-F", "pftna"], capture_output=True, text=True).stdout
                pid, item = None, {}
                def retain():
                    if item.get("type") == "REG" and item.get("access") in {"w", "u"} and "path" in item:
                        handles.append({"pid": pid, **item, "time": time.time()})
                for line in output.splitlines():
                    if not line: continue
                    kind, value = line[0], line[1:]
                    if kind in {"p", "f"}:
                        retain(); item = {}
                        if kind == "p": pid = int(value)
                        else: item["fd"] = value
                    elif kind == "a": item["access"] = value
                    elif kind == "t": item["type"] = value
                    elif kind == "n": item["path"] = value
                retain()
            stop.wait(0.15)

    try:
        print("Creating disposable encrypted WebKit workspace", flush=True)
        ws.create(password)
        encrypted = subprocess.run(["hdiutil", "isencrypted", str(ws.image)], capture_output=True, text=True)
        report["encryption_tool_output"] = (encrypted.stdout + encrypted.stderr).strip()
        report["checks"]["encrypted_image"] = encrypted.returncode == 0 and "YES" in encrypted.stdout.upper()
        ws.unlock(password)
        report["installation"] = ws.install_webkit()
        report["browser_bundle_bytes"] = sum(p.stat().st_size for p in ws.webkit_app.rglob("*") if p.is_file() and not p.is_symlink())
        report["checks"]["browser_installed_inside_vault"] = ws.webkit_binary.is_file()

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                route = self.path.split("?", 1)[0]; requests[route] = requests.get(route, 0) + 1
                if route in {"/download.bin", "/slow.bin"}:
                    self.send_response(200); self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Disposition", 'attachment; filename="noct-workspace-download.bin"')
                    self.send_header("Content-Length", str(8 * 1024 * 1024)); self.end_headers()
                    block = (token.encode() + b"\n").ljust(262144, b"x")
                    try:
                        for _ in range(32):
                            self.wfile.write(block); self.wfile.flush(); time.sleep(0.2 if route == "/download.bin" else 1)
                    except (BrokenPipeError, ConnectionResetError): pass
                    return
                if route == "/cache.txt":
                    body = (token + " cached body\n").encode() * 4096; kind = "text/plain"
                else:
                    body = ("""<!doctype html><meta name='color-scheme' content='light dark'><title>Noct Browser workspace verification</title>
<style>body{font:17px -apple-system;margin:8vh 10vw;background:#11232b;color:#e0f6ec}h1{font-size:36px}p{line-height:1.7;color:#b4d0c7}a{color:#89e8d2}#result{white-space:pre-wrap;font:13px ui-monospace;background:#19343b;padding:20px;border-radius:12px}canvas{display:block;margin:20px 0}</style>
<h1>Inside your encrypted workspace.</h1><p>Real WebKit · memory-only website storage<br>Browser settings and download files stay in the vault.</p>
<a id='download' href='/download.bin' download>Download synthetic test file</a> · <a id='slow' href='/slow.bin' download>Slow download for lock check</a>
<canvas id='canvas' width='680' height='50'></canvas><div id='result'>Running website storage checks…</div>
<script>(async()=>{let p={};const t='__TOKEN__';try{
p.previousLocalStorage=localStorage.getItem('noct-test'); p.previousCookie=document.cookie;
localStorage.setItem('noct-test',t);p.localStorage=localStorage.getItem('noct-test');document.cookie='noct='+t+'; SameSite=Strict; path=/';p.cookie=document.cookie;
const db=await new Promise((resolve,reject)=>{let r=indexedDB.open('noct-test',1);r.onupgradeneeded=()=>r.result.createObjectStore('test');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
p.previousIndexedDB=await new Promise((resolve,reject)=>{let r=db.transaction('test').objectStore('test').get('token');r.onsuccess=()=>resolve(r.result??null);r.onerror=()=>reject(r.error)});
await new Promise((resolve,reject)=>{let tx=db.transaction('test','readwrite');tx.objectStore('test').put(t,'token');tx.oncomplete=resolve;tx.onerror=reject});p.indexedDB=true;db.close();
try{let c=await caches.open('noct-cache');await c.put('/cached-object',new Response(t));p.cacheStorage=await(await c.match('/cached-object')).text()}catch(e){p.cacheStorageError=String(e)}
await(await fetch('/cache.txt')).arrayBuffer();await(await fetch('/cache.txt')).arrayBuffer();p.httpCacheWorkload=true;
const ctx=document.querySelector('canvas').getContext('2d');ctx.fillStyle='#79d8bd';ctx.fillRect(0,0,680,50);ctx.fillStyle='#102329';ctx.font='18px -apple-system';ctx.fillText('Noct WebKit · synthetic storage verification',16,32);
const gl=document.createElement('canvas').getContext('webgl');p.webgl=!!gl;
}catch(e){p.error=String(e)}window.proof=p;document.querySelector('#result').textContent=JSON.stringify(p,null,2)})()</script>""").replace("__TOKEN__", token).encode(); kind = "text/html"
                self.send_response(200); self.send_header("Content-Type", kind)
                self.send_header("Cache-Control", "max-age=3600" if route == "/cache.txt" else "no-store")
                self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        origin = f"http://127.0.0.1:{server.server_port}"; report["origin"] = origin
        roots = [str(ws.mount), str(Path.home() / "Library"), str(temp), str(cache), "/private/tmp"]
        watcher = subprocess.Popen([str(ROOT / "build/watch-files"), *roots], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        if watcher.stderr.readline().strip() != "READY": raise RuntimeError("Filesystem observer did not start")
        def consume():
            for line in watcher.stdout:
                with contextlib.suppress(ValueError):
                    event = json.loads(line); path = event["path"]
                    if event["flags"] & 7: drops.append({"time": event["time"], "flags": event["flags"]})
                    if path.startswith(str(ws.mount)) or any(k in path.lower() for k in keywords): events.append(event)
                    elif "webkit" in path.lower(): ambiguous_events.append(event)
        consumer = threading.Thread(target=consume, daemon=True); consumer.start()
        sampler = threading.Thread(target=sample, daemon=True); sampler.start()
        print("Launching real WebKit with normal process protections", flush=True)
        launch = ws.launch_webkit(origin, audit=True); browser_pid = launch["pid"]; report["launch"] = launch
        ready_path = ws.mount / "Run/NoctBrowser/ready.json"
        wait_for(ready_path.exists, timeout=25)
        report["runtime"] = json.loads(ready_path.read_text())
        audit = Audit(ws)
        proof = wait_for(lambda: audit.evaluate("return window.proof ?? null"), timeout=35)
        report["web_workload"] = proof
        report["checks"]["local_storage_in_session"] = proof.get("localStorage") == token
        report["checks"]["cookies_in_session"] = token in proof.get("cookie", "")
        report["checks"]["indexeddb_in_session"] = proof.get("indexedDB") is True
        report["checks"]["cache_storage_in_session"] = proof.get("cacheStorage") == token
        report["http_cache_requests_first_session"] = requests.get("/cache.txt")
        report["checks"]["http_cache_workload_completed"] = proof.get("httpCacheWorkload") is True
        report["checks"]["website_store_nonpersistent"] = audit.call("diagnostics")["isPersistent"] is False
        report["checks"]["foundation_temp_directory_inside_vault"] = report["runtime"]["temporaryDirectory"].startswith(str(ws.mount) + "/")
        report["checks"]["foundation_home_inside_vault"] = report["runtime"]["homeDirectory"].startswith(str(ws.mount) + "/")
        audit.call("settings", homePage=origin, zoom=1.25)
        audit.call("bookmark")
        stored = json.loads((ws.mount / "Apps/NoctBrowser/Settings/settings.json").read_text())
        report["checks"]["settings_and_bookmark_inside_vault"] = stored["zoom"] == 1.25 and origin + "/" in stored["bookmarks"]
        audit.evaluate("document.querySelector('#download').click();return true")
        partial = wait_for(lambda: list((ws.mount / "Apps/NoctBrowser/Temp").glob("*.partial")), timeout=15)
        report["download_temporary_files"] = [str(p.relative_to(ws.mount)) for p in partial]
        report["checks"]["partial_download_inside_vault"] = bool(partial)
        destination = ws.mount / "Downloads/noct-workspace-download.bin"
        wait_for(destination.exists, timeout=25)
        block = (token.encode() + b"\n").ljust(262144, b"x")
        report["checks"]["download_bytes_and_location"] = hashlib.sha256(destination.read_bytes()).digest() == hashlib.sha256(block * 32).digest()
        observed_processes(); time.sleep(2)
        sandbox = ctypes.CDLL("/usr/lib/libsandbox.dylib"); sandbox.sandbox_check.restype = ctypes.c_int
        report["helper_processes"] = dict(process_records)
        report["helper_sandbox_checks"] = {pid: sandbox.sandbox_check(pid, None, 0) for pid in helper_pids}
        report["checks"]["webkit_helpers_sandboxed"] = bool(helper_pids) and all(v > 0 for v in report["helper_sandbox_checks"].values())
        report["checks"]["all_new_webkit_helpers_attributed"] = bool(helper_pids) and all(p["attribution"] == "browser" for p in process_records.values())
        write_json(evidence / "vault-files.json", disk_inventory(ws.mount))
        print("Checking lock, session clearing and encrypted settings reopen", flush=True)
        ws.lock()
        report["checks"]["lock_unmounted_volume"] = ws.attached() is None and not os.path.ismount(ws.mount)
        report["checks"]["settings_downloads_app_unavailable_when_locked"] = not destination.exists() and not ws.webkit_binary.exists() and not (ws.mount / "Apps/NoctBrowser/Settings/settings.json").exists()
        try:
            ws.launch_webkit(); report["checks"]["launch_while_locked_rejected"] = False
        except WorkspaceError: report["checks"]["launch_while_locked_rejected"] = True
        ws.unlock(password); browser_pid = ws.launch_webkit(origin + "/?reopen=1", audit=True)["pid"]
        wait_for(ready_path.exists, timeout=25); audit = Audit(ws)
        reopened = wait_for(lambda: audit.evaluate("return window.proof ?? null"), timeout=35)
        report["web_workload_reopened"] = reopened
        report["checks"]["website_session_cleared_on_lock"] = reopened.get("previousLocalStorage") is None and reopened.get("previousIndexedDB") is None and token not in reopened.get("previousCookie", "")
        report["checks"]["settings_and_download_survive_reopen"] = json.loads((ws.mount / "Apps/NoctBrowser/Settings/settings.json").read_text()) == stored and destination.exists() and audit.call("diagnostics")["zoom"] == 1.25
        audit.evaluate("document.querySelector('#slow').click();return true")
        wait_for(lambda: list((ws.mount / "Apps/NoctBrowser/Temp").glob("*.partial")))
        ws.lock(); report["checks"]["lock_during_download_succeeds"] = ws.attached() is None and not ws.active_processes()
        if "--interactive" in sys.argv:
            ws.unlock(password)
            env = os.environ.copy(); env["NOCT_DESKTOP_WORKSPACE"] = str(ws.folder)
            desktop = subprocess.Popen([str(ROOT / "build/Noct Desktop.app/Contents/MacOS/NoctDesktop")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("INTERACTIVE READY: use Noct Desktop to launch Noct Browser, inspect settings and downloads, then lock and quit Desktop. Enter finish afterward.", flush=True)
            if input().strip() != "finish": raise RuntimeError("Interactive verification was not completed")
            report["checks"]["gui_desktop_quit"] = desktop.poll() is not None
            report["checks"]["gui_desktop_locked_vault"] = ws.attached() is None
        report["checks"]["final_state_locked"] = ws.status()["state"] == "locked"
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        print(report["error"], flush=True)
    finally:
        with contextlib.suppress(Exception): ws.lock()
        if ws.attached(): report["cleanup_error"] = "Synthetic vault is still attached; retain process and inspect before cleanup."
        stop.set()
        if sampler: sampler.join(timeout=5)
        time.sleep(1)
        if watcher:
            watcher.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired): watcher.wait(timeout=5)
        if consumer: consumer.join(timeout=3)
        if server: server.shutdown()
        after = host_snapshot()
        report["host_app_paths_changed"] = {p: v for p, v in after.items() if baseline.get(p) != v and any(k in p.lower() for k in keywords)}
        report["host_webkit_paths_changed_unattributed"] = {p: v for p, v in after.items() if baseline.get(p) != v and not any(k in p.lower() for k in keywords)}
        report["outside_writable_handles"] = sorted({h["path"] for h in handles if not h["path"].startswith(str(ws.mount) + "/")})
        report["outside_app_events"] = sorted({e["path"] for e in events if not e["path"].startswith(str(ws.mount) + "/") and e["path"] != str(ws.mount)})
        report["event_count"] = len(events); report["writable_handle_samples"] = len(handles)
        report["observer_drop_flags"] = drops
        report["checks"]["no_observed_outside_writable_handles"] = not report["outside_writable_handles"]
        report["checks"]["no_known_host_app_changes"] = not report["host_app_paths_changed"]
        report["checks"]["no_outside_app_events"] = not report["outside_app_events"]
        report["checks"]["no_unattributed_webkit_host_changes"] = not report["host_webkit_paths_changed_unattributed"] and not ambiguous_events
        report["checks"]["no_observer_drop_flags"] = not drops
        report["checks"]["temporary_writes_observed_inside_vault"] = any(e["path"].startswith(str(ws.mount / "Apps/NoctBrowser/Temp") + "/") for e in events)
        report["server_requests"] = requests; report["helper_processes"] = process_records
        if not ws.attached() and not ws.active_processes() and ws.metadata.exists():
            for link, target in ws.webkit_redirects():
                if link.is_symlink() and os.readlink(link) == str(target): link.unlink()
            shutil.rmtree(ws.folder)
            with contextlib.suppress(OSError): ws.mount.rmdir()
            report["disposable_image_removed"] = True
        else: report["disposable_image_removed"] = False
        password = b""
        report["finished_at"] = time.time()
        report["all_checks_passed"] = "error" not in report and all(report["checks"].values())
        report["observed_write_confinement_passed"] = "error" not in report and all(report["checks"].get(k, False) for k in ["no_observed_outside_writable_handles", "no_known_host_app_changes", "no_outside_app_events", "no_unattributed_webkit_host_changes", "no_observer_drop_flags", "all_new_webkit_helpers_attributed"])
        write_json(evidence / "report.json", report)
        write_json(evidence / "filesystem-events.json", events)
        write_json(evidence / "ambiguous-webkit-events.json", ambiguous_events)
        write_json(evidence / "writable-file-handles.json", handles)
        write_json(ROOT / "evidence/latest-webkit.json", {"report": str(evidence / "report.json")})
        print(json.dumps({"report": str(evidence / "report.json"), "all_checks_passed": report["all_checks_passed"], "failed_checks": [k for k, v in report["checks"].items() if not v], "error": report.get("error"), "outside_handles": report["outside_writable_handles"], "outside_events": report["outside_app_events"], "host_app_changes": list(report["host_app_paths_changed"]), "helper_processes": process_records}, indent=2), flush=True)
    return 0 if report["all_checks_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
