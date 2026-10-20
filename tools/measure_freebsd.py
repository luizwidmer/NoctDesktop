#!/usr/bin/env python3
"""Measure a configured synthetic workspace. Does not create or unlock a vault.

Close the GUI before boot measurements: guest exit intentionally triggers its
automatic lock. Output can contain local paths; evidence is excluded from Git.
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from freebsd_vm import FreeBSDWorkspace, disk_guard


def capture(ws):
    pid = next(iter(ws.vm_processes()))
    host = subprocess.check_output(["ps", "-p", str(pid), "-o", "rss=,time=,%cpu="], text=True).strip()
    guest = ws.ssh("sysctl hw.pagesize hw.physmem vm.stats.vm.v_page_count vm.stats.vm.v_free_count vm.stats.vm.v_inactive_count vm.stats.vm.v_wire_count vm.stats.vm.v_active_count; swapinfo -k; ps -axo pid,user,rss,time,comm").stdout.decode()
    return {"host_qemu_rss_kib_cpu_time_percent": host, "guest": guest, "host_free_bytes": disk_guard()}


def boot(ws, runs):
    values = []
    for i in range(runs):
        shutdown = ws.stop_vm()
        epoch = time.time(); start = time.monotonic(); ws.launch_vm(); ws.wait_ready()
        ssh_time = time.monotonic() - start
        ready = "from pathlib import Path; import sys; p=Path('/home/noct/.run/desktop-ready'); sys.exit(0 if p.exists() and p.stat().st_mtime > " + str(epoch) + " else 1)"
        while time.monotonic() - start < 90:
            if ws.ssh("/usr/local/bin/python3.12 -c " + __import__('shlex').quote(ready), check=False).returncode == 0: break
            time.sleep(.25)
        else: raise RuntimeError("Desktop did not become ready")
        row = {"run": i+1, "launch_to_ssh_seconds": ssh_time, "launch_to_desktop_seconds": time.monotonic()-start,
               "preceding_shutdown": shutdown, "snapshot": capture(ws)}
        values.append(row); print(json.dumps({k:v for k,v in row.items() if k != "snapshot"}), flush=True)
    return {"boot_runs": values, "desktop_median_seconds": statistics.median(x["launch_to_desktop_seconds"] for x in values)}


def browser(ws):
    existing = ws.ssh("pgrep -f '^/usr/local/bin/python3.12 /opt/noct/noct.py (--benchmark|--app (browser|web-))'",check=False)
    if existing.returncode == 0: raise RuntimeError("Close other guest browser windows before this measurement")
    cleanup = "from pathlib import Path; p=Path('/home/noct/Workspace/Downloads/noct-test.bin'); assert not p.exists() or p.open('rb').read(24).startswith(b'NOCT_SYNTHETIC_DOWNLOAD'); p.unlink(missing_ok=True)"
    ws.ssh("/usr/local/bin/python3.12 -c "+__import__('shlex').quote(cleanup))
    # Restart only our own loopback workload, so a repeated test uses its current source.
    server_cleanup = """from pathlib import Path
import os,signal,subprocess,time
p=Path('/home/noct/.run/benchmark-server.pid')
if p.exists():
    pid=int(p.read_text())
    r=subprocess.run(['ps','-ww','-p',str(pid),'-o','args='],capture_output=True,text=True)
    if r.returncode==0:
        assert r.stdout.strip()=='/usr/local/bin/python3.12 /opt/noct/benchmark.py', 'Benchmark PID was reused; refusing to stop it'
        os.kill(pid,signal.SIGTERM);time.sleep(.3)
    p.unlink(missing_ok=True)
"""
    ws.ssh("/usr/local/bin/python3.12 -c "+__import__('shlex').quote(server_cleanup))
    command = """su -l noct -c 'export DISPLAY=:0 XAUTHORITY=/home/noct/.Xauthority TMPDIR=/home/noct/.tmp XDG_RUNTIME_DIR=/home/noct/.run XDG_CONFIG_HOME=/home/noct/.config XDG_CACHE_HOME=/home/noct/.cache XDG_DATA_HOME=/home/noct/.local/share; rm -f /home/noct/.run/browser-benchmark.json /home/noct/.run/browser-load.json; /usr/sbin/daemon -f -p /home/noct/.run/benchmark-server.pid -o /home/noct/Workspace/Logs/benchmark-server.log /usr/local/bin/python3.12 /opt/noct/benchmark.py; /usr/sbin/daemon -f -p /home/noct/.run/benchmark-browser.pid -o /home/noct/Workspace/Logs/benchmark-browser.log /usr/local/bin/python3.12 /opt/noct/noct.py --benchmark http://127.0.0.1:8765/'"""
    start = time.monotonic(); ws.ssh(command)
    load_time = None
    while time.monotonic() - start < 90:
        result = ws.ssh("cat /home/noct/.run/browser-load.json /home/noct/.run/browser-benchmark.json 2>/dev/null", check=False).stdout.decode()
        if load_time is None and '"load_seconds"' in result: load_time = time.monotonic()-start
        if '"js_samples_ms"' in result: break
        time.sleep(.25)
    else: raise RuntimeError("Browser benchmark did not complete: " + result[-500:])
    # Separate reads make each JSON object independently parseable.
    benchmark = json.loads(ws.ssh("cat /home/noct/.run/browser-benchmark.json").stdout)
    load = json.loads(ws.ssh("cat /home/noct/.run/browser-load.json").stdout)
    for _ in range(30):
        size = ws.ssh("stat -f %z /home/noct/Workspace/Downloads/noct-test.bin", check=False).stdout.strip()
        if size == b"8388608": break
        time.sleep(.2)
    return {"browser": benchmark, "load": load, "host_launch_to_observed_load_seconds_upper_bound": load_time,
            "download_bytes": int(size or b"0"), "snapshot": capture(ws)}


def main():
    p=argparse.ArgumentParser(); p.add_argument("--workspace", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path); p.add_argument("action", choices=["boot", "browser", "snapshot"])
    p.add_argument("--runs", type=int, default=3); a=p.parse_args(); w=FreeBSDWorkspace(a.workspace)
    w.require_mounted(); result = boot(w,a.runs) if a.action == "boot" else browser(w) if a.action == "browser" else capture(w)
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(result,indent=2)+"\n")
    print("Saved", a.output, flush=True)


if __name__ == "__main__": main()
