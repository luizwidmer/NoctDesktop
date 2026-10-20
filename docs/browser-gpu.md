# Experimental browser GPU backend

Test platform: Apple M4, macOS 27.0.1, FreeBSD 15.1-RELEASE-p5 ARM64,
Mesa 26.2.2, WebKitGTK 4.1 / 2.46.6_8. Local research, 20 October 2026.

**This is partial browser acceleration. Full browser GPU support is not achieved.**

| Path | Result |
| --- | --- |
| Native window presentation | Metal, with existing AppKit fallback |
| Guest hardware render node | Experimental virtio DRM driver; `/dev/dri/renderD128` |
| Mesa renderer | `virgl (ANGLE (Apple, ANGLE Metal Renderer: Apple M4, ...))`; `Accelerated: yes` |
| WebGL 1 | Compiled shader, draw, exact pixel readback and zero GL error passed |
| WebKit compositor | Hardware policy `always`; shared-memory presentation |
| Ordinary page painting / Canvas 2D | CPU Skia rendering; GPU tile painting loses text |
| WebGL 2 | Context creation fails; virtual GPU reports `GL_MAX_SAMPLES = 0` |
| WebGPU / hardware video decode | Not implemented or verified |
| Display transport | GPU readback, shared memory and RFB; no zero-copy claim |

The working path is:

```text
WebKit WebProcess / UID noct
  Mesa virgl -> FreeBSD virtio GPU DRM -> QEMU virglrenderer
    ANGLE Metal -> Apple GPU
  GPU compositor -> shared-memory pixels -> Xvnc/RFB -> native Metal view
```

WebKit's privacy-masked `Apple GPU` string alone is insufficient evidence. The
verification combines the actual host Metal renderer, guest Mesa hardware
renderer, WebProcess render-node descriptors, WebKit compositor policy, a
compiled WebGL shader and pixel readback. Page animation callbacks are not the
end-to-end display frame rate.

## Local verification results

The host runtime was rebuilt from the saved recipe, then the guest installer
was run through a cold restart. The final hardware-path verifier passed, while
its separate `full_browser_gpu` result remained `false`.

| Check | Observed result |
| --- | --- |
| WebGL shader | Pixel `[64, 191, 128, 255]`; GL error `0` |
| WebKit compositor policy | `always`; WebProcess opened `/dev/drm/128` |
| Rendered inspection | Normal page text, green shader canvas and animated CSS object visible |
| Host runtime binaries | 36,824,976 bytes / 35.1 MiB, excluding reused Homebrew dependencies |
| Added guest modules | 1,160,864 bytes total for four modules |
| Cold boot, one run | 41.22 s from launch to host-observed desktop readiness |
| Preceding orderly shutdown | 6.81 s |
| QEMU resident memory | 857 MiB after boot; about 1.14 GiB with the GPU test page |
| Storage after detach/reopen | Cookie, settings, caches, 8 MiB download and temporary-file placement passed |
| Host regular files open for writing | Confined to the encrypted VM directory in the final snapshot |
| Invalid guest DRM descriptor | Rejected with `EINVAL`; guest remained running |
| Lock with GPU browser open | VM and helper exited; encrypted volume detached in 10.22 s |
| Simulated stuck guest | A 2 s shutdown timeout reported failure and left the vault mounted; resumed guest then locked successfully |

These are local smoke measurements, not a controlled performance comparison or
graphics conformance certification. The GPU boot is slower than the earlier
software baseline. An earlier loopback browser workload on this graphics stack
loaded in 0.77 s; Canvas 2D painting in that workload remained on the CPU.
The VM still uses two virtual CPUs and 1,536 MiB of guest RAM. Firmware uses a
small 640×480 scanout and the ARM64 `eficom` serial console; Xvnc keeps the
existing independent dynamic desktop resolution.

Source/build directories and guest installer scratch were removed after the
successful builds. The retained runtime contains code and licenses, with no
workspace profile or user data. Raw local verification records are excluded
from Git under `evidence/browser-gpu-20261020-143427/`. After the final successful
lock, the synthetic encrypted test vault and alternative-backend probe scratch
were removed, recovering 7.08 GiB. The retained runtime, metadata, licenses and
build logs together occupy 35.4 MiB.

## Why the remaining features need more work

The Metal ANGLE backend exposes GLES 3.0, while virgl's multisample texture path
needs host features unavailable on this combination. Although guest Mesa
reports GLES 3.0, its sample queries return only one sample and MAX_SAMPLES zero.
Bundled WebKit ANGLE requires multisampling for its ES3/WebGL 2 contexts. We do
not override reported GL versions, advertise unsupported capabilities, or bypass
WebGL validation. See [ANGLE's capability checks](https://github.com/WebKit/WebKit/blob/webkitgtk-2.46.6/Source/ThirdParty/ANGLE/src/libANGLE/renderer/gl/renderergl_utils.cpp).

A bounded alternative probe of ANGLE Vulkan through MoltenVK also failed to
create an ES3 context. It is not included in the runtime. Full WebGL 2 requires
implementing the missing host/virgl features or a different compatible graphics
backend, followed by conformance testing. A new general GPU implementation and
virtual video codec support are separate engineering projects.

With the current stack, GPU Skia tiles lose ordinary text. The explicit CPU
painting workaround preserves correct text and feeds WebKit's GPU compositor.
`WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` selects shared-memory presentation without
disabling compositing; `WEBKIT_DISABLE_DMABUF_RENDERER=1` would disable the
compositor and is not used. These choices follow the [WebKit buffer-mode
implementation](https://github.com/WebKit/WebKit/blob/webkitgtk-2.46.6/Source/WebKit/UIProcess/gtk/AcceleratedBackingStoreDMABuf.cpp).

## Reproduce

Close the native Noct Desktop shell first: the explicit enable/disable commands
perform a cold restart, and the GUI intentionally locks when it observes guest
exit. Unlock the intended workspace through the CLI, then:

```sh
python3 tools/fetch_virgl_host.py
python3 src/freebsd_vm.py --workspace /path/to/workspace enable-browser-gpu
python3 tools/verify_browser_gpu.py --workspace /path/to/workspace --output evidence/browser-gpu.json
```

The builder requires Homebrew QEMU (for firmware and core libraries), Ninja,
pkg-config and Xcode command line tools. It builds only AArch64/HVF QEMU with
two jobs. It reuses existing Homebrew libraries without a global install,
streams three small checksum-pinned bottles, and removes source/build scratch
after success. The existing Homebrew QEMU installation is preserved. `--rebuild`
rebuilds explicitly; `--keep-build` retains scratch for debugging. A verified
manifest permits reuse without downloads. Running GPU VMs prevent replacement.
The 15 GiB host free-space floor is monitored during downloads and compilation.

The guest installer uses the existing package catalogue and rejects mismatched
kernel/source versions. If the catalogue has expired, update the guest package
catalogue before retrying. It extracts only the matching kernel headers and
generators, excludes unrelated AMD/Intel/Radeon driver trees, builds four
stripped modules, and removes its private build/package scratch. It does not
build or retain a full kernel tree. Initial download includes the approximately
88 MiB compressed source package and 42 MiB driver archive, used in separate
phases. It explicitly uses the base LLVM linker/objcopy and checks module
metadata before installation; the ports GNU linker produced unloadable ARM64
modules in the initial reproduction. Guest source synchronization restores
script executable modes, and enablement checks for a render node and Xvnc
after the cold restart. The usual 8 GiB sparse vault remains supported.

To return to the default software backend, with the shell closed:

```sh
python3 src/freebsd_vm.py --workspace /path/to/workspace disable-browser-gpu
```

## Pinned inputs and local changes

| Component | Pin |
| --- | --- |
| QEMU fork | `https://gitlab.com/milesbuckton/qemu.git`, `7be5fa18e0a654678205799942c18673c2d87299` |
| Local QEMU changes | `tools/patches/qemu-virgl-metal-headless.patch` |
| ANGLE Metal bottle | startergo `v1.0.17`, SHA-256 `bf9f0be551197eed7f29312f88ad4e5ed47c97b80a7c157228d09325346f57a1` |
| libepoxy bottle | SHA-256 `a9a47d808e0333de4564060f9378874b267f870fc5f1549dd9d1cc78cc2dde4a` |
| virglrenderer bottle | SHA-256 `e84cb1159894388c6be6cbc1a55a335aa358f356e2c8fce2410f706a1e725693` |
| Guest DRM fork | borovikovd/drm-kmod, `fa44e452f2d3291710a4d4c19b89e2edcd13d6b9` |
| Guest archive SHA-256 | `2311bc08753e47c9fc346613d5add57d733455837ece85d3b803551af75ae372` |
| Guest compatibility patch | NoctBSD `overlay/opt/noct/freebsd15-virtio-gpu.patch` |
| FreeBSD header reference | `0ce9d6e240a14d5b7cd8eb45a83d0e429f4a3edf` |

The host patch selects Metal explicitly, releases the startup EGL context before
thread handoff, checks initialization/cleanup context binding, and fixes vertex
array deletion. Earlier unselected/OpenGL ANGLE paths crashed during cleanup;
they are not used. These are local Noct experiments, not upstream QEMU
contributions. A remaining cleanup-context `EGL_BAD_ACCESS` warning was observed
during GPU shutdown, although the process exited and the image detached. No
GPU-memory zeroization guarantee is made. Third-party licenses and input
metadata are retained locally, including a checksum-pinned ANGLE license fetched
from the revision reported by the runtime because its bottle omits that notice.

The guest driver comes from open [FreeBSD drm-kmod PR 517](https://github.com/freebsd/drm-kmod/pull/517),
with a local 15.1 compatibility backport. It is not a supported FreeBSD release
driver. The patch adapts string/ctype calls and matching LinuxKPI wrappers,
retaining the FreeBSD copyright notices. An invalid file-descriptor destructor
is guarded before calling 15.1's `fput`. The stock vtgpu console driver and DRM
fbdev emulation are disabled; no live graphics-module unload is attempted.

Mutable release URLs are checksum pinned and fail closed if changed. The Metal
bottle's embedded source-commit file is empty; the reproducible input is its
version and artifact hash, not an invented source revision. The runtime is
locally ad-hoc signed for the Hypervisor Framework. No new Apple entitlement is
required.

## Encrypted storage and lock

The GPU QEMU process inherits vault-local HOME, TMPDIR and XDG cache paths. Its
research Seatbelt policy denies regular-file writes outside the VM vault, apart
from `/dev/null`; core dumps are disabled. Mesa shader caches, WebKit profiles,
cookies, caches, preferences, downloads and guest system temporary paths all
remain on the encrypted guest disk. No shared host folder, host GPU TCP port,
browser security override, clipboard bridge, guest swap or saved RAM is added.

Process discovery covers both QEMU binaries. Lock requests ACPI poweroff, waits
for the GPU VM and optional triangle helper to exit, and then detaches the
encrypted image. A shutdown timeout leaves the vault mounted and explicitly
unsealed. No forced detach or RAM snapshot is used. The GUI clears its display
on successful lock.

Open-file snapshots bound the process write claim; they do not certify every
macOS service or GPU-driver write. Host RAM/swap, GPU memory, screenshots,
diagnostic reports and OS metadata remain outside this storage guarantee.
`sandbox-exec` is a deprecated research mechanism. The existing host sleep,
crash and distribution limitations still apply.
