#!/usr/bin/env python3
"""Noct Desktop FreeBSD research runtime. No shared folders or saved VM RAM."""
from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import resource
import secrets
import shutil
import socket
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request

from workspace import ROOT, Workspace, WorkspaceError, process_table, read_password, run, write_json

RELEASE = "15.1-RELEASE"
IMAGE_NAME = f"FreeBSD-{RELEASE}-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz"
IMAGE_URL = f"https://download.freebsd.org/releases/VM-IMAGES/{RELEASE}/aarch64/Latest/{IMAGE_NAME}"
IMAGE_SHA256 = "9722aea499610802de9a14bb645707fc4f6df49ff765cd9ce372b783c4693963"
QEMU = Path("/opt/homebrew/bin/qemu-system-aarch64")
VIRGL_RUNTIME = ROOT / "build/virgl-host"
VIRGL_QEMU = VIRGL_RUNTIME / "bin/qemu-system-aarch64"
QEMU_IMG = Path("/opt/homebrew/bin/qemu-img")
FIRMWARE = Path("/opt/homebrew/share/qemu/edk2-aarch64-code.fd")
VARIABLES = Path("/opt/homebrew/share/qemu/edk2-arm-vars.fd")
MIN_FREE = 15 * 1024**3
BSD_SOURCE = ROOT.parent / "NoctBSD" / "overlay/opt/noct"
GPU_BROKER = ROOT / "build/NoctGPUBroker"


def disk_guard():
    free = shutil.disk_usage(ROOT).free
    if free < MIN_FREE:
        raise WorkspaceError(f"Disk reserve reached ({free / 1024**3:.1f} GiB free). Keep at least 15 GiB free.")
    return free


class FreeBSDWorkspace(Workspace):
    @property
    def vm(self): return self.mount / "VM/FreeBSD"

    def safe(self, relative):
        self.require_mounted()
        path = self.vm / relative
        if path.is_symlink() or path.resolve() != path or not path.is_relative_to(self.mount):
            raise WorkspaceError("A VM path is not contained in the encrypted workspace.")
        return path

    def create(self, password, *, size="8g", disk_mib=7680, **kwargs):
        disk_guard()
        if (size, disk_mib) not in {("8g", 7680), ("12g", 9216)}:
            raise WorkspaceError("Unsupported FreeBSD volume/disk capacity pair.")
        super().create(password, size=size)
        config = self.config()
        config.update(runtime="freebsd-vm", release=RELEASE, memory_mib=1536, vcpus=2, noct_gpu=True, disk_mib=disk_mib)
        write_json(self.metadata, config)

    def install_vm(self):
        disk_guard()
        if not all(p.exists() for p in [QEMU, QEMU_IMG, FIRMWARE, VARIABLES]):
            raise WorkspaceError("Install the Homebrew qemu package before setting up this prototype.")
        if self.vm_processes(): raise WorkspaceError("Stop the VM before installation.")
        for name in ["", "Run", "Home", "Home/Library/Preferences", "Cache", "Temp", "Logs", "Seed", "Keys"]:
            self.safe(name).mkdir(mode=0o700, parents=True, exist_ok=True)
        disk = self.safe("system.qcow2")
        installation = self.safe("installation.json")
        if disk.exists():
            if not installation.exists(): raise WorkspaceError("An incomplete VM installation is present; it was preserved.")
            return json.loads(installation.read_text())
        stage = self.safe("system.qcow2.part")
        digest = hashlib.sha256(); compressed = expanded = 0; next_progress = 0
        decoder = lzma.LZMADecompressor(memlimit=256 * 1024**2)
        try:
            with urllib.request.urlopen(IMAGE_URL, timeout=45) as source, stage.open("xb") as target:
                os.chmod(stage, 0o600)
                while chunk := source.read(1024**2):
                    disk_guard(); digest.update(chunk); compressed += len(chunk)
                    incoming = chunk
                    while True:
                        output = decoder.decompress(incoming, max_length=4 * 1024**2)
                        incoming = b""; expanded += len(output)
                        if expanded > 4 * 1024**3: raise WorkspaceError("The decompressed image exceeds the prototype budget.")
                        target.write(output)
                        if decoder.needs_input or decoder.eof: break
                    if compressed >= next_progress:
                        print(f"FreeBSD image: {compressed // 1024**2} MiB downloaded, {expanded // 1024**2} MiB extracted", file=sys.stderr, flush=True)
                        next_progress = compressed + 64 * 1024**2
                target.flush(); os.fsync(target.fileno())
            if not decoder.eof or digest.hexdigest() != IMAGE_SHA256:
                raise WorkspaceError("The FreeBSD image failed its pinned SHA-256 / XZ integrity check.")
            info = json.loads(run([QEMU_IMG, "info", "--output=json", stage]))
            if info.get("format") != "qcow2" or info.get("backing-filename"):
                raise WorkspaceError("Unexpected guest image format or external backing file.")
            run([QEMU_IMG, "check", stage], timeout=90)
            # A sparse virtual capacity increase gives pkg enough working room;
            # it allocates no additional guest data here. growfs handles it on boot.
            disk_mib = self.config().get("disk_mib", 7680)
            if disk_mib not in {7680, 9216}: raise WorkspaceError("Unsupported guest disk capacity.")
            run([QEMU_IMG, "resize", stage, f"{disk_mib}M"])
            stage.rename(disk)
            shutil.copyfile(VARIABLES, self.safe("uefi-vars.fd"))
            os.chmod(self.safe("uefi-vars.fd"), 0o600)
            self.make_seed()
            result = {"release": RELEASE, "source": IMAGE_URL, "compressed_sha256": digest.hexdigest(),
                      "compressed_bytes": compressed, "extracted_bytes": expanded,
                      "source_virtual_bytes": info["virtual-size"], "virtual_bytes": disk_mib * 1024**2, "installed_at": time.time(),
                      "firmware_sha256": hashlib.sha256(FIRMWARE.read_bytes()).hexdigest()}
            write_json(installation, result)
            return result
        except Exception:
            stage.unlink(missing_ok=True)
            raise

    def make_seed(self):
        key = self.safe("Keys/management_ed25519")
        hostkey = self.safe("Keys/ssh_host_ed25519_key")
        for path in [key, hostkey]:
            if not path.exists(): run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", path])
        public = key.with_suffix(".pub").read_text().strip()
        host_private = base64.b64encode(hostkey.read_bytes()).decode()
        host_public = base64.b64encode(hostkey.with_suffix(".pub").read_bytes()).decode()
        # NoCloud executes this script once, at rc.local time. Every seed,
        # private key, guest log, host-key pin and package cache is in the vault.
        script = f'''#!/bin/sh
set -eu
umask 077
mkdir -p /root/.ssh
printf '%s\\n' '{public}' > /root/.ssh/authorized_keys
echo '{host_private}' | /usr/bin/base64 -d > /etc/ssh/ssh_host_ed25519_key
echo '{host_public}' | /usr/bin/base64 -d > /etc/ssh/ssh_host_ed25519_key.pub
chmod 600 /root/.ssh/authorized_keys /etc/ssh/ssh_host_ed25519_key
cat > /etc/ssh/sshd_config <<'SSHD'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
HostKey /etc/ssh/ssh_host_ed25519_key
SSHD
pw usermod freebsd -w no || true
sysrc sshd_enable=YES dumpdev=NO savecore_enable=NO sendmail_enable=NONE
sysrc ntpd_enable=NO growfs_enable=YES hostname=noct-desktop
swapoff -a || true
sed -i '' '/gpt\\/swapfs/d' /etc/fstab
service sshd restart
touch /root/noct-bootstrap-ready
echo NOCT_BOOTSTRAP_READY > /dev/console
'''
        self.safe("Seed/user-data").write_text(script)
        self.safe("Seed/meta-data").write_text(f"instance-id: noct-{self.config()['id']}\nlocal-hostname: noct-desktop\n")
        run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata",
             "-o", self.safe("seed.iso"), self.safe("Seed")], timeout=45)
        os.chmod(self.safe("seed.iso"), 0o600)

    def vm_processes(self):
        marker = str(self.vm / "Run/qmp.sock")
        executables = (str(QEMU) + " ", str(VIRGL_QEMU) + " ")
        return {pid: row for pid, row in process_table().items()
                if row["command"].startswith(executables) and marker in row["command"]}

    def gpu_processes(self):
        marker = str(self.vm / "Run/gpu.sock")
        return {pid: row for pid, row in process_table().items()
                if row["command"].startswith(str(GPU_BROKER)) and marker in row["command"]}

    def stop_gpu(self):
        import signal
        processes = self.gpu_processes()
        for pid in processes:
            with contextlib.suppress(ProcessLookupError): os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 3
        while self.gpu_processes() and time.monotonic() < deadline: time.sleep(.05)
        if self.gpu_processes():
            raise WorkspaceError("Lock incomplete: the workspace GPU helper did not exit.")

    def runtime_environment(self):
        return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8",
                "HOME": str(self.safe("Home")), "CFFIXED_USER_HOME": str(self.safe("Home")),
                "TMPDIR": str(self.safe("Temp")) + "/", "XDG_CACHE_HOME": str(self.safe("Cache")),
                "XDG_CONFIG_HOME": str(self.safe("Home")), "XDG_RUNTIME_DIR": str(self.safe("Run"))}

    def launch_gpu(self):
        self.stop_gpu()
        if not GPU_BROKER.is_file(): raise WorkspaceError("Build Noct Desktop before enabling its experimental GPU API.")
        self.safe("Run/gpu.sock").unlink(missing_ok=True)
        def no_core(): resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        with self.safe("Logs/gpu.log").open("ab", buffering=0) as log:
            child = subprocess.Popen(["/usr/bin/sandbox-exec", "-D", "VAULT=" + str(self.vm), "-f", str(ROOT / "tools/gpu-helper.sb"),
                str(GPU_BROKER), "--socket", str(self.safe("Run/gpu.sock"))],
                cwd=self.vm, env=self.runtime_environment(), stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                start_new_session=True, preexec_fn=no_core)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if child.poll() is not None: raise WorkspaceError("The experimental Metal helper failed to start.")
            if self.safe("Run/gpu.sock").exists(): return
            time.sleep(.05)
        self.stop_gpu(); raise WorkspaceError("The experimental Metal helper did not become ready.")

    def wait_ready(self, timeout=600, *, initial_setup=False):
        started = time.monotonic(); last = "Waiting for SSH"
        while time.monotonic() - started < timeout:
            disk_guard()
            if not self.vm_processes():
                if initial_setup: self.launch_vm()  # Cloud image's first pkgbase update reboots once.
                else: raise WorkspaceError("FreeBSD stopped before becoming ready.")
            try:
                result = self.ssh("test -f /root/noct-bootstrap-ready", timeout=6, check=False)
                if result.returncode == 0: return {"ready_seconds": time.monotonic() - started}
                last = result.stderr.decode(errors="replace")[-300:]
            except (OSError, subprocess.TimeoutExpired) as error: last = str(error)
            time.sleep(1)
        raise WorkspaceError("FreeBSD setup timed out: " + last)

    def setup_vm(self):
        self.install_vm(); self.launch_vm(); self.wait_ready(initial_setup=True)
        self.sync_guest_sources()
        results = []
        def install():
            try: results.append(self.ssh("/bin/sh /opt/noct/provision.sh; s=$?; tail -30 /var/log/noct-provision.log; exit $s", timeout=1800, check=False))
            except Exception as error: results.append(error)
        worker = threading.Thread(target=install); worker.start()
        reserve_error = None
        while worker.is_alive():
            try: disk_guard()
            except WorkspaceError as error:
                reserve_error = error
                self.ssh("pkill -TERM -x pkg || true", timeout=10, check=False)
                break
            worker.join(1)
        worker.join(20)
        if reserve_error: raise reserve_error
        if not results: raise WorkspaceError("Guest installer did not return a result.")
        if isinstance(results[0], Exception): raise results[0]
        if results[0].returncode:
            raise WorkspaceError("Guest setup failed: " + (results[0].stdout + results[0].stderr).decode(errors="replace")[-2500:])
        write_json(self.safe("desktop.json"), {"runtime": 1, "desktop": "Noct", "browser": "WebKitGTK", "installed_at": time.time()})
        self.ssh("/usr/sbin/daemon -f -o /var/log/noct-desktop.log /opt/noct/start-desktop.sh")
        return self.vm_status()

    def sync_guest_sources(self):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as bundle:
            for path in sorted(BSD_SOURCE.iterdir()):
                if path.is_file() or path.name == "native": bundle.add(path, arcname=path.name)
        self.ssh("mkdir -p /opt/noct; tar -xf - -C /opt/noct && chmod 755 /opt/noct/*.sh /opt/noct/noct.py /opt/noct/noct_gpu.py", input=archive.getvalue())

    def enable_browser_gpu(self):
        """Close the native shell before this explicit cold-restart operation."""
        disk_guard()
        self.verify_gpu_runtime()
        if not self.safe("desktop.json").is_file():
            raise WorkspaceError("Configure the FreeBSD desktop before enabling browser GPU rendering.")
        self.launch_vm(); self.wait_ready()
        self.sync_guest_sources()
        results = []
        def install():
            try:
                results.append(self.ssh("/bin/sh /opt/noct/install-browser-gpu.sh; s=$?; tail -12 /var/log/noct-browser-gpu-install.log; exit $s", timeout=1200, check=False))
            except Exception as error: results.append(error)
        worker = threading.Thread(target=install); worker.start()
        reserve_error = None
        while worker.is_alive():
            try: disk_guard()
            except WorkspaceError as error:
                reserve_error = error
                # Shutdown cancels all guest build/package children as well.
                self.stop_vm()
                break
            worker.join(1)
        worker.join(20)
        if reserve_error: raise reserve_error
        if not results: raise WorkspaceError("Guest GPU installer did not return a result.")
        if isinstance(results[0], Exception): raise results[0]
        if results[0].returncode:
            raise WorkspaceError("Guest GPU setup failed: " + (results[0].stdout + results[0].stderr).decode(errors="replace")[-2500:])
        self.stop_vm()
        config = self.config(); config["graphics"] = "virgl-metal"; write_json(self.metadata, config)
        self.launch_vm(); self.wait_ready()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.ssh("test -c /dev/dri/renderD128 && pgrep -x Xvnc >/dev/null", check=False).returncode == 0:
                break
            time.sleep(.5)
        else:
            details = self.ssh("dmesg | tail -15; tail -8 /var/log/noct-desktop.log", check=False)
            raise WorkspaceError("GPU desktop did not start; workspace remains mounted: " +
                                 (details.stdout + details.stderr).decode(errors="replace")[-2000:])
        return self.vm_status()

    def disable_browser_gpu(self):
        self.launch_vm(); self.wait_ready()
        self.ssh("rm -f /etc/noct/gpu.json")
        self.stop_vm()
        config = self.config(); config["graphics"] = "software"; write_json(self.metadata, config)
        self.launch_vm(); self.wait_ready()
        return self.vm_status()

    @staticmethod
    def verify_gpu_runtime():
        try:
            manifest = json.loads((VIRGL_RUNTIME / "manifest.json").read_text())
            binaries = manifest["binaries"]
            required = {"bin/qemu-system-aarch64", "lib/libEGL.dylib", "lib/libGLESv2.dylib",
                        "lib/libGLESv1_CM.dylib", "lib/libepoxy.0.dylib", "lib/libvirglrenderer.1.dylib"}
            if manifest.get("prepared_by") != "noct.browser-gpu@1" or not required.issubset(binaries):
                raise ValueError("Incomplete GPU runtime manifest")
            for relative, expected in binaries.items():
                path = VIRGL_RUNTIME / relative
                if not path.resolve().is_relative_to(VIRGL_RUNTIME.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                    raise ValueError("GPU runtime checksum mismatch")
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise WorkspaceError("Prepare the browser GPU runtime with tools/fetch_virgl_host.py: " + str(error)) from error

    def launch_vm(self):
        disk_guard()
        if not self.safe("installation.json").is_file(): raise WorkspaceError("Set up FreeBSD first.")
        if self.vm_processes(): return self.vm_status()
        for name in ["Run/qmp.sock", "Run/display.sock", "Run/qemu.pid"]:
            self.safe(name).unlink(missing_ok=True)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0)); port = reservation.getsockname()[1]
        host_public = self.safe("Keys/ssh_host_ed25519_key.pub").read_text().strip()
        self.safe("Keys/known_hosts").write_text(f"[127.0.0.1]:{port} {host_public}\n")
        use_gpu = self.config().get("noct_gpu", False)
        graphics = self.config().get("graphics", "software")
        if graphics not in {"software", "virgl-metal"}:
            raise WorkspaceError("Unknown VM graphics backend.")
        virgl = graphics == "virgl-metal"
        if virgl and not VIRGL_QEMU.is_file():
            raise WorkspaceError("Build the Noct virgl host runtime before enabling browser GPU acceleration.")
        if virgl: self.verify_gpu_runtime()
        if use_gpu: self.launch_gpu()
        # Unix sockets live under a 0700 encrypted mount. No VNC TCP listener,
        # host file share, clipboard agent, writable backing disk, or RAM save.
        command = [str(VIRGL_QEMU if virgl else QEMU), "-L", str(FIRMWARE.parent),
                   "-name", "Noct Desktop FreeBSD", "-machine", "virt", "-accel", "hvf",
                   "-cpu", "host", "-smp", "2", "-m", str(self.config().get("memory_mib", 1536)),
                   "-nodefaults", "-no-user-config", "-no-reboot",
                   "-drive", f"if=pflash,format=raw,unit=0,file={FIRMWARE},readonly=on",
                   "-drive", f"if=pflash,format=raw,unit=1,file={self.safe('uefi-vars.fd')}",
                   "-drive", f"if=none,id=system,format=qcow2,file={self.safe('system.qcow2')},cache=writethrough,discard=unmap,detect-zeroes=unmap",
                   "-device", "virtio-blk-pci,drive=system",
                   "-drive", f"if=none,id=seed,format=raw,file={self.safe('seed.iso')},readonly=on",
                   "-device", "virtio-blk-pci,drive=seed",
                   "-netdev", f"user,id=network,hostfwd=tcp:127.0.0.1:{port}-:22,hostfwd=unix:{self.safe('Run/display.sock')}-:5900",
                   "-device", "virtio-net-pci,netdev=network", "-device", "virtio-rng-pci",
                   *([] if virgl else ["-device", "ramfb"]),
                   "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
                   "-display", "egl-headless,gl=es" if virgl else "none",
                   "-serial", f"file:{self.safe('Logs/serial.log')}",
                   "-qmp", f"unix:{self.safe('Run/qmp.sock')},server=on,wait=off",
                   "-pidfile", str(self.safe("Run/qemu.pid"))]
        if use_gpu:
            command += ["-device", "virtio-serial-pci", "-chardev", f"socket,id=noctgpu,path={self.safe('Run/gpu.sock')},reconnect-ms=1000",
                        "-device", "virtserialport,chardev=noctgpu,nr=1,name=org.noctdesktop.gpu"]
        if virgl:
            # This scanout serves firmware only; Xvnc has its own resizable
            # desktop. Keeping the unused boot console small saves transfers.
            command += ["-device", "virtio-gpu-gl-pci,xres=640,yres=480"]
        env = self.runtime_environment()
        if virgl:
            # SIP strips DYLD_* at sandbox-exec startup. Set the search path in
            # its child, then exec the locally signed runtime under Seatbelt.
            command = ["/usr/bin/sandbox-exec", "-D", "VAULT=" + str(self.vm),
                       "-f", str(ROOT / "tools/gpu-helper.sb"), "/usr/bin/env",
                       "DYLD_LIBRARY_PATH=" + str(VIRGL_RUNTIME / "lib"), *command]
        def no_core(): resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        with self.safe("Logs/qemu.log").open("ab", buffering=0) as log:
            process = subprocess.Popen(command, cwd=self.vm, env=env, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=log, start_new_session=True, preexec_fn=no_core)
        started = time.time()
        write_json(self.safe("Run/process.json"), {"pid": process.pid, "ssh_port": port, "started_at": started,
                                                    "argv": command, "accelerator": "hvf", "graphics": graphics})
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.stop_gpu()
                raise WorkspaceError("QEMU exited during startup: " + self.safe("Logs/qemu.log").read_text()[-2000:])
            try:
                if self.vm_processes() and self.safe("Run/qmp.sock").is_socket():
                    return self.vm_status()
            except (FileNotFoundError, ConnectionRefusedError, TimeoutError):
                # Cold Metal initialization can precede the QMP listener.
                pass
            time.sleep(.1)
        raise WorkspaceError("QEMU has not exposed its control socket yet; the vault remains mounted.")

    def qmp(self, command):
        path = self.safe("Run/qmp.sock")
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5); client.connect(str(path)); stream = client.makefile("rwb", buffering=0)
            json.loads(stream.readline())
            def request(name):
                stream.write(json.dumps({"execute": name}).encode() + b"\n")
                while line := stream.readline():
                    reply = json.loads(line)
                    if "error" in reply: raise WorkspaceError(str(reply["error"]))
                    if "return" in reply: return reply["return"]
                raise WorkspaceError("The VM control socket closed unexpectedly.")
            request("qmp_capabilities")
            return request(command)

    def ssh(self, command, *, timeout=60, input=None, check=True):
        info = json.loads(self.safe("Run/process.json").read_text())
        args = ["/usr/bin/ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10",
                "-o", "IdentityAgent=none", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + str(self.safe("Keys/known_hosts")),
                "-o", "GlobalKnownHostsFile=/dev/null", "-i", str(self.safe("Keys/management_ed25519")),
                "-p", str(info["ssh_port"]), "root@127.0.0.1", command]
        for attempt in range(2):
            result = subprocess.run(args, input=input, capture_output=True, timeout=timeout)
            # A busy experimental renderer can delay slirp's SSH handshake.
            # Only retry this pre-authentication failure: the remote command
            # has not run. Never retry an ambiguous command/transport failure.
            if attempt == 0 and result.returncode == 255 and b"Connection timed out during banner exchange" in result.stderr:
                continue
            break
        if check and result.returncode:
            raise WorkspaceError("Guest command failed: " + (result.stdout + result.stderr).decode(errors="replace")[-2500:])
        return result

    def vm_status(self):
        processes = self.vm_processes()
        result = {"vm_pids": list(processes), "vm_running": bool(processes),
                  "gpu_pids": list(self.gpu_processes()), "gpu_api": "noct.triangles@1" if self.config().get("noct_gpu", False) else None,
                  "vm_installed": self.safe("installation.json").is_file(),
                  "vm_configured": self.safe("desktop.json").is_file(),
                  "graphics": self.config().get("graphics", "software"),
                  "display_socket": str(self.vm / "Run/display.sock"), "memory_mib": self.config().get("memory_mib", 1536)}
        if processes:
            result["qmp"] = self.qmp("query-status")
        return result

    def status(self):
        result = super().status()
        result["runtime"] = "freebsd-vm"
        if result.get("mounted", False): result.update(self.vm_status())
        else: result.update(vm_running=bool(self.vm_processes()), vm_pids=list(self.vm_processes()), vm_installed=None)
        return result

    def stop_vm(self, timeout=60):
        if not self.vm_processes():
            self.stop_gpu()
            return {"shutdown_seconds": 0, "already_stopped": True}
        self.require_mounted(); start = time.monotonic()
        # ACPI power button -> guest filesystem sync/unmount -> QEMU exit.
        # A timeout remains visibly unlocked; no forced unmount or RAM suspend.
        self.qmp("system_powerdown")
        while self.vm_processes() and time.monotonic() - start < timeout: time.sleep(0.2)
        if self.vm_processes(): raise WorkspaceError("Lock incomplete: FreeBSD did not shut down. The vault remains mounted.")
        self.stop_gpu()
        return {"shutdown_seconds": time.monotonic() - start, "shutdown_method": "ACPI system_powerdown"}

    def lock(self):
        if self.vm_processes() and not self.attached():
            raise WorkspaceError("VM state is inconsistent: a process is running without its mounted vault.")
        stopped = self.stop_vm()
        result = super().lock(); result.update(stopped)
        return result


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=ROOT / "workspaces/FreeBSD")
    parser.add_argument("--password-stdin", action="store_true")
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ["create", "unlock", "install-vm", "setup-vm", "launch-vm", "stop-vm", "lock", "status", "enable-browser-gpu", "disable-browser-gpu"]: sub.add_parser(action)
    ssh = sub.add_parser("ssh"); ssh.add_argument("command")
    args = parser.parse_args(); ws = FreeBSDWorkspace(args.workspace)
    try:
        with ws.exclusive():
            if args.action == "create": ws.create(read_password(args.password_stdin, confirm=True)); result = ws.status()
            elif args.action == "unlock": result = ws.unlock(read_password(args.password_stdin))
            elif args.action == "install-vm": result = ws.install_vm()
            elif args.action == "setup-vm": result = ws.setup_vm()
            elif args.action == "launch-vm": result = ws.launch_vm()
            elif args.action == "stop-vm": result = ws.stop_vm()
            elif args.action == "enable-browser-gpu": result = ws.enable_browser_gpu()
            elif args.action == "disable-browser-gpu": result = ws.disable_browser_gpu()
            elif args.action == "lock": result = ws.lock()
            elif args.action == "ssh":
                result = ws.ssh(args.command, timeout=1200)
                sys.stdout.buffer.write(result.stdout); return 0
            else: result = ws.status()
        print(json.dumps(result, indent=2))
    except (WorkspaceError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr); return 1
    return 0


if __name__ == "__main__": raise SystemExit(main())
