#!/usr/bin/env python3
"""Build the experimental browser GPU runtime locally, without a global install.

Only two small renderer bottles and one Metal-enabled ANGLE bottle are used.
QEMU is built for AArch64/HVF only. Existing Homebrew firmware and core libraries
are reused. Source/build scratch is removed after success unless --keep-build.
Third-party components retain their upstream licenses. These patches are local
Noct experiments, not contributions to the upstream QEMU project.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "build/virgl-host"
SOURCE = ROOT / "build/qemu-gpu-source"
BUILD = ROOT / "build/qemu-gpu-build"
PATCH = ROOT / "tools/patches/qemu-virgl-metal-headless.patch"
QEMU_COMMIT = "7be5fa18e0a654678205799942c18673c2d87299"
BOTTLES = {
    "libepoxy-angle-master": {
        "prefix": "libepoxy-angle/master",
        "url": "https://github.com/milesbuckton/homebrew-qemu-virgl/releases/download/latest/libepoxy-angle-master.arm64_golden_gate.bottle.tar.gz",
        "sha256": "a9a47d808e0333de4564060f9378874b267f870fc5f1549dd9d1cc78cc2dde4a",
    },
    "virglrenderer-main": {
        "prefix": "virglrenderer/main",
        "url": "https://github.com/milesbuckton/homebrew-qemu-virgl/releases/download/latest/virglrenderer-main.arm64_golden_gate.bottle.tar.gz",
        "sha256": "e84cb1159894388c6be6cbc1a55a335aa358f356e2c8fce2410f706a1e725693",
    },
    "angle-metal": {
        "prefix": "angle/1.0.17",
        "url": "https://github.com/startergo/homebrew-angle/releases/download/v1.0.17/angle-1.0.17.arm64_tahoe.bottle.tar.gz",
        "sha256": "bf9f0be551197eed7f29312f88ad4e5ed47c97b80a7c157228d09325346f57a1",
    },
}
ANGLE_LICENSE = {
    "url": "https://raw.githubusercontent.com/google/angle/b82a564646a2/LICENSE",
    "sha256": "bf4da21bd20bcfb5b60b7ecc67fa864a79be049e21d6178076887f178dd6c71a",
}
RENDERER_PATCH = ROOT / "tools/patches/virgl-angle-multisample.patch"
RENDERER_SOURCE = {
    "commit": "f599855944c9fdf706f28dd9c41a2d8256b7f3a4",
    "url": "https://gitlab.freedesktop.org/miles.buckton/virglrenderer/-/archive/f599855944c9fdf706f28dd9c41a2d8256b7f3a4/virglrenderer-f599855944c9fdf706f28dd9c41a2d8256b7f3a4.tar.gz",
    "sha256": "49b23a83e9206b0b834c8e2758fbe4a1b6bfc4cb4eb0db9633df92d077437028",
}


def build_renderer(keep=False):
    """Build-time tooling only. Neither shipped app runs Python."""
    scratch = ROOT / "build/virgl-renderer-build"
    if scratch.exists():
        raise RuntimeError("Renderer scratch exists; preserve or remove that build before retrying")
    scratch.mkdir(parents=True)
    deps = scratch / "deps"
    try:
        for name in ["libepoxy-angle-master", "angle-metal", "source"]:
            spec = RENDERER_SOURCE if name == "source" else BOTTLES[name]
            archive = scratch / (name + ".tar.gz")
            with urllib.request.urlopen(spec["url"], timeout=45) as incoming, archive.open("xb") as output:
                count = 0
                while chunk := incoming.read(1024**2):
                    reserve(); count += len(chunk)
                    if count > 16 * 1024**2: raise RuntimeError("Renderer input exceeds its download budget")
                    output.write(chunk)
            if digest(archive) != spec["sha256"]: raise RuntimeError("Renderer input checksum mismatch: " + name)
            with tarfile.open(archive) as bundle:
                for member in bundle:
                    if not member.isfile(): continue
                    parts = Path(member.name).parts
                    if ".." in parts or Path(member.name).is_absolute(): raise RuntimeError("Unsafe renderer archive member")
                    if name == "source":
                        relative = Path(*parts[1:]); target = scratch / "source" / relative
                    else:
                        prefix = spec["prefix"] + "/include/"
                        if not member.name.startswith(prefix): continue
                        target = deps / "include" / member.name[len(prefix):]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(bundle.extractfile(member).read())
            archive.unlink()
        pc = deps / "lib/pkgconfig/epoxy.pc"; pc.parent.mkdir(parents=True)
        pc.write_text(f"prefix={deps}\nincludedir=${{prefix}}/include\nlibdir={DEST}/lib\nepoxy_has_glx=0\nepoxy_has_egl=1\nepoxy_has_wgl=0\nName: epoxy\nDescription: GL dispatch\nVersion: 1.5.11\nLibs: -L${{libdir}} -lepoxy\nCflags: -I${{includedir}}\n")
        run(["/usr/bin/patch", "-p1", "-t", "-i", RENDERER_PATCH], cwd=scratch / "source", stderr=subprocess.STDOUT)
        run([sys.executable, "-m", "venv", scratch / "venv"])
        run([scratch / "venv/bin/python3", "-m", "pip", "install", "--disable-pip-version-check", "--only-binary=:all:", "PyYAML==6.0.3"], stderr=subprocess.STDOUT)
        env = {**os.environ, "PATH": str(scratch / "venv/bin") + ":" + os.environ["PATH"],
               "PKG_CONFIG_PATH": str(pc.parent) + ":/opt/homebrew/lib/pkgconfig"}
        monitored(["meson", "setup", scratch / "build", scratch / "source", "-Dplatforms=egl", "-Dvenus=false", "-Dtests=false", "-Dvideo=false", "-Dbuildtype=release", "-Db_ndebug=true"], DEST / "logs/renderer-configure.log", env=env)
        monitored(["ninja", "-C", scratch / "build", "-j2", "src/libvirglrenderer.1.dylib"], DEST / "logs/renderer-build.log", env=env)
        target = DEST / "lib/libvirglrenderer.1.dylib"
        shutil.copyfile(scratch / "build/src/libvirglrenderer.1.dylib", target)
        run(["/usr/bin/install_name_tool", "-id", target, target], stderr=subprocess.STDOUT)
        run(["/usr/bin/codesign", "--force", "--sign", "-", target], stderr=subprocess.STDOUT)
        for file in (scratch / "source").glob("COPYING*"):
            shutil.copyfile(file, DEST / "licenses" / ("virglrenderer-source-" + file.name))
    finally:
        if not keep: shutil.rmtree(scratch, ignore_errors=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reserve():
    if shutil.disk_usage(ROOT).free < 15 * 1024**3:
        raise RuntimeError("Keep at least 15 GiB host disk space free")


def ensure_angle_license():
    # The pinned ANGLE bottle omits its BSD license. Fetch the matching source
    # notice separately and verify it, including when reusing a built runtime.
    target = DEST / "licenses/angle-metal-LICENSE"
    if target.is_file() and digest(target) == ANGLE_LICENSE["sha256"]:
        return
    with urllib.request.urlopen(ANGLE_LICENSE["url"], timeout=30) as response:
        data = response.read(65537)
    if len(data) > 65536 or hashlib.sha256(data).hexdigest() != ANGLE_LICENSE["sha256"]:
        raise RuntimeError("ANGLE license checksum mismatch")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)


def run(args, **kwargs):
    return subprocess.check_output([str(a) for a in args], **kwargs)


def monitored(args, log, **kwargs):
    with log.open("wb") as output:
        p = subprocess.Popen([str(a) for a in args], stdout=output, stderr=subprocess.STDOUT, **kwargs)
        try:
            while p.poll() is None:
                reserve()
                time.sleep(1)
        except BaseException:
            p.terminate()
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill(); p.wait()
            raise
    if p.returncode:
        raise RuntimeError(str(args[0]) + " failed: " + log.read_text(errors="replace")[-2500:])


def fetch(name, spec):
    archive = DEST / (name + ".tar.gz")
    part = archive.with_suffix(".part")
    print("Fetching", name, flush=True)
    try:
        with urllib.request.urlopen(spec["url"], timeout=45) as src, part.open("wb") as out:
            total = 0
            while chunk := src.read(1024**2):
                reserve(); total += len(chunk)
                if total > 16 * 1024**2:
                    raise RuntimeError("Bottle exceeds the 16 MiB download budget")
                out.write(chunk)
        part.rename(archive)
        if digest(archive) != spec["sha256"]:
            raise RuntimeError("Bottle checksum mismatch: " + name)
        with tarfile.open(archive) as bundle:
            prefix = spec["prefix"] + "/"
            for member in bundle:
                if not member.isfile() or not member.name.startswith(prefix):
                    continue
                relative = Path(member.name[len(prefix):])
                if relative.is_absolute() or ".." in relative.parts:
                    raise RuntimeError("Unsafe bottle member")
                library = relative.parts[0] == "lib" and relative.name.endswith(".dylib")
                header = relative.parts[0] == "include"
                pkgconfig = relative.parts[:2] == ("lib", "pkgconfig")
                metadata = relative.name in {"INSTALL_RECEIPT.json", "commit.txt"}
                license_file = relative.name.startswith(("LICENSE", "COPYING"))
                if not any((library, header, pkgconfig, metadata, license_file)):
                    continue
                target = (DEST / "lib" / relative.name if library else DEST / relative)
                if metadata: target = DEST / "metadata" / (name + "-" + relative.name)
                if license_file: target = DEST / "licenses" / (name + "-" + relative.name)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(bundle.extractfile(member).read())
                if library: target.chmod(0o755)
    finally:
        part.unlink(missing_ok=True)
        archive.unlink(missing_ok=True)


def relocate_and_sign():
    libraries = sorted((DEST / "lib").glob("*.dylib"))
    for binary in libraries:
        if binary.is_symlink(): continue
        args = ["/usr/bin/install_name_tool", "-id", binary]
        for line in run(["/usr/bin/otool", "-L", binary], text=True).splitlines()[1:]:
            old = line.strip().split(" (compatibility")[0]
            if old.startswith("@@HOMEBREW_PREFIX@@/opt/"):
                relative = old.split("/opt/", 1)[1]
                keg = relative.split("/", 1)[0]
                new = DEST / "lib" / Path(old).name if keg in {"angle", "libangle", "libepoxy-angle", "virglrenderer"} else Path("/opt/homebrew/opt") / relative
            elif old.startswith("@rpath/lib") and (DEST / "lib" / Path(old).name).exists():
                new = DEST / "lib" / Path(old).name
            else:
                continue
            if not new.exists(): raise RuntimeError("Missing dependency: " + str(new))
            args += ["-change", old, new]
        run([*args, binary], stderr=subprocess.STDOUT)
        run(["/usr/bin/xattr", "-c", binary])
        run(["/usr/bin/codesign", "--force", "--sign", "-", binary], stderr=subprocess.STDOUT)
    for name, version in [("epoxy", "0"), ("virglrenderer", "1")]:
        link = DEST / "lib" / ("lib" + name + ".dylib")
        link.unlink(missing_ok=True)
        link.symlink_to("lib" + name + "." + version + ".dylib")
    for pc in (DEST / "lib/pkgconfig").glob("*.pc"):
        lines = pc.read_text().splitlines()
        pc.write_text("\n".join("prefix=" + str(DEST) if line.startswith("prefix=") else line for line in lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-build", action="store_true")
    parser.add_argument("--rebuild", action="store_true")
    parser.add_argument("--renderer-only", action="store_true", help="Rebuild the small renderer without rebuilding QEMU")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise SystemExit("Apple Silicon macOS required")
    ensure_angle_license()
    manifest_path = DEST / "manifest.json"
    patch_hash = digest(PATCH)
    if manifest_path.exists() and not args.rebuild:
        manifest = json.loads(manifest_path.read_text())
        required = {"bin/qemu-system-aarch64", "lib/libEGL.dylib", "lib/libGLESv1_CM.dylib", "lib/libGLESv2.dylib", "lib/libepoxy.0.dylib", "lib/libvirglrenderer.1.dylib"}
        if manifest.get("qemu_local_patch_sha256") == patch_hash and manifest.get("qemu_source_commit") == QEMU_COMMIT and required <= manifest.get("binaries", {}).keys() and all((DEST / p).is_file() and digest(DEST / p) == h for p, h in manifest.get("binaries", {}).items()) and manifest.get("prepared_by") == "noct.browser-gpu@1":
            if manifest.get("renderer_patch_sha256") != digest(RENDERER_PATCH) or args.renderer_only:
                args.renderer_only = True
            else:
                manifest["angle_license"] = ANGLE_LICENSE
                manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
                print("Verified existing Noct browser GPU runtime"); return
    processes = run(["/bin/ps", "-axo", "command="], text=True)
    if any(line.startswith(str(DEST / "bin/qemu-system-aarch64") + " ") for line in processes.splitlines()):
        raise RuntimeError("Stop GPU workspaces before replacing their runtime")
    reserve()
    if args.renderer_only:
        if not manifest_path.is_file(): raise RuntimeError("Prepare QEMU before using --renderer-only")
        build_renderer(args.keep_build)
        manifest = json.loads(manifest_path.read_text())
        manifest.update(renderer_source=RENDERER_SOURCE, renderer_patch_sha256=digest(RENDERER_PATCH))
        manifest["binaries"]["lib/libvirglrenderer.1.dylib"] = digest(DEST / "lib/libvirglrenderer.1.dylib")
        manifest["runtime_file_bytes"] = sum((DEST / p).stat().st_size for p in manifest["binaries"])
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        print("Built and verified the patched ANGLE multisample renderer"); return
    for program in ["git", "/opt/homebrew/bin/ninja", "pkg-config", "clang", "codesign", "install_name_tool"]:
        if not shutil.which(program):
            raise RuntimeError("Install the required build tool first: " + program)
    for folder in ["bin", "lib", "metadata", "licenses", "logs"]:
        (DEST / folder).mkdir(parents=True, exist_ok=True)
    for name, spec in BOTTLES.items(): fetch(name, spec)
    relocate_and_sign()
    build_renderer(args.keep_build)
    fresh = not SOURCE.exists()
    if fresh:
        run(["git", "clone", "--depth=1", "--filter=blob:none", "--no-checkout", "--no-recurse-submodules", "https://gitlab.com/milesbuckton/qemu.git", SOURCE], stderr=subprocess.STDOUT)
    # Establish sparse rules before the first checkout to avoid unused ROMs.
    sparse = SOURCE / ".git/info/sparse-checkout"
    sparse.parent.mkdir(parents=True, exist_ok=True)
    sparse.write_text("/*\n!/roms/\n!/pc-bios/*.fd\n!/pc-bios/*.bin\n!/pc-bios/*.rom\n")
    run(["git", "-C", SOURCE, "config", "core.sparseCheckout", "true"])
    current = run(["git", "-C", SOURCE, "rev-parse", "HEAD"], text=True).strip()
    if current != QEMU_COMMIT:
        if not fresh and run(["git", "-C", SOURCE, "status", "--porcelain"], text=True).strip():
            raise RuntimeError("QEMU source has changes; preserve them before changing its revision")
        run(["git", "-C", SOURCE, "fetch", "--depth=1", "origin", QEMU_COMMIT], stderr=subprocess.STDOUT)
        run(["git", "-C", SOURCE, "checkout", "--detach", QEMU_COMMIT], stderr=subprocess.STDOUT)
    run(["git", "-C", SOURCE, "read-tree", "-mu", "HEAD"], stderr=subprocess.STDOUT)
    # Accept only our exact patch, or a clean tree to which it can be applied.
    actual = run(["git", "-C", SOURCE, "diff", "--binary"])
    if actual != PATCH.read_bytes():
        if actual: raise RuntimeError("Unexpected local QEMU source changes")
        run(["git", "-C", SOURCE, "apply", PATCH], stderr=subprocess.STDOUT)
    BUILD.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "PKG_CONFIG_PATH": str(DEST / "lib/pkgconfig") + ":/opt/homebrew/lib/pkgconfig", "DYLD_LIBRARY_PATH": str(DEST / "lib")}
    options = ["--target-list=aarch64-softmmu", "--without-default-features", "--enable-hvf", "--enable-slirp", "--enable-cocoa", "--enable-opengl", "--enable-virglrenderer", "--enable-pixman", "--disable-tcg", "--disable-tools", "--disable-docs", "--disable-tests", "--disable-debug-info", "--disable-guest-agent", "--disable-install-blobs", "--disable-werror", "--disable-pvg"]
    print("Configuring AArch64/HVF QEMU", flush=True)
    monitored([SOURCE / "configure", *options], DEST / "logs/configure.log", cwd=BUILD, env=env)
    print("Building QEMU with two jobs", flush=True)
    monitored(["/opt/homebrew/bin/ninja", "-j2", "qemu-system-aarch64"], DEST / "logs/build.log", cwd=BUILD, env=env)
    target = DEST / "bin/qemu-system-aarch64"
    shutil.copyfile(BUILD / "qemu-system-aarch64", target); target.chmod(0o755)
    entitlements = DEST / "metadata/qemu-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.hypervisor": True, "com.apple.security.cs.allow-jit": True}))
    run(["/usr/bin/xattr", "-c", target])
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, target], stderr=subprocess.STDOUT)
    for name in ["COPYING", "COPYING.LIB"]:
        if (SOURCE / name).exists(): shutil.copyfile(SOURCE / name, DEST / "licenses" / ("QEMU-" + name))
    manifest = {"prepared_by": "noct.browser-gpu@1", "qemu_source_commit": QEMU_COMMIT, "qemu_local_patch_sha256": patch_hash, "artifacts": BOTTLES, "angle_license": ANGLE_LICENSE, "binaries": {str(p.relative_to(DEST)): digest(p) for d in ["bin", "lib"] for p in (DEST / d).iterdir() if p.is_file() and not p.is_symlink()}, "version": run([target, "--version"], env=env, text=True).splitlines()[0]}
    manifest.update(renderer_source=RENDERER_SOURCE, renderer_patch_sha256=digest(RENDERER_PATCH))
    manifest["runtime_file_bytes"] = sum((DEST / p).stat().st_size for p in manifest["binaries"])
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    if not args.keep_build:
        shutil.rmtree(BUILD); shutil.rmtree(SOURCE)
        shutil.rmtree(DEST / "include", ignore_errors=True)
        shutil.rmtree(DEST / "lib/pkgconfig", ignore_errors=True)
    print(json.dumps({k: manifest[k] for k in ["version", "runtime_file_bytes"]}, indent=2))


if __name__ == "__main__":
    main()
