# Historical native macOS experiments

These results predate the FreeBSD architecture. Local evidence is excluded from Git.

# Noct Desktop — native encrypted workspace prototype

A native macOS desktop with draggable app and folder icons, a dock, an internal Files panel and an encrypted volume. No VM, container guest, privileged service, or changes to SIP or Gatekeeper.

**Result as of 20 October 2026: the encrypted storage and lock lifecycle work. Complete write confinement does not pass.** macOS still writes a Chromium preferences plist and a temporary replacement plist outside the volume. Do not put real accounts or confidential data into this research build.

## Run the app

Open `build/Noct Desktop.app`. Create a workspace with a new password and unlock it to enter the desktop. Double click an icon, or use the dock. The Chromium icon installs the research browser inside the encrypted volume on first use and launches it afterward. Chromium opens its own native window. The desktop can enter full screen; it does not embed Chromium's native windows.

Files opens an internal file browser with Desktop, Documents and Downloads. New folder creates folders inside the volume. Import files copies regular files into the selected workspace folder and leaves their originals in place. Opening arbitrary files in host apps and editing file contents are not implemented. Icon positions are stored inside the encrypted volume. Desktop file commands reject traversal and symlink escapes and are unavailable while locked.

**Lock** closes that workspace's Chromium and unmounts its volume. The desktop clears its file list and icon layout from the UI while locking. Quitting also attempts to lock; it cancels quitting if locking fails. A successful lock is shown only after the image detaches.

The password is not saved in Keychain or in a configuration file. Keep it: this prototype has no password recovery.

Build and download prerequisites, if needed:

```sh
rtk proxy python3 tools/fetch_chromium.py
rtk proxy python3 tools/build.py
```

Requirements: Apple Silicon macOS, Python 3.11 or newer, Xcode command line tools. Tested on macOS 27.0.1 (26A434), arm64. The launcher records this machine's Python and project paths in its bundle. Keep the project in place, or rebuild after moving it. It is a local development app, not an installer or notarized release.

## What was verified

The initial functional baseline is `evidence/20261020-114342/report.json`. Its overall result is **false**; that deliberately includes the outside-file checks. `storage_lifecycle_passed` is **true**, while `observed_write_confinement_passed` is **false**. Follow-up runs preserve that result.

The latest desktop interaction run is `evidence/desktop-20261020-120905/report.json`: all 11 checks passed, including actual GUI folder creation, a dragged icon persisted across encrypted reopen, file import and overwrite refusal, traversal/symlink rejection, and lock/quit with Chromium running. The restored icon position was also inspected in the rendered desktop after an actual lock and unlock. The disposable image was detached and removed afterward. This verifies desktop behavior; it does not certify arbitrary Noct app compatibility.

The lightweight browser investigation is recorded in `docs/runtime-plan.md`. `evidence/webkit-storage-api.json` records an actual WebKit API capability probe: localStorage export is accepted; cookies and IndexedDB are rejected by that export API. This is not a browser storage-confinement result.

| Check | Result |
| --- | --- |
| Create AES-256 encrypted APFS sparsebundle; wrong password rejected | Passed |
| Install Chromium inside the encrypted filesystem | Passed |
| Profile, history, cookies, localStorage, IndexedDB, CacheStorage, service worker | Created and exercised inside the volume |
| HTTP disk cache | Inside the volume; repeated request served from cache |
| Actual partial `.crdownload` and completed 8 MiB download | Inside the volume |
| Chromium temporary file activity | Observed inside the volume |
| Writable regular-file handles sampled from workspace Chromium processes | No outside handles in the final functional run |
| Chromium renderer sandbox | Six live renderers reported sandboxed via `sandbox_check` |
| Close, unmount, reject launch while locked | Passed |
| Reopen and recover stored web data | Passed |
| Lock button can stop a running browser | Passed |
| File held open by another process | Lock fails honestly; volume remains unlocked until the handle closes |
| No Chromium filesystem activity outside the volume | **Failed: macOS preferences and preference temporary file** |

The run retained 734 file events, 6,017 writable-handle samples, and a 197-file volume inventory. These are observations from a bounded synthetic workload, not proof of absence of other writes. The native launcher's visible unlocked/locking/locked states were also inspected, and its Lock button was checked against the actual detached image (`evidence/gui-lock-check.json`).

### Remaining outside paths

The final functional run observed:

```text
~/Library/Preferences/org.chromium.Chromium.plist
/private/var/folders/<user>/T/TemporaryItems/org.chromium.Chromium.plist.<random>
```

The persistent plist was an empty dictionary when inspected. That reduces the content exposed in this particular run; it does **not** satisfy a rule requiring all assigned-app storage, including temporary files, to stay inside the vault. No claim is made about its content under other browsing workloads.

An earlier configuration also wrote native Chromium temporary files and Metal shader caches into the user's Darwin temp/cache directories. The working configuration adds `MAC_CHROMIUM_TMPDIR` and uses software rendering with `--disable-gpu`. The Metal-cache switch alone did not eliminate the observed Metal handles.

An additional `sandbox-exec` policy denying outside writes and user-preference writes was tested in `evidence/20261020-113508/`. It prevented Chromium's helpers from initializing their own sandboxes, and the browser failed. **That policy is disabled in the usable launcher.** Chromium's own sandbox stays enabled. The experimental code remains available through the Python API's explicit `restrict_writes=True` parameter for research only.

### Preference investigation

`evidence/20261020-115016/report.json` tested `__CFPREFERENCES_AVOID_DAEMON=1` with the fixed home and temp paths. The same outside plist and temporary replacement were observed. This private switch is disabled by default; the test can be reproduced with `WORKSPACE_TEST_DIRECT_PREFERENCES=1`.

`evidence/20261020-120147/` adds opt-in preference call instrumentation to the unchanged development snapshot. It traces Chromium removing the native defaults `AppleTextDirection` and `NSForceRightToLeftWritingDirection`, then synchronizing its application domain. This matches Chromium's `cocoa_l10n_util::ApplyForcedRTL()` source and explains why even an empty plist is rewritten. A later `LastRunAppBundlePath` CFPreferences write was also traced. Six live renderers still reported an active sandbox in that instrumented run. The same two confinement checks still fail; instrumentation is not redirection.

The tracing library changes no preference behavior, records no values, and is restricted to disposable `Verification-` workspaces. Normal app launches strip `DYLD_*` variables and use no injected library. A third-party preference adapter has not been shipped. For first-party Noct apps, use an explicit workspace preferences backend through a shared runtime SDK rather than depending on process-wide overrides.

## How storage is arranged

The default workspace is `workspaces/Personal/`. It contains the encrypted `Workspace.sparsebundle` and nonsensitive lifecycle metadata. The 4 GiB image grows as data is written; it does not allocate all 4 GiB immediately.

Unlocked images mount at a private, random path below `~/.ew-mounts/`. This keeps Chromium's Unix socket path below macOS's length limit.

```text
Encrypted mounted filesystem
├── Applications/Chromium.app
├── Data/Chromium/             profile, site data, Crashpad location
├── Cache/Chromium/            HTTP and code caches
├── Downloads/                completed and partial downloads
├── Temp/                     Chromium's configured temporary directory
├── Home/Library/              a compatibility home folder tree
├── Home/Desktop/              desktop user files
├── Home/Documents/            workspace documents
├── Data/Desktop/layout.json   draggable icon positions
├── Logs/                      browser output
└── Run/                       launcher process metadata
```

The launcher sets `--user-data-dir`, `--disk-cache-dir`, download preferences, `TMPDIR`, `MAC_CHROMIUM_TMPDIR`, `HOME`, and `CFFIXED_USER_HOME`. The last two are compatibility settings; they do not virtualize macOS services or create a fake OS.

Locking checks the exact installed application path, sends an orderly termination request to that browser, waits for its helpers to stop, then asks macOS to detach this image. It never kills the user's normal Chrome, never force-unmounts, and only reports locked after the image is detached. A busy image or failed operation is an error, not a successful lock.

### Research configuration

- Official Chromium development snapshot **1722776**, version **158.0.8114.0**, pinned by archive SHA-256. Its linker-signed executables have no complete application resource seal; it is not a signed/notarized production browser. The installer records this diagnostic without re-signing Chromium or changing OS protections.
- All prototype launches use Chromium's **mock Keychain** to keep the test away from the real login Keychain. Its cookie encryption key is deterministic test material. The encrypted disk image provides the meaningful at-rest protection in this prototype; mock Keychain is not suitable as a production secret provider.
- Software rendering avoids the Metal cache paths observed in the first runs. GPU performance and hardware video were not evaluated.
- Normal launches expose no debugging port. The verifier enables a temporary loopback CDP endpoint for synthetic automation only.
- Sync, saved passwords, default-browser prompts, and background operation are disabled. These switches are not a complete network privacy or telemetry policy.

## Reproduce verification

```sh
rtk proxy python3 tools/build.py
rtk proxy python3 tools/verify_workspace.py
```

The harness creates a fresh disposable encrypted workspace, generates its password only in memory, serves a local synthetic test page, uses real GUI Chromium, samples file handles, records file events, and tests lock/reopen/busy-volume behavior. It returns a nonzero exit code when confinement checks fail. `evidence/latest.json` points to the newest report.

The evidence contains only generated canaries, synthetic files, browser diagnostics and relevant filesystem paths. Unrelated file events are discarded. The verification password is not persisted; completed verification images are locked and cannot be reopened after that process exits.

Useful evidence files:

- `report.json`: results, browser provenance, configuration, exact outside paths.
- `vault-files.json`: files actually found in the encrypted workspace.
- `filesystem-events.json`: relevant file-level FSEvents, without PID attribution.
- `writable-file-handles.json`: repeated `lsof` samples of this workspace's processes.
- `chromium-proof.png`: rendered browser storage exercise.

### Verification limits

FSEvents has no PID attribution; `lsof` is sampled and can miss short-lived files. Watching known paths does not cover every possible name or system-service-mediated write. The functional workload did not exercise real accounts, extensions, printing, file pickers, uploads, audio/video devices, deliberate crashes, or OS screen locking. A real kernel trace is still needed for stronger attribution, and service-mediated writes need separate coverage.

This prototype locks through its own button, CLI command, or orderly quit. **Locking the Mac's screen or putting it to sleep does not currently guarantee that the workspace has been unmounted.** Use the workspace lock operation and verify completion. Unexpected launcher termination can leave the image mounted.

## Endpoint Security entitlement

Request **[private request ID omitted]** for `com.apple.developer.endpoint-security.client` was submitted through the signed-in Apple Developer account. Apple displayed its submission confirmation and said it will review the request. **Submitted is not granted.** Details are in `evidence/entitlement-request.json`.

The intended next verifier uses macOS's descendant-scoped Endpoint Security API to attribute filesystem operations to Chromium and its children. The local SDK says this mode needs the restricted entitlement but no root or Full Disk Access. The compiled unsigned probe returns `ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED` (3).

After Apple grants access, signing and provisioning must be refreshed for the approved team. The currently installed development signing identity belongs to a different team from the one used by the request. Merely adding an entitlements plist to an ad-hoc signature will not grant access. No privileged monitoring agent is installed by this prototype.

Endpoint Security improves observation and can support selected authorization checks; it does not provide filesystem path virtualization or automatically fix cfprefsd writes.

## CLI

All operations use an exclusive workspace lock. Password entry is through a hidden terminal prompt; the GUI passes it through an anonymous stdin pipe. Do not put a password in command arguments, environment variables, or shell history.

```sh
rtk proxy python3 src/workspace.py create
rtk proxy python3 src/workspace.py unlock
rtk proxy python3 src/workspace.py install
rtk proxy python3 src/workspace.py launch
rtk proxy python3 src/workspace.py lock
rtk proxy python3 src/workspace.py status
```

For an explicit workspace, put `--workspace /absolute/path` before the action.

## Feasibility conclusion

A lightweight native launcher can install a browser and its major data stores onto a volume that becomes unavailable after an orderly lock. This prototype demonstrates that with Chromium.

A normal macOS process still shares host services and OS-defined directories. Environment variables and app flags do not enforce a universal storage boundary, and the tested outer Seatbelt wrapper was incompatible with Chromium's inner sandbox. An installed app copy is unavailable when this image is locked, but there is no policy preventing someone from copying/running another copy while unlocked.

The next version needs deliberate browser integration for preferences, temporary paths, OS-backed caches and secrets, plus stronger tracing and host-lock handling. Support for arbitrary existing apps would require a separate compatibility and enforcement design. No claim is made that the host OS, another process in the same unlocked session, a privileged attacker, RAM, swap, screenshots, clipboard, backups, or all system metadata are isolated by this volume.

The accepted product direction is **Noct apps first**, followed by selected third-party ports. See [Runtime and browser plan](docs/runtime-plan.md) for the compatibility contract and the WebKit browser recommendation. Existing Noct app repositories were inspected read-only; they have not yet been ported or certified for this runtime.

### Primary references

- [Chromium user data directory documentation](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)
- [Chromium macOS temporary-directory implementation](https://chromium.googlesource.com/chromium/src/+/main/base/files/file_util_apple.mm)
- [Chromium macOS sandbox parameters and Darwin directories](https://chromium.googlesource.com/chromium/src/+/main/content/browser/sandbox_parameters_mac.mm)
- [Chromium native text-direction preference mutations](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/cocoa/l10n_util.mm)
- [Chromium installer use of the private preference daemon switch](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/mac/install.sh.in)
- [Official Chromium download guidance](https://new.chromium.org/getting-involved/download-chromium/)
- [Apple encrypted disk image documentation](https://support.apple.com/guide/disk-utility/create-a-disk-image-dskutl11888/mac)
- [Apple Endpoint Security entitlement request](https://developer.apple.com/contact/request/system-extension/)
