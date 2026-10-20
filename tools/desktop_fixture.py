#!/usr/bin/env python3
"""Disposable encrypted desktop for visual and interaction verification.

Never opens or modifies Personal. The generated passphrase stays in this process.
Type finish only after closing the app; the fixture then records evidence and
removes its own disposable image after a verified detach.
"""
from pathlib import Path
import json
import os
import secrets
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from workspace import Workspace, WorkspaceError, write_json

runid = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
ws = Workspace(ROOT / "workspaces" / ("DesktopVerification-" + runid))
evidence = ROOT / "evidence" / ("desktop-" + runid)
evidence.mkdir(parents=True, mode=0o700)
secret = secrets.token_urlsafe(40).encode()
created_id = None
app = None
report = {"workspace": str(ws.folder), "synthetic": True, "checks": {}}
try:
    with ws.exclusive():
        ws.create(secret); created_id = ws.config()["id"]
        ws.unlock(secret); ws.install()
        source = evidence / "sample-note.txt"
        source.write_text("Synthetic workspace desktop verification.\n")
        result = ws.desktop_command({"action": "import", "folder": "Home/Documents", "sources": [str(source)]})
        report["checks"]["imported_file_inside_encrypted_volume"] = any(e["name"] == source.name for e in result["entries"])
        report["checks"]["import_preserves_source"] = source.read_text() == (ws.mount / "Home/Documents/sample-note.txt").read_text()
        try:
            ws.desktop_command({"action": "import", "folder": "Home/Documents", "sources": [str(source)]})
            report["checks"]["import_refuses_overwrite"] = False
        except WorkspaceError:
            report["checks"]["import_refuses_overwrite"] = (ws.mount / "Home/Documents/sample-note.txt").read_text() == source.read_text()
        try:
            ws.desktop_command({"folder": "../../Library"})
            report["checks"]["path_traversal_rejected"] = False
        except WorkspaceError:
            report["checks"]["path_traversal_rejected"] = True
        link = ws.mount / "Home/Desktop/host-link"
        link.symlink_to(Path.home())
        try:
            ws.desktop_command({"folder": "Home/Desktop/host-link"})
            report["checks"]["symlink_escape_rejected"] = False
        except WorkspaceError:
            report["checks"]["symlink_escape_rejected"] = True
        finally:
            link.unlink()
    env = os.environ.copy(); env["NOCT_DESKTOP_WORKSPACE"] = str(ws.folder)
    app = subprocess.Popen([str(ROOT / "build/Noct Desktop.app/Contents/MacOS/NoctDesktop")],
                           env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("READY: disposable desktop opened. Inspect Files, create Ideas on Desktop, move an icon, launch Chromium, lock, then quit. Type finish.", flush=True)
    print("Evidence: " + str(evidence), flush=True)
    while True:
        command = sys.stdin.readline().strip()
        if command == "finish": break
        if command == "unlock":
            with ws.exclusive(): ws.unlock(secret)
            print("UNLOCKED: verify that saved icon positions reload, then lock and quit.", flush=True)
        else: raise RuntimeError("Expected unlock or finish.")
    app.wait(timeout=10)
    report["checks"]["gui_quit_finished"] = app.returncode == 0
    report["checks"]["gui_locked_volume"] = ws.status()["state"] == "locked" and ws.attached() is None
    report["checks"]["desktop_files_unavailable_when_locked"] = not (ws.mount / "Home/Desktop").exists()
    try:
        ws.desktop_command({"folder": "Home/Documents"})
        report["checks"]["file_commands_rejected_when_locked"] = False
    except WorkspaceError:
        report["checks"]["file_commands_rejected_when_locked"] = True
    with ws.exclusive():
        ws.unlock(secret)
        report["checks"]["gui_created_folder_persisted"] = (ws.mount / "Home/Desktop/Ideas").is_dir()
        report["layout"] = ws.desktop_command({"action": "layout"})["positions"]
        report["checks"]["icon_position_persisted_inside_vault"] = bool(report["layout"])
        ws.lock()
except Exception as error:
    report["error"] = str(error)
    raise
finally:
    if app is not None and app.poll() is None:
        print("App remains open. Close it before removing the fixture.", flush=True)
    else:
        if created_id is not None:
            with ws.exclusive():
                ws.lock()
                if ws.config()["id"] != created_id or ws.attached() or ws.image.is_symlink():
                    raise RuntimeError("Fixture identity changed; no cleanup performed.")
                mount = ws.mount
                shutil.rmtree(ws.image)
                ws.metadata.unlink()
                if mount.is_dir() and not any(mount.iterdir()): mount.rmdir()
            report["disposable_image_removed"] = True
    secret = b""
    report["all_checks_passed"] = all(report["checks"].values()) and "error" not in report
    write_json(evidence / "report.json", report)
    print(json.dumps(report, indent=2), flush=True)
