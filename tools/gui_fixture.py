#!/usr/bin/env python3
"""Temporary empty synthetic volume for checking the launcher's visible lock state.

Refuses an existing personal workspace. Keeps the password in this process and
removes only the exact synthetic image/metadata that it created, after detaching.
"""
from pathlib import Path
import json
import secrets
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from workspace import Workspace, write_json

ws = Workspace(ROOT / "workspaces/Personal")
if ws.metadata.exists() or ws.image.exists():
    raise SystemExit("An existing personal workspace is present. No fixture was created.")
secret = secrets.token_urlsafe(40).encode()
created_id = None
try:
    with ws.exclusive():
        ws.create(secret)
        created_id = ws.config()["id"]
        ws.unlock(secret)
    print("READY: empty synthetic workspace is unlocked. Check GUI, click Lock workspace, then enter finish here.", flush=True)
    if sys.stdin.readline().strip() != "finish":
        raise RuntimeError("Fixture expected finish; attempting cleanup.")
    result = ws.status()
    write_json(ROOT / "evidence/gui-lock-check.json", {"observed_at": time.time(),
        "workspace": str(ws.folder), "state_after_gui_lock": result["state"],
        "unmounted_after_gui_lock": not result["mounted"], "synthetic": True})
finally:
    secret = b""
    if created_id is not None:
        with ws.exclusive():
            ws.lock()
            if ws.config()["id"] != created_id or ws.attached():
                raise RuntimeError("Unexpected fixture identity/state. No files were removed.")
            mount = ws.mount
            if ws.image.is_symlink() or not ws.image.is_dir():
                raise RuntimeError("Unexpected synthetic image path. No files were removed.")
            shutil.rmtree(ws.image)
            ws.metadata.unlink()
            if mount.is_dir() and not any(mount.iterdir()): mount.rmdir()
        print("Synthetic fixture removed; the launcher is ready to create a fresh workspace.", flush=True)
