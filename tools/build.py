#!/usr/bin/env python3
"""Build a small AppKit launcher and the local filesystem observer."""
from pathlib import Path
import os
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
BUILD.mkdir(exist_ok=True)
BROWSER = BUILD / "Noct Browser.app"
(BROWSER / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-O", "-framework", "AppKit", "-framework", "WebKit",
                str(ROOT / "src/BrowserWorkspace.swift"), str(ROOT / "src/NoctBrowser.swift"),
                "-o", str(BROWSER / "Contents/MacOS/NoctBrowser")], check=True)
browser_info = {"CFBundleName": "Noct Browser", "CFBundleDisplayName": "Noct Browser",
                "CFBundleIdentifier": "local.noctdesktop.browser", "CFBundleExecutable": "NoctBrowser",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1", "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
                "NSAppTransportSecurity": {"NSAllowsArbitraryLoadsInWebContent": True, "NSAllowsArbitraryLoads": True},
                "NSHumanReadableCopyright": "Noct Desktop browser prototype"}
(BROWSER / "Contents/Info.plist").write_bytes(plistlib.dumps(browser_info))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(BROWSER)], check=True)
APP = BUILD / "Noct Desktop Native.app"
(APP / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-O", "-framework", "AppKit", "-framework", "MetalKit",
                str(ROOT / "src/NoctDesktop.swift"), str(ROOT / "src/DesktopViews.swift"), str(ROOT / "src/VMDisplay.swift"), str(ROOT / "src/NoctMetal.swift"),
                "-o", str(APP / "Contents/MacOS/NoctDesktop")], check=True)
info = {"CFBundleName": "Noct Desktop", "CFBundleDisplayName": "Noct Desktop",
        "CFBundleIdentifier": "local.noctdesktop.prototype", "CFBundleExecutable": "NoctDesktop",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.2", "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "PrototypeRoot": str(ROOT), "PythonExecutable": sys.executable}
(APP / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(APP)], check=True)
VMAPP = BUILD / "Noct Desktop.app"
(VMAPP / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
import shutil
shutil.copy2(APP / "Contents/MacOS/NoctDesktop", VMAPP / "Contents/MacOS/NoctDesktop")
vm_info = {**info, "CFBundleIdentifier": "local.noctdesktop.freebsd.prototype", "CFBundleDisplayName": "Noct Desktop",
           "CFBundleShortVersionString": "0.3", "CFBundleVersion": "3", "NoctVMRuntime": True}
(VMAPP / "Contents/Info.plist").write_bytes(plistlib.dumps(vm_info))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(VMAPP)], check=True)
subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-O", "-framework", "MetalKit",
                str(ROOT / "src/NoctMetal.swift"), str(ROOT / "src/NoctGPUBroker.swift"),
                "-o", str(BUILD / "NoctGPUBroker")], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(BUILD / "NoctGPUBroker")], check=True)
subprocess.run(["/usr/bin/xcrun", "clang", "-O2", "-framework", "Foundation", "-framework", "CoreServices",
                str(ROOT / "tools/watch_files.m"), "-o", str(BUILD / "watch-files")], check=True)
subprocess.run(["/usr/bin/xcrun", "clang", "-fblocks", "-lEndpointSecurity", str(ROOT / "tools/probe_es.c"),
                "-o", str(BUILD / "probe-es")], check=True)
subprocess.run(["/usr/bin/xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-framework", "Foundation",
                str(ROOT / "tools/trace_preferences.m"), "-o", str(BUILD / "trace-preferences.dylib")], check=True)
print(VMAPP)
