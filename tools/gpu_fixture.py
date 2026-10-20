#!/usr/bin/env python3
"""Disposable browser-GPU guest; the vault password stays only in this process.

The 12 GiB volume and 9 GiB guest disk are sparse capacities. The same host
15 GiB free-space floor applies. Existing user workspaces are not modified.
"""
import json
import os
from pathlib import Path
import secrets
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from freebsd_vm import FreeBSDWorkspace, ROOT
from workspace import write_json

os.umask(0o077)
identifier=time.strftime("%Y%m%d-%H%M%S",time.gmtime())
w=FreeBSDWorkspace(ROOT/"workspaces"/("BrowserGPUVerification-"+identifier))
e=ROOT/"evidence"/("browser-gpu-"+identifier);e.mkdir(parents=True)
write_json(ROOT/"evidence/latest-browser-gpu.json",{"workspace":str(w.folder),"evidence":str(e)})
password=secrets.token_urlsafe(48).encode()
print("WORKSPACE",w.folder,flush=True);print("EVIDENCE",e,flush=True)
try:
    w.create(password,size="12g",disk_mib=9216);w.unlock(password)
    start=time.monotonic();w.setup_vm()
    write_json(e/"setup.json",{"seconds":time.monotonic()-start,"status":w.status()})
    print("READY: status, unlock, lock, finish",flush=True)
    for line in sys.stdin:
        action=line.strip()
        try:
            if action=="status":r=w.status()
            elif action=="unlock":r=w.unlock(password)
            elif action=="lock":r=w.lock()
            elif action=="finish":print(json.dumps(w.lock()),flush=True);break
            else:r={"error":"Unknown command"}
            print(json.dumps(r),flush=True)
        except Exception as error:print("ERROR",str(error),flush=True)
finally:
    try:print("FINAL_LOCK",json.dumps(w.lock()),flush=True)
    except Exception as error:print("LOCK_FAILED",str(error),flush=True)
    password=b""
