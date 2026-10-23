# Native development

Open `NoctDesktop.xcodeproj` and select **NoctDesktop**. The checked-in project
builds the AppKit/Metal app, its Swift VM controller/installer and a Swift CLI.
`project.yml` is its XcodeGen source. Keep the NoctBSD checkout alongside it.
Homebrew QEMU/XZ and, for the optional GPU backend, the locally prepared runtime
are still development dependencies. This is not yet a standalone notarized app.

The post-build script bundles guest C++/shell/HTML sources, the sandbox profile
and the Metal helper. It excludes Python files. The guest builds its approximately
250 KiB C++17 desktop/browser with the base compiler and existing GTK/WebKit,
JSON-GLib, X11 and OpenSSL libraries. The guest installer uses shell/base tools.
Python is retained only for host build/verification and historical experiments.

## Checks

`NoctRuntimeChecks` is an Xcode command-line target. Run it from the repository
root with at least 15 GiB free. It creates and removes its own empty synthetic
encrypted vault. Eleven checks cover creation, AES-encrypted image status,
wrong-password rejection, reopen/persistence, filesystem identity, path escape,
symlink rejection, successful detachment and absence of a VM after lock.

In an unlocked synthetic guest, `/opt/noct/test-native.sh` compiles a disposable
C++ test binary. Twelve checks cover authenticated secret round trips, fresh
nonces, empty values, tampering, cross-app AAD, missing-key refusal, input bounds,
key symlinks and key permissions. The `noctdesktop.secret@1` envelope remains
compatible with the earlier implementation; it is not a Noctweave wire object.

`tools/verify_browser_gpu.py` checks the native C++ browser's WebGL 2/text pixels,
actual renderer paths, render-node descriptors and host writable-file placement.
`tools/verify_freebsd.py` retains the synthetic storage workload. These are
research tools, not app runtime dependencies or OS-wide security certification.

The Swift controller was exercised on the configured GPU guest, including
ordinary ACPI shutdown/detach and a failed shutdown that kept the vault mounted.
The entire newly ported image download and first provisioning sequence has not
yet been rerun. The existing guest was synchronized, rebuilt and tested in place
to avoid duplicating its multi-gigabyte disk.

## UI

The Swift gate uses short lock/unlock copy. The C++ shell uses a compact menu
bar, vector wallpaper, floating dock, running indicators and traffic-light
controls with the Noctweave palette. Guest app windows share a rounded X11 shape,
compact draggable title bar, resize edges and vector toolbar controls. Files uses
a selected-place sidebar, expanding name column and short item count. Applications
uses an icon launcher and a compact web-app installation form. Rounded
corners require no compositor or new guest packages. Desktop positions and browser preferences
stay in the guest home. The logical-resolution cap and readback display path
remain; the UI does not claim Retina rendering or a full macOS compositor.
