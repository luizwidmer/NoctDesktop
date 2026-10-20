#!/usr/bin/env python3
"""Keep a disposable FreeBSD vault's password only in this process's memory."""
import json
import os
from pathlib import Path
import secrets
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from freebsd_vm import FreeBSDWorkspace, ROOT, disk_guard
from workspace import write_json

os.umask(0o077)
identifier = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
ws = FreeBSDWorkspace(ROOT / "workspaces" / ("FreeBSDVerification-" + identifier))
password = secrets.token_urlsafe(48).encode()
evidence = ROOT / "evidence" / ("freebsd-" + identifier)
evidence.mkdir(parents=True)
write_json(ROOT / "evidence/latest-freebsd.json", {"workspace": str(ws.folder), "evidence": str(evidence)})
print("WORKSPACE", ws.folder, flush=True)
print("EVIDENCE", evidence, flush=True)
try:
    ws.create(password); ws.unlock(password)
    start = time.monotonic(); installation = ws.install_vm()
    write_json(evidence / "installation.json", {**installation, "setup_seconds": time.monotonic() - start})
    print("LAUNCH", json.dumps(ws.launch_vm()), flush=True)
    print("READY: commands status, unlock, start, stop, lock, finish", flush=True)
    for line in sys.stdin:
        action = line.strip()
        try:
            if action == "status": result = ws.status()
            elif action == "unlock": result = ws.unlock(password)
            elif action == "start": result = ws.launch_vm()
            elif action == "stop": result = ws.stop_vm()
            elif action == "lock": result = ws.lock()
            elif action == "finish":
                print(json.dumps(ws.lock()), flush=True); break
            else: result = {"error": "Unknown fixture command"}
            print(json.dumps(result), flush=True)
        except Exception as error: print("ERROR", str(error), flush=True)
finally:
    try: print("FINAL_LOCK", json.dumps(ws.lock()), flush=True)
    except Exception as error: print("LOCK_FAILED", str(error), flush=True)
    password = b""
