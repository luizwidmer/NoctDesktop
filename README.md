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

Tested on Apple Silicon macOS 27.0.1 with Xcode command line tools, Python 3.14 and Homebrew QEMU 11.1.2.

```sh
git clone https://github.com/luizwidmer/NoctDesktop.git
git clone https://github.com/luizwidmer/NoctBSD.git
brew install qemu
cd NoctDesktop
python3 tools/build.py
open "build/Noct Desktop.app"
```

Create an encrypted workspace, unlock it and choose **Set up desktop**. The installer streams the pinned official cloud image directly into the vault and installs the guest desktop. The first base-system update may reboot once. Setup requires network access and several minutes.

The sparse vault has an 8 GiB logical capacity; the guest disk has 7.5 GiB logical capacity. These are capacities, not initial disk allocations. Installation stops if the host's 15 GiB free-space reserve is reached. This package-based prototype includes a large LLVM/graphics dependency; it is not yet a minimal release image.

The desktop provides draggable icons, a dock, Files with internal folders and folder creation, workspace settings, a WebKitGTK browser and an HTTPS web-app registry. Installed web apps get separate profile/cache/preferences directories. The web-app installer does not port macOS applications or verify publisher signatures.

The shell and guest use Noctweave's plum, ivory, coral and wine colors. The guest resolution follows the native window and fullscreen at logical pixel density, with a 200 ms delay and a 1920×1200 cap. The native display scales frames with Metal, with an AppKit fallback. Software guest rendering remains the default; there is no Retina density mode.

An experimental **Noct GPU** API lets first-party guest apps render bounded triangles on the Mac's GPU through a private virtio-serial channel. Open **Settings → GPU Studio** for the visible proof. The helper has an additional file-write restriction and exits before vault detachment. This is not an OpenGL/Vulkan driver or browser acceleration. See [GPU implementation and limits](docs/gpu.md).

An optional **browser GPU backend** now connects guest Mesa/virgl to ANGLE Metal. Hardware WebGL 1 and WebKit compositing work. CPU page painting is retained to avoid missing text; WebGL 2, hardware video decode and WebGPU are not working/verified. The small local runtime and matching guest-driver installer preserve the encrypted disk and shutdown-before-unmount sequence. See [setup, evidence and remaining GPU limits](docs/browser-gpu.md). Full browser acceleration is not achieved.

The password is passed through stdin and is not saved in Keychain, arguments or configuration. There is no recovery. Keep your password.

## CLI

```sh
python3 src/freebsd_vm.py create
python3 src/freebsd_vm.py unlock
python3 src/freebsd_vm.py setup-vm
python3 src/freebsd_vm.py launch-vm
python3 src/freebsd_vm.py status
python3 src/freebsd_vm.py lock
```

Place `--workspace /absolute/path` before the action to select a workspace. Do not put passwords on command lines.

## Evidence and scope

See [FreeBSD verification](docs/freebsd-prototype.md) for measurements and remaining work. Raw local evidence and disposable disks are deliberately not published. The native Chromium/WebKit investigations remain available as [historical notes](docs/native-experiments.md); their results do not certify this guest runtime. `build/Noct Desktop Native.app` is the earlier native experiment.

The guest secret SDK uses AES-256-GCM, fresh nonces, authenticated app/record context and separate vault-local key files. This aligns the local encryption primitive with Noctweave's public requirements. It does not implement Noctweave relationships, post-quantum exchange, messaging, group authority or wire compatibility. Guest apps currently share one Unix user; their profile directories and SDK are cooperative separation, not hostile-app isolation.

The FreeBSD VM approach does not require Apple's Endpoint Security entitlement. An earlier research request was submitted; its withdrawal is being handled by the project owner.

## License

Project code is licensed under **GNU AGPL v3 (AGPL-3.0-only)**. See [LICENSE](LICENSE). FreeBSD, QEMU, WebKitGTK and other third-party software retain their respective upstream licenses.
