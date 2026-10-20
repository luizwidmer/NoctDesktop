# Noct GPU prototype

Status: experimental, verified on Apple M4 / macOS 27.0.1 / FreeBSD 15.1 ARM64, 20 October 2026.

## What works

The native display presents the guest framebuffer with Metal. It uploads RFB pixels to immutable GPU textures, scales them in a fixed render pipeline, coalesces pending frames, limits GPU submissions and draws only when content changes. AppKit drawing remains a fallback if Metal initialization fails. Metal presentation alone does not accelerate WebKit. A separate [experimental browser backend](browser-gpu.md) now provides hardware WebGL 1 and WebKit compositing, with explicit remaining limits.

A separate **NoctGPUBroker** executes a small, first-party triangle API on the Mac GPU. FreeBSD apps use `noct_gpu.py` over a private virtio-serial port. GPU Studio, available from guest Settings, renders a colored triangle and lets the user change its geometry. The GPU executes the render pass; returned pixels are displayed in the guest through GTK. No external rendering service is involved.

The verified guest test, running as UID 1001, received the expected red center and black corner pixels, changed its output when the input turned green, and rejected five invalid requests. The host test rejects six invalid requests. Both identify Apple M4 and collect Metal command-buffer GPU timestamps. These prove GPU execution, not an application speedup: serialization, serial transport, readback and guest presentation add overhead.

## Transport and limits

```text
Noct app / UID noct
  /dev/ttyV0.1, group video, 0660
    virtio-serial port org.noctdesktop.gpu
      QEMU Unix chardev in the mounted vault
        NoctGPUBroker -> fixed Metal shaders -> bounded RGBA surface
```

No host GPU TCP listener, shared folder or clipboard is added. Cooperating guest clients serialize access with a private runtime lock. They do not get a host file, shader compilation or command execution API.

Protocol v1:

- Request: four-byte big-endian JSON length, followed by JSON; maximum 1 MiB.
- Response: four-byte big-endian JSON length, acknowledged by byte `0x06`; then JSON in chunks of at most 1024 bytes, each acknowledged by `0x06`. This prevents overflow of FreeBSD's tty input queue.
- Operations: `info`, or `render` with width, height, clear RGBA and triangle vertices `[x,y,r,g,b,a]`.
- Version must be integer 1. Surface dimensions are integers from 16 through 512. At most 12,288 vertices, in complete triangles. Coordinates are finite values in [-1,1]; colors in [0,1].
- Response pixels are base64 RGBA8 with exact dimensions and a SHA-256 checksum. A checksum detects transfer errors; the host remains trusted.
- One sequential channel, a 30 request/second ceiling, bounded messages, finite timeouts and fixed shaders. No guest Metal source or native handles are accepted.

The client is a proof API, not a graphics compatibility driver. It has no textures, depth buffers, blending, OpenGL, Vulkan, WebGPU, shared GPU memory, video decoding or general compositor integration. Serial readback is unsuitable as the final high-performance display transport. Malformed framing or a channel timeout may require restarting the desktop. Apps currently share a guest UID.

## Storage and lock

The helper inherits vault-local HOME, TMPDIR and XDG directories. Its additional research Seatbelt policy denies file writes outside the vault (apart from `/dev/null`). This prevents its attempted writes to macOS's normal compiled shader cache; the Metal pixel test succeeds under that restriction. Open writable regular files are checked by the verification tool.

The helper is stopped after guest shutdown and before detaching the encrypted image. Lock fails explicitly if either process remains. There is no saved GPU or guest RAM image.

The native Mac shell and macOS services can still create ordinary UI metadata and caches for the fixed public shaders. Host RAM, swap, screenshots, diagnostic reports, GPU driver behavior and system service metadata are outside the guest-storage guarantee. Neither the helper policy nor an open-file snapshot certifies all system writes. `sandbox-exec` is a deprecated research mechanism; a supported distribution strategy and independent review are release requirements.

New prototype workspaces enable `noct_gpu` in their non-secret runtime configuration. Existing workspaces may opt in only after building the helper and installing the updated NoctBSD overlay. Setting it to false before starting the VM omits the experimental serial device and helper.

## Browser acceleration

The default Homebrew QEMU still lacks the required compiled 3D device. The
optional local runtime now builds a separate AArch64/HVF QEMU with virgl and
Metal ANGLE, and NoctBSD provides a matching experimental 15.1 DRM backport.
Hardware renderer and WebGL pixel tests pass. This extends beyond the limited
triangle API above, but it is not full browser acceleration: CPU page painting,
WebGL 2, video decoding and display readback remain limitations.

See [browser setup, pinned sources, verification and remaining work](browser-gpu.md).
