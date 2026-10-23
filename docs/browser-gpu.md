# Experimental browser GPU backend

Test platform: Apple M4, macOS 27.0.1, FreeBSD 15.1-RELEASE-p5 ARM64,
Mesa 26.2.2, WebKitGTK 4.1 / 2.46.6_8. Local research, 20 October 2026.

**GPU page/text painting, compositing and WebGL 2 now pass focused checks.** Hardware video decode and WebGPU remain unsupported/unverified.

| Path | Result |
| --- | --- |
| Native window presentation | Metal, with AppKit fallback |
| Guest render node | Experimental virtio DRM; `/dev/dri/renderD128` |
| Mesa | `virgl (ANGLE (Apple, ANGLE Metal Renderer: Apple M4, ...))`; accelerated |
| WebGL 2 | Shader/pixel, 4× MSAA resolve, 3D R8, VAO instancing, integer inputs, R8 atlas subrect passed |
| Page/Canvas 2D text | GPU Skia; 1,624 foreground glyph pixels, visible DOM and canvas text |
| WebKit compositor | Hardware policy `always`, WebProcess render-node descriptor verified |
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

The small renderer was rebuilt from its pinned source and saved patch using `--renderer-only`; QEMU was reused after checksum verification. The native C++ browser returned `hardware_path_passed: true`, `webgl2_passed: true`, and `gpu_text_passed: true`. `full_browser_gpu` remains false because video/WebGPU and zero-copy presentation are not implemented. These checks are not a WebGL conformance certification.

The retained six runtime binaries total **35,327,552 bytes (33.7 MiB)**, excluding reused Homebrew libraries and firmware. The stripped C++ desktop/browser binary is approximately 250 KiB. The local loopback storage/browser workload loaded in 0.79 s in one run; shader startup/cache state affects this result. Page animation callbacks are not display FPS. The guest still uses two virtual CPUs and 1,536 MiB RAM.

Synthetic local evidence is excluded from Git under `evidence/browser-gpu-20261020-170955/`: `native-browser-gpu.json`, `native-runtime.json`, storage/persistence and lock records. Earlier prototype measurements and limitations remain in [FreeBSD verification](freebsd-prototype.md).

## What changed

ANGLE Metal exposes GLES 3.0 plus the real `GL_ANGLE_texture_multisample` extension. The extension uses ANGLE-suffixed functions; virgl previously missed that path. The patch checks the extension and its function pointers, dispatches its 2D multisample storage/sample-mask/sample-position entry points, and emits the matching shader extension. Multisample texture arrays are rejected on this 2D-only extension path. No ES 3.1 claim or GL version override is introduced. See the [ANGLE extension specification](https://github.com/google/angle/blob/b82a564646a2/extensions/ANGLE_texture_multisample.txt).

The text failure was isolated to glyph atlas vertex coordinates. Virgl used float inputs to transport integer bit patterns. Its typed-integer workaround was vendor-selected, and its integer attribute masks were populated only in the GLES 3.1 binding path. The patch selects typed inputs for ANGLE Metal and fills the masks when vertex elements are created, covering the GLES 3.0 legacy binding path as well. GPU canvas text changed from zero foreground pixels to 1,624, and ordinary DOM text became visible. Pixel checks remained correct after rebuilding without debug logging.

GPU Skia painting is enabled in `/etc/noct/gpu.json`. The explicit CPU painting option remains available for diagnosis. `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` keeps shared-memory presentation while retaining compositing; no browser sandbox-disabling switch is added.

## Reproduce

Close the native Noct Desktop shell first: the explicit enable/disable commands
perform a cold restart, and the GUI intentionally locks when it observes guest
exit. Unlock the intended workspace through the CLI, then:

```sh
python3 tools/fetch_virgl_host.py
build/Xcode/Build/Products/Debug/NoctRuntime --workspace /path/to/workspace enable-browser-gpu
python3 tools/verify_browser_gpu.py --workspace /path/to/workspace --output evidence/browser-gpu.json
```

The build-only Python tool requires Homebrew QEMU (firmware/core libraries), Meson, Ninja, pkg-config and Xcode command line tools. Neither shipped runtime launches Python. It builds only AArch64/HVF QEMU with
two jobs. It reuses existing Homebrew libraries without a global install,
streams three small checksum-pinned bottles, and removes source/build scratch
after success. The existing Homebrew QEMU installation is preserved. `--rebuild`
rebuilds explicitly; `--keep-build` retains scratch for debugging. A verified
manifest permits reuse without downloads. `--renderer-only` rebuilds just the small renderer, using a private build-only PyYAML environment and removing its scratch afterward. Running GPU VMs prevent replacement.
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
build/Xcode/Build/Products/Debug/NoctRuntime --workspace /path/to/workspace disable-browser-gpu
```

## Pinned inputs and local changes

| Component | Pin |
| --- | --- |
| QEMU fork | `https://gitlab.com/milesbuckton/qemu.git`, `7be5fa18e0a654678205799942c18673c2d87299` |
| Local QEMU changes | `tools/patches/qemu-virgl-metal-headless.patch` |
| ANGLE Metal bottle | startergo `v1.0.17`, SHA-256 `bf9f0be551197eed7f29312f88ad4e5ed47c97b80a7c157228d09325346f57a1` |
| libepoxy bottle | SHA-256 `a9a47d808e0333de4564060f9378874b267f870fc5f1549dd9d1cc78cc2dde4a` |
| virglrenderer source | `f599855944c9fdf706f28dd9c41a2d8256b7f3a4`, archive SHA-256 `49b23a83e9206b0b834c8e2758fbe4a1b6bfc4cb4eb0db9633df92d077437028` |
| Local renderer changes | `tools/patches/virgl-angle-multisample.patch` |
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
