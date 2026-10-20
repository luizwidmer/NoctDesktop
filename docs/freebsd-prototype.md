# FreeBSD prototype verification

Measured locally on 20 October 2026. This report covers the package-based research build, not a production security certification or a comparison with other operating systems.

## Software baseline configuration

| Component | Tested configuration |
| --- | --- |
| Host | Apple M4, 16 GiB RAM, macOS 27.0.1 |
| Hypervisor | QEMU 11.1.2, Apple Hypervisor Framework, ARM64 |
| Guest | FreeBSD 15.1-RELEASE-p5, two virtual CPUs, 1,536 MiB RAM |
| Desktop | Unprivileged TigerVNC Xvnc, JWM, Noct GTK3 apps |
| Browser | WebKitGTK 4.1; software rendering |
| Storage | 7.5 GiB virtual qcow2 inside an 8 GiB logical AES-256 APFS sparsebundle |
| GPU | Metal display presentation; experimental first-party `noct.triangles@1` API |

The guest root used about 5.5 GiB. LLVM and graphics packages dominate its footprint. It is a working desktop prototype; a genuinely small release needs purpose-built runtime packages. Compressed image bytes, guest filesystem use, qcow2 allocation and encrypted APFS allocation are different measurements.

The installer enforces a 15 GiB host free-space reserve, streams the official compressed base image into the mounted vault and does not keep a second expanded source disk. The published repositories contain source, recipes and this report, without OS images, keys or user data.

## Performance

| Measurement | Result | Interpretation |
| --- | --- | --- |
| Launch to observed desktop readiness, three runs | 15.398, 15.462, 15.492 s; median **15.462 s** | Includes launcher and SSH polling delays; an upper bound, not isolated kernel boot time |
| ACPI shutdown preceding those runs | 6.915, 6.859, 6.849 s | Guest shutdown and helper stop; excludes encrypted-volume detachment |
| Idle QEMU RSS | 925,840 KiB | One quiet sample with 1,536 MiB configured guest RAM |
| Idle native shell RSS | 122,320 KiB | Resizable Metal display open |
| Idle GPU helper RSS | 16,000 KiB | No active render requests |
| Sum of those RSS samples | **1.015 GiB** | Shared pages can be counted more than once; not a complete physical-memory accounting |
| CPU over a quiet 10.013 s interval | About 1.2% of one core across the three processes | Derived from CPU-time deltas; not a sustained workload benchmark |
| Local browser page load | 1.234 s; 0.809 s in a subsequent persistence run | Loopback synthetic page; caches and display sizes differed |
| JavaScript, 2 million iterations | 3 ms median in both runs | Small synthetic workload; no cross-browser performance claim |
| 2,000 DOM elements and layout | 14 ms; 8 ms in the subsequent run | Software browser workload |
| Canvas, 20,000 rectangles | 19 ms; 17 ms in the subsequent run | Software browser workload |
| Browser animation callback interval | 18 ms median / 224 ms maximum; subsequent run 19 / 67 ms | Page callback timing, **not** end-to-end display frame rate |
| Download | 8,388,608 bytes | Synthetic file written into guest Workspace/Downloads |

These samples were taken on a developer machine without controlling all host activity. They establish feasibility and identify remaining overhead; they do not establish a speedup over the earlier prototype.

## Display and desktop

Actual guest geometry, queried through Gdk, changed from **1120×688** in a regular window to **1464×744** when zoomed and **1464×848** in fullscreen. No VM reboot was needed. The host sends ExtendedDesktopSize requests after a 200 ms resize delay, rounds dimensions to eight pixels and caps them at 1920×1200 logical pixels. Retina density rendering is not implemented.

Rendered inspection covered the Noctweave plum/ivory/coral/wine desktop, draggable icons, dock, Files, folder creation, Applications installer, Settings, browser, GPU Studio and locked screen. The installer list scrolls so installed apps do not push the installation form outside the window.

An HTTPS Example app was installed through the UI, loaded its page and saved zoom 1.1. A folder was created in Documents and the Browser icon was moved. The folder, app registry, zoom setting and icon position survived shutdown, actual vault detachment, unlock and reboot.

## GPU verification

The native shell presents changed guest frames through Metal. A separate restricted helper receives bounded triangle requests over private virtio-serial and executes fixed Metal shaders on Apple M4. GPU Studio displayed the resulting triangle and a changed geometry after its button was pressed.

The guest pixel test ran as the unprivileged `noct` user. It checked an exact red center and black corner, a different output for green input, a transfer checksum and five rejected invalid requests. The host self-test additionally rejected six invalid requests. The guest test's observed Metal pass was 0.045 ms; its complete multi-request verification took 0.286 s. Those figures cover different scopes and are not per-frame throughput measurements.

The measurements above describe the software baseline and first-party triangle API. A separate optional virgl/ANGLE Metal backend now provides hardware WebGL 1 and WebKit compositing. Full browser GPU support remains incomplete. See [browser GPU verification and limits](browser-gpu.md).

## Storage and lock evidence

The browser workload exercised cookies, localStorage, IndexedDB, Cache Storage and an 8 MiB download. Files were present under the browser's explicit Data and Cache directories; owned settings were under Preferences. After closing the browser, the persistent cookie was independently read from WebKit's `moz_cookies` SQLite table. The persistent test cookie uses Max-Age; a session cookie would not prove disk persistence.

A temporary-file probe running as `noct` used the configured guest `.tmp` directory. Browser helpers may also use guest system paths: the entire guest root and EFI filesystem are inside the encrypted virtual disk. No guest swap, crash dump, host shared folder, clipboard bridge or RAM save was configured. App profile directories are cooperative separation under one guest UID, not malicious-app isolation.

An open-file check of QEMU and the GPU helper found every writable regular file inside the mounted VM vault, including disk, firmware variables, temporary memory backing and logs. The helper's additional file-write policy blocked its attempted use of the ordinary host Metal shader cache while pixel rendering continued to pass. This is a bounded process snapshot, not an exhaustive system write trace. The native GUI and macOS services may create metadata and fixed-shader caches outside the vault; host RAM, swap, screenshots and diagnostics are outside this guarantee.

Verified lifecycle cases:

- Guest Lock: QEMU and GPU helper exited; encrypted volume actually detached; native display was cleared and the locked screen appeared.
- Wrong password: unlock failed; vault stayed detached and no VM/helper remained.
- Paused guest: a shortened shutdown deadline raised an explicit lock error and kept the vault mounted with its processes running. No successful lock was reported.
- Resume after that failure: the queued shutdown completed, both processes exited, and the GUI's stopped-guest handling detached the vault. The observed recovery took 12.9 s.
- Reopen after lock: persistent cookie, 8 MiB download, settings, installed app, created folder and icon layout were independently checked again.

Successful lock requires guest exit, helper exit and actual volume detachment. Timeout or busy-volume errors remain unsealed states. Mac screen locking, sleep, host-shell crashes and unexpected power loss are not verified replacements for the workspace Lock action. There is no claim of RAM or GPU-memory zeroization.

The local secret SDK's eight tests passed: encryption with fresh nonces, tamper rejection, app/record context binding, refusal to replace a missing key, symlink protections, permissions and invalid identifiers. This implements local AES-256-GCM storage; it does not certify Noctweave messaging or post-quantum protocol compatibility.

## Reproducing measurements

Use a disposable synthetic workspace. Boot measurements require closing the GUI first, because guest exit intentionally triggers its automatic lock. Browser measurements require closing other guest browser windows. Output belongs in the ignored evidence directory.

```sh
python3 tools/measure_freebsd.py --workspace /path/to/disposable-workspace --output evidence/boot.json --runs 3 boot
python3 tools/measure_freebsd.py --workspace /path/to/disposable-workspace --output evidence/browser.json browser
python3 tools/verify_freebsd.py --workspace /path/to/disposable-workspace --output evidence/storage.json storage
python3 tools/verify_freebsd.py --workspace /path/to/disposable-workspace --output evidence/gpu.json gpu
```

The storage check expects the synthetic browser workload first. Run it again after lock, unlock and reboot to check persistence. The NoctBSD overlay also provides `test_secret_store.py` and the visible GPU Studio. Raw local evidence contains machine paths and is deliberately excluded from publication.

## Remaining release work

`pkg audit -F` on the verification date reported **eight problems in seven installed packages**: Python 3.12, libXtst, expat, setuptools, libXrender, curl and libXpm. A refreshed upgrade plan offered only an unrelated firstboot helper update. The prototype is not cleared for sensitive browsing or release; affected packages need fixed builds or removal with regression checks.

Other release requirements include general GPU support, a smaller package image, hostile-app confinement, reviewed and signed updates with rollback, supported helper sandbox distribution, lifecycle handling for host sleep/termination, recovery and independent security review. The full updated overlay has not been re-provisioned from a clean base since the last changes; this report's guest received the corresponding files and configuration in place. Native Noct applications still need explicit ports.
