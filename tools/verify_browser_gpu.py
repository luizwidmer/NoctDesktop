#!/usr/bin/env python3
"""Verify the real browser render path in an unlocked synthetic Noct guest.

Close other browser windows first. This opens a local shader/pixel workload.
These focused WebGL 2/text checks are not graphics conformance, video decode,
or an end-to-end display FPS measurement. Python is verification tooling only.
"""
import argparse
import json
from pathlib import Path
import shlex
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from freebsd_vm import FreeBSDWorkspace
from verify_freebsd import writable_files


def verify(ws):
    ws.require_mounted(); ws.verify_gpu_runtime()
    if ws.config().get("graphics") != "virgl-metal":
        raise RuntimeError("Enable the experimental browser GPU backend first")
    existing = ws.ssh("pgrep -f '^/opt/noct/bin/noct-desktop (--benchmark|--app (browser|web-))'", check=False)
    if existing.returncode == 0:
        raise RuntimeError("Close other guest browser windows before this verification")
    env = "export DISPLAY=:0 XAUTHORITY=/home/noct/.Xauthority TMPDIR=/home/noct/.tmp XDG_RUNTIME_DIR=/home/noct/.run XDG_CONFIG_HOME=/home/noct/.config XDG_CACHE_HOME=/home/noct/.cache XDG_DATA_HOME=/home/noct/.local/share; "
    launch = env + "rm -f /home/noct/.run/browser-load.json /home/noct/.run/browser-benchmark.json; /usr/sbin/daemon -f -p /home/noct/.run/browser-gpu-check.pid -o /home/noct/Workspace/Logs/browser-gpu-check.log /opt/noct/bin/noct-desktop --benchmark file:///opt/noct/gpu-benchmark.html"
    ws.ssh("su -l noct -c " + shlex.quote(launch))
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        raw = ws.ssh("cat /home/noct/.run/browser-benchmark.json 2>/dev/null", check=False)
        if raw.returncode == 0:
            browser = json.loads(raw.stdout); break
        time.sleep(.25)
    else:
        raise RuntimeError("Browser GPU workload did not return a result")
    load = json.loads(ws.ssh("cat /home/noct/.run/browser-load.json").stdout)
    config = json.loads(ws.ssh("cat /etc/noct/gpu.json").stdout)
    renderer = ws.ssh("su -l noct -c " + shlex.quote(env + "GALLIUM_DRIVER=virgl glxinfo -B")).stdout.decode()
    fds = ws.ssh("for p in $(pgrep -x WebKitWebProcess); do procstat -f $p; done").stdout.decode()
    host_log = ws.safe("Logs/qemu.log").read_text(errors="replace")
    host_renderer = [s for s in host_log.splitlines() if "GPU renderer:" in s][-1:]
    confinement = writable_files(ws)
    required = {"multisample_resolve", "texture_3d_r8", "vao_instancing",
                "integer_vertex_attributes", "r8_atlas_subrect"}
    checks = browser.get("webgl2_checks", {})
    webgl2 = (browser.get("context") == "webgl2" and required <= checks.keys()
              and all(checks[name].get("passed") is True for name in required))
    text = browser.get("canvas_text_passed") is True
    passed = (webgl2 and text and browser.get("pixel_passed") is True and browser.get("gl_error") == 0
              and config.get("page_painting") == "gpu" and load.get("runtime") == "c++"
              and load.get("hardware_acceleration_policy") == "always"
              and "virgl (ANGLE" in renderer and "Accelerated: yes" in renderer
              and "ANGLE Metal Renderer: Apple" in " ".join(host_renderer)
              and "/dev/drm/128" in fds and confinement["passed"])
    return {"hardware_path_passed": passed,
            "webgl2_passed": webgl2, "gpu_text_passed": text,
            "full_browser_gpu": False,
            "limits": ["Focused smoke checks, not a full WebGL conformance suite",
                       "Hardware video decode and WebGPU are not implemented/verified",
                       "Shared-memory readback and RFB display transport"],
            "browser": browser, "load": load, "guest_gpu_config": config,
            "guest_renderer": renderer, "host_renderer": host_renderer,
            "webkit_render_node_fds": fds, "host_runtime": confinement}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--workspace", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args(); result = verify(FreeBSDWorkspace(a.workspace))
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"saved": str(a.output), "hardware_path_passed": result["hardware_path_passed"],
                      "full_browser_gpu": result["full_browser_gpu"]}))
    return 0 if result["hardware_path_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
