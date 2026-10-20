#!/usr/bin/env python3
"""Native encrypted workspace with Noct Browser and a Chromium research adapter.

This is a storage-location prototype, not an application sandbox or a security
product. Passwords travel only through anonymous stdin pipes to hdiutil.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import uuid
import zipfile
import stat
import posixpath

ROOT = Path(__file__).resolve().parents[1]
REVISION = "1722776"
ARCHIVE = ROOT / "downloads" / f"chromium-{REVISION}-mac-arm64.zip"
DOWNLOAD_URL = f"https://storage.googleapis.com/chromium-browser-snapshots/Mac_Arm/{REVISION}/chrome-mac.zip"
# Pinned after retrieving this exact development snapshot over HTTPS from the
# official Chromium bucket. This detects a changed archive; it is not a vendor
# signature or a notarization claim.
ARCHIVE_SHA256 = "f28ed27b0e03890408ec8372f7b67b367701ae5fd3d286da980312cd639ad951"


class WorkspaceError(RuntimeError):
    pass


def run(args, *, password=None, timeout=90, **kwargs):
    payload = None
    if password is not None:
        if not password or b"\x00" in password or b"\n" in password:
            raise WorkspaceError("The password must be nonempty and contain no newline or NUL.")
        payload = password + b"\x00"
    result = subprocess.run([str(x) for x in args], input=payload,
                            capture_output=True, timeout=timeout, **kwargs)
    if result.returncode:
        # hdiutil does not print stdin credentials. Never include the input here.
        message = result.stderr.decode(errors="replace").strip()
        raise WorkspaceError(f"{Path(str(args[0])).name} failed ({result.returncode}): {message}")
    return result.stdout


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + ".new")
    with temp.open("w") as f:
        os.chmod(temp, 0o600)
        json.dump(value, f, indent=2)
        f.write("\n")
    os.replace(temp, path)


def process_table():
    data = run(["/bin/ps", "-axo", "pid=,ppid=,command="]).decode(errors="replace")
    rows = {}
    for line in data.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows[int(fields[0])] = {"ppid": int(fields[1]), "command": fields[2]}
    return rows


class Workspace:
    def __init__(self, folder):
        self.folder = Path(folder).expanduser().resolve()
        self.metadata = self.folder / "workspace.json"
        self.image = self.folder / "Workspace.sparsebundle"

    @property
    def mount(self):
        if self.metadata.exists():
            config = self.config()
            if config.get("short_mount_id"):
                return Path.home() / ".ew-mounts" / config["short_mount_id"]
        return self.folder / "Mounted"

    @contextlib.contextmanager
    def exclusive(self):
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.folder / ".operation.lock").open("a") as f:
            os.chmod(f.name, 0o600)
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise WorkspaceError("Another workspace operation is running.")
            yield

    def config(self):
        if not self.metadata.exists():
            raise WorkspaceError("Create the workspace first.")
        return json.loads(self.metadata.read_text())

    def attached(self):
        info = plistlib.loads(run(["/usr/bin/hdiutil", "info", "-plist"]))
        for image in info.get("images", []):
            path = image.get("image-path", "")
            if path and Path(path).resolve() == self.image:
                return image
        return None

    def require_mounted(self):
        info = self.attached()
        if not info:
            raise WorkspaceError("The workspace is locked. Unlock it first.")
        matching = [e for e in info.get("system-entities", [])
                    if e.get("mount-point") and Path(e["mount-point"]).resolve() == self.mount]
        if len(matching) != 1 or not os.path.ismount(self.mount):
            raise WorkspaceError("The image is attached at an unexpected location; no operation was performed.")
        marker = self.mount / ".workspace-identity.json"
        if not marker.exists() or json.loads(marker.read_text()).get("id") != self.config()["id"]:
            raise WorkspaceError("The mounted filesystem identity does not match this workspace.")
        return matching[0]

    @property
    def app(self):
        return self.mount / "Applications" / "Chromium.app"

    @property
    def binary(self):
        return self.app / "Contents" / "MacOS" / "Chromium"

    @property
    def profile(self):
        return self.mount / "Data" / "Chromium"

    def create(self, password, *, size="4g"):
        if len(password) < 12:
            raise WorkspaceError("Use at least 12 characters for a new workspace password.")
        if self.image.exists() or self.metadata.exists():
            raise WorkspaceError("This workspace already exists; it will not be overwritten.")
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.folder, 0o700)
        if size not in {"4g", "8g"}:
            raise WorkspaceError("Unsupported prototype volume size.")
        run(["/usr/bin/hdiutil", "create", "-size", size, "-type", "SPARSEBUNDLE",
             "-fs", "APFS", "-volname", "Noct Desktop Workspace", "-encryption", "AES-256",
             "-stdinpass", self.image], password=password, timeout=180)
        write_json(self.metadata, {"format": 1, "id": str(uuid.uuid4()), "created_at": time.time(),
                                   "chromium_revision": REVISION, "encryption": "AES-256 disk image",
                                   "short_mount_id": uuid.uuid4().hex[:12]})
        self.unlock(password, initializing=True)
        self.lock()

    def unlock(self, password, *, initializing=False):
        config = self.config()
        if self.attached():
            if initializing:
                raise WorkspaceError("An image unexpectedly became attached during creation.")
            self.require_mounted()
            return self.status()
        # Chromium's singleton Unix socket has a short path limit. A random
        # private mount beneath HOME avoids deep project folder names.
        if self.mount.parent.is_symlink():
            raise WorkspaceError("The mount parent must not be a symlink.")
        self.mount.parent.mkdir(exist_ok=True, mode=0o700)
        if self.mount.parent.stat().st_uid != os.getuid():
            raise WorkspaceError("The mount parent must belong to the current user.")
        os.chmod(self.mount.parent, 0o700)
        self.mount.mkdir(exist_ok=True, mode=0o700)
        if self.mount.is_symlink() or any(self.mount.iterdir()):
            raise WorkspaceError("The mount location must be an empty directory, without symlinks.")
        run(["/usr/bin/hdiutil", "attach", self.image, "-stdinpass", "-nobrowse", "-owners", "on",
             "-mountpoint", self.mount, "-plist"], password=password)
        if initializing:
            os.chmod(self.mount, 0o700)
            write_json(self.mount / ".workspace-identity.json", {"id": config["id"]})
        self.require_mounted()
        for name in ["Applications", "Data/Chromium", "Cache/Chromium", "Temp", "Downloads",
                     "Home/Library/Application Support", "Home/Library/Caches", "Home/Library/Preferences",
                     "Home/Library/Saved Application State", "Home/Documents", "Home/Desktop", "Logs", "Run"]:
            (self.mount / name).mkdir(parents=True, exist_ok=True, mode=0o700)
        # Prevent Spotlight from indexing workspace content. This is advisory,
        # not a universal guarantee about system metadata.
        (self.mount / ".metadata_never_index").touch(mode=0o600)
        return self.status()

    def install(self, archive=ARCHIVE):
        self.require_mounted()
        if self.active_processes():
            raise WorkspaceError("Close workspace Chromium before installing.")
        if self.app.exists():
            return {"installed": True, "already_present": True, "path": str(self.app)}
        archive = Path(archive).resolve()
        if not archive.is_file():
            raise WorkspaceError(f"Download the official Chromium archive first: {DOWNLOAD_URL}")
        with archive.open("rb") as source_file:
            digest = hashlib.file_digest(source_file, "sha256").hexdigest()
        if digest != ARCHIVE_SHA256:
            raise WorkspaceError("The archive does not match the pinned official development snapshot.")
        # Validate every member before giving the official archive to ditto.
        with zipfile.ZipFile(archive) as z:
            for item in z.infolist():
                path = Path(item.filename)
                if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] not in ["chrome-mac", "__MACOSX"]:
                    raise WorkspaceError("Unsafe or unexpected browser archive member.")
                if stat.S_ISLNK(item.external_attr >> 16):
                    target = z.read(item).decode("utf-8")
                    resolved = posixpath.normpath(posixpath.join(str(path.parent), target))
                    if target.startswith("/") or not resolved.startswith("chrome-mac/"):
                        raise WorkspaceError("Browser archive symlink escapes its application tree.")
        stage = self.mount / "Temp" / ("install-" + uuid.uuid4().hex)
        stage.mkdir(mode=0o700)
        try:
            run(["/usr/bin/ditto", "-xk", archive, stage], timeout=180)
            source = stage / "chrome-mac" / "Chromium.app"
            if not (source / "Contents/MacOS/Chromium").is_file():
                raise WorkspaceError("The archive does not contain the expected Chromium application.")
            # Chromium's raw development snapshot is not a notarized release
            # and has no complete bundle resource seal. Record that fact. Do
            # not re-sign it or change Gatekeeper, SIP, or browser sandboxing.
            signature = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)],
                                       capture_output=True, text=True, timeout=120)
            signing_info = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(source / "Contents/MacOS/Chromium")],
                                         capture_output=True, text=True, timeout=30)
            shutil.move(str(source), self.app)
        finally:
            shutil.rmtree(stage)
        version = plistlib.loads((self.app / "Contents/Info.plist").read_bytes()).get("CFBundleShortVersionString")
        provenance = {"revision": REVISION, "version": version, "archive_sha256": digest,
                      "download_url": DOWNLOAD_URL, "installed_at": time.time(),
                      "development_snapshot": True, "bundle_signature_valid": signature.returncode == 0,
                      "bundle_signature_diagnostic": signature.stderr.strip(),
                      "executable_signing_info": signing_info.stderr.strip()}
        write_json(self.mount / "Data" / "browser-installation.json", provenance)
        # Preferences exist before first run; do not rewrite them on later runs.
        prefpath = self.profile / "Default" / "Preferences"
        if not prefpath.exists():
            write_json(prefpath, {"download": {"default_directory": str(self.mount / "Downloads"),
                                                "prompt_for_download": False, "directory_upgrade": True},
                                  "savefile": {"default_directory": str(self.mount / "Downloads")},
                                  "browser": {"check_default_browser": False},
                                  "credentials_enable_service": False,
                                  "profile": {"password_manager_enabled": False}})
        return {"installed": True, "path": str(self.app), **provenance}

    def environment(self):
        env = os.environ.copy()
        # HOME alone does not virtualize Foundation's home-directory APIs.
        values = {"HOME": self.mount / "Home", "CFFIXED_USER_HOME": self.mount / "Home",
                  "TMPDIR": self.mount / "Temp", "TMP": self.mount / "Temp", "TEMP": self.mount / "Temp",
                  "MAC_CHROMIUM_TMPDIR": self.mount / "Temp",
                  "XDG_CONFIG_HOME": self.mount / "Home/.config", "XDG_CACHE_HOME": self.mount / "Cache",
                  "XDG_DATA_HOME": self.mount / "Home/.local/share", "CHROME_LOG_FILE": self.mount / "Logs/chromium.log"}
        env.update({k: str(v) + ("/" if k == "TMPDIR" else "") for k, v in values.items()})
        # This private compatibility switch did not confine Chromium preferences
        # on macOS 27. Keep it opt-in for reproducible research only.
        if os.environ.get("WORKSPACE_TEST_DIRECT_PREFERENCES") == "1":
            env["__CFPREFERENCES_AVOID_DAEMON"] = "1"
        else:
            env.pop("__CFPREFERENCES_AVOID_DAEMON", None)
        # Never inherit an unrelated runtime-injection or browser profile override.
        for key in list(env):
            if key.startswith("DYLD_") or key in {"CHROME_USER_DATA_DIR", "CHROME_CONFIG_HOME"}:
                del env[key]
        return env

    def launch(self, url="about:blank", *, audit_port=None, restrict_writes=False):
        self.require_mounted()
        if not self.binary.exists():
            raise WorkspaceError("Install Chromium into the workspace first.")
        if self.active_processes():
            raise WorkspaceError("The workspace browser is already running.")
        flags = [f"--user-data-dir={self.profile}", f"--disk-cache-dir={self.mount / 'Cache/Chromium'}",
                 f"--crash-dumps-dir={self.profile / 'Crashpad'}", "--no-first-run", "--no-default-browser-check",
                 "--disable-background-mode", "--disable-background-networking", "--disable-component-update",
                 "--disable-sync", "--metrics-recording-only", "--disable-breakpad",
                 "--disable-session-crashed-bubble", "--disable-metal-shader-cache", "--disable-gpu", "--window-size=1180,840",
                 # Research mode: never use the user's real Keychain. Cookie
                 # storage relies on the outer encrypted volume, not this
                 # deterministic test key. Do not use for real accounts.
                 "--use-mock-keychain"]
        if audit_port is not None:
            # Automation only. Normal launches expose no debugging endpoint.
            flags.extend([f"--remote-debugging-port={int(audit_port)}", "--remote-debugging-address=127.0.0.1"])
        flags.append(url)
        command = [str(self.binary), *flags]
        if restrict_writes:
            # Research-only negative experiment. On this macOS build an outer
            # Seatbelt policy prevents Chromium's helper sandboxes from
            # initializing. Never enable this in the usable launcher, and
            # never compensate by disabling Chromium's own sandbox.
            policy = ("(version 1)\n(allow default)\n(deny file-write*)\n"
                      f"(allow file-write* (subpath {json.dumps(str(self.mount))}))\n"
                      "(allow file-write* (literal \"/dev/null\"))\n"
                      "(deny user-preference-write)\n")
            policy_path = self.mount / "Run/write-policy.sb"
            policy_path.write_text(policy)
            os.chmod(policy_path, 0o600)
            command = ["/usr/bin/sandbox-exec", "-f", str(policy_path), *command]
        environment = self.environment()
        trace_preferences = os.environ.get("WORKSPACE_TRACE_PREFERENCES") == "1"
        if trace_preferences:
            # Instrumentation only, on a fresh synthetic verification workspace.
            # Normal launches inherit no injection variables or runtime shim.
            if not self.folder.name.startswith("Verification-"):
                raise WorkspaceError("Preference tracing is restricted to disposable Verification workspaces.")
            trace_library = self.mount / "Run/trace-preferences.dylib"
            shutil.copyfile(ROOT / "build/trace-preferences.dylib", trace_library)
            environment["DYLD_INSERT_LIBRARIES"] = str(trace_library)
            environment["NOCT_PREF_TRACE_FILE"] = str(self.mount / "Logs/preferences-trace.log")
        with (self.mount / "Logs" / "browser-stderr.log").open("ab", buffering=0) as log:
            process = subprocess.Popen(command, cwd=self.mount,
                                       env=environment, stdout=log, stderr=log,
                                       stdin=subprocess.DEVNULL, start_new_session=True)
        time.sleep(1)
        if process.poll() is not None:
            raise WorkspaceError("Chromium exited during launch; inspect Logs/browser-stderr.log inside the vault.")
        write_json(self.mount / "Run" / "browser.json", {"pid": process.pid, "started_at": time.time(),
                                                        "arguments": flags, "write_policy": restrict_writes,
                                                        "environment": {
                                                            k: self.environment()[k] for k in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "MAC_CHROMIUM_TMPDIR"]},
                                                        "direct_preferences_experiment": self.environment().get("__CFPREFERENCES_AVOID_DAEMON") == "1",
                                                        "preference_trace_instrumentation": trace_preferences})
        return {"pid": process.pid, "profile": str(self.profile), "debugging_enabled": audit_port is not None}

    def active_processes(self):
        table = process_table()
        prefixes = (str(self.app) + "/", str(self.webkit_app) + "/")
        # App path rather than process name: never touch the user's normal Chrome.
        return {pid: row for pid, row in table.items() if row["command"].startswith(prefixes)}

    @property
    def webkit_app(self):
        return self.mount / "Applications/Noct Browser.app"

    @property
    def webkit_binary(self):
        return self.webkit_app / "Contents/MacOS/NoctBrowser"

    @property
    def webkit_bundle_id(self):
        return "local.noctdesktop.browser." + self.config()["short_mount_id"]

    def webkit_redirects(self):
        """App-specific macOS scratch links. Never redirect shared OS roots."""
        result = []
        for kind, variable in [("Cache", "DARWIN_USER_CACHE_DIR"), ("Temp", "DARWIN_USER_TEMP_DIR")]:
            parent = Path(run(["/usr/bin/getconf", variable]).decode().strip()).resolve()
            if parent.stat().st_uid != os.getuid():
                raise WorkspaceError("The macOS scratch directory belongs to another user.")
            for name in [self.webkit_bundle_id, *[f"com.apple.WebKit.{p}+{self.webkit_bundle_id}" for p in ["GPU", "Networking", "WebContent"]]]:
                result.append((parent / name, self.mount / f"Apps/NoctBrowser/{kind}/System/{name}"))
        return result

    def prepare_webkit_paths(self):
        self.require_mounted()
        for link, target in self.webkit_redirects():
            if target.is_symlink() or not target.resolve().is_relative_to(self.mount):
                raise WorkspaceError("A browser scratch target escapes the encrypted workspace.")
            target.mkdir(parents=True, exist_ok=True, mode=0o700)
            if link.is_symlink():
                if os.readlink(link) != str(target):
                    raise WorkspaceError("A browser scratch link points at another location.")
            elif link.exists():
                raise WorkspaceError(f"The dedicated browser scratch path already exists; no files were replaced: {link}")
            else:
                link.symlink_to(target, target_is_directory=True)
        return [{"host_link": str(link), "encrypted_target": str(target)} for link, target in self.webkit_redirects()]

    def install_webkit(self):
        self.require_mounted()
        if self.active_processes():
            raise WorkspaceError("Close workspace browsers before installing.")
        source = ROOT / "build/Noct Browser.app"
        if not (source / "Contents/MacOS/NoctBrowser").is_file():
            raise WorkspaceError("Build Noct Browser with tools/build.py first.")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", source])
        if self.webkit_app.is_symlink():
            raise WorkspaceError("The browser installation must not be a symbolic link.")
        if self.webkit_app.exists():
            old = self.webkit_binary.read_bytes()
            old_info = plistlib.loads((self.webkit_app / "Contents/Info.plist").read_bytes())
            if (hashlib.sha256(old).digest() == hashlib.sha256((source / "Contents/MacOS/NoctBrowser").read_bytes()).digest()
                    and old_info.get("CFBundleIdentifier") == self.webkit_bundle_id):
                self.prepare_webkit_paths()
                return {"installed": True, "already_present": True, "path": str(self.webkit_app)}
            # Installation changes only this generated executable bundle.
            shutil.rmtree(self.webkit_app)
        shutil.copytree(source, self.webkit_app)
        info_path = self.webkit_app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = self.webkit_bundle_id
        info_path.write_bytes(plistlib.dumps(info))
        # Our own generated development app; never re-sign third-party apps.
        run(["/usr/bin/codesign", "--force", "--sign", "-", self.webkit_app])
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", self.webkit_app])
        redirects = self.prepare_webkit_paths()
        return {"installed": True, "path": str(self.webkit_app), "engine": "System WebKit", "bundle_id": self.webkit_bundle_id, "scratch_redirects": redirects}

    def launch_webkit(self, url=None, *, audit=False):
        self.require_mounted()
        if not self.webkit_binary.is_file():
            raise WorkspaceError("Install Noct Browser into the workspace first.")
        if self.active_processes():
            raise WorkspaceError("A workspace browser is already running.")
        self.prepare_webkit_paths()
        base = self.mount / "Apps/NoctBrowser"
        for name in ["Settings", "Home/Library/Caches", "Home/Library/Preferences", "Cache", "Temp", "Logs"]:
            directory = base / name
            if directory.is_symlink() or not directory.resolve().is_relative_to(self.mount):
                raise WorkspaceError("A browser storage directory escapes the workspace.")
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        runtime = self.mount / "Run/NoctBrowser"
        runtime.mkdir(mode=0o700, exist_ok=True)
        environment = self.environment()
        environment.update({"HOME": str(base / "Home"), "CFFIXED_USER_HOME": str(base / "Home"),
                            "TMPDIR": str(base / "Temp") + "/", "TMP": str(base / "Temp"), "TEMP": str(base / "Temp"),
                            "XDG_CACHE_HOME": str(base / "Cache"), "NOCT_WORKSPACE_ROOT": str(self.mount),
                            "NOCT_WORKSPACE_ID": self.config()["id"]})
        for key in ["NOCT_BROWSER_AUDIT", "NOCT_BROWSER_URL", "NOCT_PREF_TRACE_FILE"]:
            environment.pop(key, None)
        if url:
            from urllib.parse import urlsplit
            parsed = urlsplit(url)
            if parsed.scheme not in {"https", "http", "about"}:
                raise WorkspaceError("Noct Browser accepts HTTP/HTTPS addresses.")
            environment["NOCT_BROWSER_URL"] = url
        if audit:
            from urllib.parse import urlsplit
            if not self.folder.name.startswith("WebKitVerification-") or not url or urlsplit(url).hostname != "127.0.0.1":
                raise WorkspaceError("Audit mode is restricted to synthetic WebKitVerification loopback fixtures.")
            environment["NOCT_BROWSER_AUDIT"] = "1"
            (runtime / "audit-enabled").touch(mode=0o600)
        else:
            (runtime / "audit-enabled").unlink(missing_ok=True)
        for name in ["ready.json", "request.json", "response.json"]:
            (runtime / name).unlink(missing_ok=True)
        # LaunchServices establishes this app as its WebKit helpers' responsible
        # process. Supply only deliberate context; do not copy arbitrary secrets
        # into an open command line or a helper's environment.
        log = base / "Logs/browser.log"
        log.touch(mode=0o600, exist_ok=True)
        command = ["/usr/bin/open", "-n", "-W", "--stdout", str(log), "--stderr", str(log)]
        for key in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "TMP", "TEMP", "XDG_CACHE_HOME", "NOCT_WORKSPACE_ROOT", "NOCT_WORKSPACE_ID", "NOCT_BROWSER_URL", "NOCT_BROWSER_AUDIT"]:
            if key in environment:
                command.extend(["--env", key + "=" + environment[key]])
        command.append(str(self.webkit_app))
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 12
        browser_pid = None
        while time.monotonic() < deadline:
            browser_pid = next((pid for pid, row in self.active_processes().items() if row["command"] == str(self.webkit_binary)), None)
            if browser_pid or process.poll() is not None:
                break
            time.sleep(0.15)
        if browser_pid is None:
            raise WorkspaceError("Noct Browser did not start. Inspect Apps/NoctBrowser/Logs/browser.log in the vault.")
        write_json(runtime / "process.json", {"pid": browser_pid, "opener_pid": process.pid, "started_at": time.time(), "engine": "WebKit",
                                             "persistent_website_data": False, "audit": audit})
        return {"pid": browser_pid, "engine": "WebKit", "persistent_website_data": False, "audit": audit}

    def user_path(self, relative):
        """Resolve only the desktop's user-file trees, never a host fallback."""
        self.require_mounted()
        relative = Path(relative)
        if relative.is_absolute() or ".." in relative.parts:
            raise WorkspaceError("The file path must stay inside the workspace.")
        candidate = self.mount / relative
        allowed = [self.mount / p for p in ["Home/Desktop", "Home/Documents", "Downloads"]]
        # Reject symlinks at every level, including a user folder itself. A
        # dangling symlink is rejected too. Imported files cannot create links.
        current = self.mount
        for part in relative.parts:
            current = current / part
            if current.is_symlink():
                raise WorkspaceError("Symbolic links cannot be opened by workspace Files.")
        resolved = candidate.resolve()
        if not any(resolved == root or root in resolved.parents for root in allowed):
            raise WorkspaceError("Choose Desktop, Documents, or Downloads.")
        return candidate

    def desktop_command(self, request):
        self.require_mounted()
        action = request.get("action", "list")
        layout_path = self.mount / "Data/Desktop/layout.json"
        if action == "layout":
            if "positions" in request:
                positions = request["positions"]
                if not isinstance(positions, dict) or set(positions) - {"browser", "chromium", "files", "documents", "downloads"}:
                    raise WorkspaceError("Invalid desktop layout.")
                for position in positions.values():
                    if (not isinstance(position, list) or len(position) != 2 or
                        not all(isinstance(n, (int, float)) and 0 <= n <= 10000 for n in position)):
                        raise WorkspaceError("Invalid icon position.")
                write_json(layout_path, positions)
            return {"positions": json.loads(layout_path.read_text()) if layout_path.exists() else {}}
        folder = self.user_path(request.get("folder", "Home/Desktop"))
        if not folder.is_dir():
            raise WorkspaceError("This workspace folder is unavailable.")
        if action == "mkdir":
            name = request.get("name", "")
            if not isinstance(name, str) or not name.strip() or name in {".", ".."} or "/" in name or "\x00" in name:
                raise WorkspaceError("Enter a folder name without slashes.")
            (folder / name).mkdir(mode=0o700)
        elif action == "import":
            sources = request.get("sources", [])
            if not isinstance(sources, list) or not sources or len(sources) > 100:
                raise WorkspaceError("Choose between 1 and 100 files.")
            # Preflight the whole selection. Never replace existing user files.
            pairs = []
            for source in sources:
                source = Path(source)
                if not source.is_absolute() or source.is_symlink() or not source.is_file():
                    raise WorkspaceError("Import accepts regular files, without symbolic links.")
                destination = folder / source.name
                if destination.exists() or destination.is_symlink() or any(destination == d for _, d in pairs):
                    raise WorkspaceError(f"A file named {source.name} already exists in this folder.")
                pairs.append((source, destination))
            for source, destination in pairs:
                # Exclusive creation avoids accidental overwrites. A failed copy
                # leaves no partial destination. The source remains untouched.
                created = False
                try:
                    with source.open("rb") as src, destination.open("xb") as dst:
                        created = True
                        os.chmod(destination, 0o600)
                        shutil.copyfileobj(src, dst)
                except Exception:
                    if created and destination.is_file():
                        destination.unlink()
                    raise
        elif action != "list":
            raise WorkspaceError("Unknown desktop operation.")
        entries = []
        for child in sorted(folder.iterdir(), key=lambda p: (not p.is_dir(), p.name.casefold())):
            if child.name.startswith("."):
                continue
            info = child.lstat()
            entries.append({"name": child.name, "path": str(child.relative_to(self.mount)),
                            "kind": "link" if child.is_symlink() else "folder" if child.is_dir() else "file",
                            "size": info.st_size})
        return {"folder": str(folder.relative_to(self.mount)), "entries": entries}

    def lock(self):
        if not self.attached():
            return {"state": "locked", "mounted": False}
        self.require_mounted()
        # Signal only binaries installed in this exact workspace. Chromium uses
        # SIGTERM for orderly shutdown. Do not force-kill or force-unmount.
        processes = self.active_processes()
        browser_pids = [pid for pid, row in processes.items() if row["command"].startswith(str(self.binary) + " ")
                        or row["command"] == str(self.webkit_binary)]
        for pid in browser_pids:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 15
        while self.active_processes() and time.monotonic() < deadline:
            time.sleep(0.2)
        remaining = self.active_processes()
        if remaining:
            raise WorkspaceError("Lock incomplete: workspace processes are still running. Storage remains unlocked.")
        # Eject this volume only. Disk Arbitration refuses if another process
        # still holds it busy; failure is surfaced rather than called 'locked'.
        run(["/usr/bin/hdiutil", "detach", self.mount], timeout=45)
        if self.attached() or os.path.ismount(self.mount):
            raise WorkspaceError("Lock incomplete: the image is still attached.")
        return {"state": "locked", "mounted": False}

    def status(self):
        if not self.metadata.exists():
            return {"state": "not_created", "folder": str(self.folder)}
        mounted = self.attached() is not None
        valid = False
        if mounted:
            self.require_mounted()
            valid = True
        return {"state": "unlocked" if valid else "locked", "mounted": mounted,
                "installed": self.binary.exists() if valid else None,
                "webkit_installed": self.webkit_binary.exists() if valid else None,
                "webkit_processes": [pid for pid, row in self.active_processes().items()
                                     if row["command"] == str(self.webkit_binary)] if valid else [],
                "browser_processes": list(self.active_processes()) if valid else [],
                "folder": str(self.folder), "mount": str(self.mount), "image": str(self.image)}


def read_password(stdin=False, *, confirm=False):
    if stdin:
        return sys.stdin.buffer.readline().rstrip(b"\r\n")
    first = getpass.getpass("Workspace password: ").encode()
    if confirm and first != getpass.getpass("Confirm password: ").encode():
        raise WorkspaceError("Passwords do not match.")
    return first


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=ROOT / "workspaces" / "Personal")
    parser.add_argument("--password-stdin", action="store_true", help="Receive the password through a private stdin pipe.")
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ["create", "unlock", "lock", "status"]:
        sub.add_parser(name)
    sub.add_parser("install-webkit")
    webkit = sub.add_parser("launch-webkit")
    webkit.add_argument("--url")
    install = sub.add_parser("install")
    install.add_argument("--archive", type=Path, default=ARCHIVE)
    launch = sub.add_parser("launch")
    launch.add_argument("--url", default="about:blank")
    sub.add_parser("desktop", help="Exchange desktop file commands over a private JSON stdin pipe.")
    args = parser.parse_args()
    workspace = Workspace(args.workspace)
    try:
        with workspace.exclusive():
            if args.action == "create":
                workspace.create(read_password(args.password_stdin, confirm=True))
                result = workspace.status()
            elif args.action == "unlock":
                result = workspace.unlock(read_password(args.password_stdin))
            elif args.action == "install":
                result = workspace.install(args.archive)
            elif args.action == "install-webkit":
                result = workspace.install_webkit()
            elif args.action == "launch-webkit":
                result = workspace.launch_webkit(args.url)
            elif args.action == "launch":
                result = workspace.launch(args.url)
            elif args.action == "lock":
                result = workspace.lock()
            elif args.action == "desktop":
                request = json.load(sys.stdin)
                if not isinstance(request, dict):
                    raise WorkspaceError("A desktop request must be an object.")
                result = workspace.desktop_command(request)
            else:
                result = workspace.status()
        print(json.dumps(result, indent=2))
    except (WorkspaceError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
