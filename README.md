# Noct Desktop

An encrypted desktop workspace for Apple Silicon Macs. The macOS shell runs a customized FreeBSD ARM64 guest with the Noct desktop, browser, Files and app installer.

**Research prototype.** Existing macOS Noct apps still need ports. This is not a hardened production operating system or a certified Noctweave client.

## Repositories

- **[NoctDesktop](https://github.com/luizwidmer/NoctDesktop)**: native macOS shell, encrypted vault, VM lifecycle and verification tools.
- **[NoctBSD](https://github.com/luizwidmer/NoctBSD)**: FreeBSD configuration, Noct desktop, guest apps and local secret SDK.

Keep the two source checkouts next to one another. VM disks, credentials, downloads, build products and raw local evidence are excluded from Git.

## Architecture

```text
macOS / Noct Desktop
  AES-256 encrypted APFS sparsebundle
    VM/FreeBSD/
      system.qcow2       FreeBSD, installed apps and all guest files
      uefi-vars.fd       writable firmware variables
      seed.iso, Keys/    bootstrap and management keys
      Home/, Cache/, Temp/, Logs/, Run/
```

QEMU uses Apple's Hypervisor Framework, two virtual CPUs and 1,536 MiB of guest RAM. Its resizable display is embedded in the native window over a private Unix socket. No shared host folders, shared clipboard, guest RAM save or host VNC TCP listener is configured. The guest display endpoint is confined to its private NAT interface. Management SSH is bound to host loopback, uses a vault-local key and pins the guest host key.

Lock requests an ACPI shutdown, waits for QEMU to exit, then detaches the encrypted image. A timeout or busy filesystem leaves an explicit error and an unsealed workspace. Quitting also attempts this sequence. Guest apps cannot remain running after a successful lock.

**Host RAM, swap, crash reports, screenshots, OS metadata and a compromised host are outside this storage guarantee.** Locking or sleeping the Mac is not yet a verified substitute for the workspace Lock action. Unexpected termination of the host shell can leave the vault mounted.

## Build and run

The macOS app and VM controller are Swift, built with Xcode. The FreeBSD desktop, browser, Files and local secret SDK are C++17. Neither shipped runtime requires Python. Python scripts retained here are build, verification or archived research tools.

Tested on Apple Silicon macOS 27.0.1 with Xcode 27 and Homebrew QEMU 11.1.2.

```sh
git clone https://github.com/luizwidmer/NoctDesktop.git
git clone https://github.com/luizwidmer/NoctBSD.git
brew install qemu
cd NoctDesktop
open NoctDesktop.xcodeproj
# Select the NoctDesktop scheme and Run.
# Or build from the terminal:
./tools/build-native.sh CODE_SIGNING_ALLOWED=NO
open "build/Xcode/Build/Products/Debug/Noct Desktop.app"
```

Create an encrypted workspace, unlock it and choose **Set up desktop**. The installer streams the pinned official cloud image directly into the vault and installs the guest desktop. The first base-system update may reboot once. Setup requires network access and several minutes.

The sparse vault has an 8 GiB logical capacity; the guest disk has 7.5 GiB logical capacity. These are capacities, not initial disk allocations. Installation stops if the host's 15 GiB free-space reserve is reached. This package-based prototype includes a large LLVM/graphics dependency; it is not yet a minimal release image.

The desktop provides draggable icons, a dock, Files with internal folders and folder creation, workspace settings, a WebKitGTK browser and an HTTPS web-app registry. Installed web apps get separate profile/cache/preferences directories. The web-app installer does not port macOS applications or verify publisher signatures.

The compact desktop uses Noctweave's plum, ivory, coral and wine colors, a floating dock, traffic-light window controls and a quiet menu bar. The guest resolution follows the native window and fullscreen at logical pixel density, with a 200 ms delay and a 1920×1200 cap. The native display scales frames with Metal, with an AppKit fallback. Software guest rendering remains the default; there is no Retina density mode.

The optional browser GPU backend connects Mesa/virgl to ANGLE Metal. WebGL 2, GPU Skia text/Canvas 2D and compositing pass focused pixel checks. The patched renderer dispatches ANGLE's real multisample extension and preserves integer glyph coordinates. Hardware video decode, WebGPU and zero-copy presentation remain unsupported/unverified. See [setup and measured GPU limits](docs/browser-gpu.md).

The earlier bounded-triangle GPU experiment remains in the research tools; it is not part of the new C++ desktop UI. See [its API and limits](docs/gpu.md).

The password is passed through stdin and is not saved in Keychain, arguments or configuration. There is no recovery. Keep your password.

## CLI

```sh
CLI=build/Xcode/Build/Products/Debug/NoctRuntime
"$CLI" --workspace /absolute/path create
"$CLI" --workspace /absolute/path unlock
"$CLI" --workspace /absolute/path setup-vm
"$CLI" --workspace /absolute/path launch-vm
"$CLI" --workspace /absolute/path status
"$CLI" --workspace /absolute/path lock
```

Create/unlock read the password from stdin. Do not put passwords in arguments. Close the GUI before CLI operations that restart or stop its guest. The app uses Application Support by default; developers may select a disposable workspace with `NOCT_DESKTOP_WORKSPACE`.

## Evidence and scope

See [FreeBSD verification](docs/freebsd-prototype.md) for measurements and remaining work. Raw local evidence and disposable disks are deliberately not published. The native Chromium/WebKit investigations remain available as [historical notes](docs/native-experiments.md); their results do not certify this guest runtime. `build/Noct Desktop Native.app` is the earlier native experiment.

The guest secret SDK uses AES-256-GCM, fresh nonces, authenticated app/record context and separate vault-local key files. This aligns the local encryption primitive with Noctweave's public requirements. It does not implement Noctweave relationships, post-quantum exchange, messaging, group authority or wire compatibility. Guest apps currently share one Unix user; their profile directories and SDK are cooperative separation, not hostile-app isolation.

The FreeBSD VM approach does not require Apple's Endpoint Security entitlement. An earlier research request was submitted; its withdrawal is being handled by the project owner.

Native vault lifecycle checks and the C++ secret authentication tests are documented in [native development](docs/native-development.md). Fresh image download/provisioning was ported to Swift; that entire first-install path has not yet been rerun with this revision.

## License

Project code is licensed under **GNU AGPL v3 (AGPL-3.0-only)**. See [LICENSE](LICENSE). FreeBSD, QEMU, WebKitGTK and other third-party software retain their respective upstream licenses.
