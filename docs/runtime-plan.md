> Historical native runtime plan. The active architecture is FreeBSD ARM64; see [the current README](../README.md).

# Noct Desktop runtime and browser plan

## Product direction

Noct Desktop is a native encrypted workspace with desktop icons, a dock and workspace files. Install compatible apps directly inside the encrypted filesystem. First support our own Noct apps through deliberate integration; port selected outside apps later. No VM or fake guest operating system is required for that cooperative model.

Installing an app in the volume controls where its executable lives. A runtime must additionally control its storage and shutdown behavior. Installation alone does not redirect macOS preference services, WebKit processes, keychains, caches or native temporary files.

This document defines the next integration work. No existing Noct app is currently certified for Noct Desktop. The implemented prototype is the desktop shell, encrypted filesystem lifecycle and bounded Chromium experiment.

## Runtime responsibilities

1. Verify an app package and its declared runtime version, install it on the mounted image and record its provenance there. Never run installers that create host login items, services or background agents implicitly.
2. Supply a per-app runtime context: app ID, workspace ID, data, preferences, caches, temporary files, logs and user-selected document locations. Match this context to the mounted volume identity; refuse startup when it is unavailable.
3. Give first-party apps explicit storage APIs. Persist app settings through a workspace file backend, using atomic temporary files in the same encrypted directory. Avoid `UserDefaults.standard`, global URL caches and default Keychain storage for workspace secrets. Set a deliberate policy for every framework that can persist data.
4. Preserve each app's normal process sandbox and cryptographic protocol boundaries. A shared desktop is not an authority linking Noctweave relationships, groups or personas. The volume key does not replace relationship/group encryption and must never be sent to a relay.
5. Track each app and its workers. On lock, ask apps to finish or cancel work, flush data, close databases, stop media/network tasks and release files. Wait for acknowledgement and exit; detach only when the volume can actually be detached. A timeout or busy volume means lock failed, not that storage is sealed.
6. Clear document previews, file lists and other workspace content from the desktop UI on lock. Native apps launched outside a workspace must use their ordinary independent storage, with no silent fallback from workspace mode into host folders.

The runtime context is a cooperative API, not an OS-enforced filesystem namespace. Stronger prevention of malicious or unported app writes requires additional enforcement and separate evidence. Environment variables are compatibility settings, not a security boundary.

### Suggested layout

```text
Encrypted filesystem
  Applications/<app>.app
  Runtime/installed-apps.json
  Apps/<app-id>/Data/
  Apps/<app-id>/Preferences/
  Apps/<app-id>/Cache/
  Apps/<app-id>/Temp/
  Apps/<app-id>/Logs/
  Home/Desktop/
  Home/Documents/
  Downloads/
```

A small Swift package is the natural first SDK for the currently inspected native Swift apps. It should accept explicit runtime context, validate its lifetime, provide file-backed preferences and storage roots, and expose a pre-lock flush/close interface. An SDK alone cannot stop code that bypasses it; compatibility requires reviewing and testing the app's actual storage paths.

## Initial app inventory

Read-only inspection of local packages and documentation on 20 October 2026:

| App | Existing foundation | Workspace integration still needed |
| --- | --- | --- |
| Noctweb Browser | SwiftUI + WebKit; publication-scoped nonpersistent renderer | Replace application `UserDefaults` persistence, route local resolver/state files, verify WebKit auxiliary writes and lock lifecycle |
| NoctCord | Swift core/UI + WebRTC | App state and preferences, identities/secrets, media logs and temp/cache paths, clean call shutdown before lock |
| NoctBoard | Swift core/UI/transport | Main client state plus its `.noctboard-private` admission journal together, app settings, transport shutdown and reopen recovery |
| NoctGallery | iPhone/iPad SwiftUI + PhotoKit + AVFoundation | Requires a macOS UI/platform port in addition to runtime storage integration; inventory media pipelines, credentials and extension behavior |

These are integration targets, not completed ports. Preserve each project's own instructions and protocol tests. Do not migrate a user's existing state as part of testing; start with disposable workspace fixtures.

### Compatibility acceptance

For each app, exercise real rendered workflows and every persistent store: startup, preferences, document edits, database recovery, caches, downloads/imports, secrets, errors, reopen, lock during activity and a busy-file failure. Trace app and worker writes plus service-mediated writes. Verify sandboxing and prove that no host storage fallback occurs when the workspace is locked. Keep unsupported features explicit until their storage behavior is covered.

## Browser choice

### Recommendation: a native WebKit browser

On macOS, use `WKWebView` and the system WebKit framework for a small browser UI. Keep WebKit's process model and protections. The UI can integrate into the desktop or be installed as a runtime-aware Noct app. This avoids distributing our own copy of Chromium; it does not imply lower memory use for every website or universal write confinement.

There is already a useful first-party base: `noctweave-net/apps/noctweb-browser`. Its existing renderer verifies `noct://` publications and denies external network access. Keep that trust model intact. Ordinary HTTPS browsing needs a separate mode or app with its own explicit permissions and tests; enabling generic navigation in the verified publication renderer would change its boundary.

Measured locally on 20 October 2026:

| Artifact | File bytes | Meaning |
| --- | ---: | --- |
| Official Chromium 1722776 archive | 179,100,510 | Compressed download |
| Chromium.app members in that archive | 388,051,346 | Sum of uncompressed archive member sizes |
| Existing Noctweb Browser.app | 26,270,310 | Sum of regular bundle file sizes, excluding symlinks |

These are development artifacts with different functionality and packaging. The WebKit figure excludes the shared macOS engine. Neither number measures RAM, startup speed, CPU use, GPU use or physical APFS allocation.

### Storage remains a gate

`WKWebsiteDataStore.nonPersistent()` keeps website data in memory according to Apple's API contract. The default persistent store writes to OS-managed locations, and a UUID-named persistent store is not an arbitrary encrypted-folder selector. Nonpersistent website data also does not certify that every preference, temporary file, log, OS cache or auxiliary process write stays in the vault.

For a first lightweight browser, use nonpersistent web sessions and persist owned settings, bookmarks, downloads and history through the workspace SDK. Make session loss across lock explicit until persistence is implemented. On macOS 26+, public `fetchData(of:)` and `restoreData` can serialize supported website data, but they are not a complete browser-profile backup API.

The actual API capability probe on this macOS 27.0.1 machine accepted localStorage and explicitly rejected cookies and IndexedDB. Evidence is `evidence/webkit-storage-api.json`; the probe uses a new empty nonpersistent store and does not prove real data round-trip or filesystem confinement. WebKit's current public implementation also only accepts the localStorage type in this export method. Cookies have their own public `WKHTTPCookieStore` get/set API and could be handled separately. There is no demonstrated public full IndexedDB export here. Do not promise arbitrary persistent web apps in the initial lightweight browser. The Chromium verifier's persistence results do not apply to WebKit.

### Other choices

| Choice | Assessment for this project |
| --- | --- |
| Chromium fork | Maximum control over storage integration, but the engine and security update responsibility remain. Removing UI/features alone does not produce a tiny engine. Keep only if Chromium compatibility is required. |
| CEF, QtWebEngine or Electron | Still ship Chromium-based components; not an automatic solution to engine footprint. |
| New rendering engine | An unnecessary engine development and web compatibility project for the first Noct Desktop release. |

## Next implementation order

1. Extract the shared Swift runtime context, preferences and lock interface.
2. Port one Noct app end to end, starting with its storage inventory and synthetic fixtures.
3. Add the lightweight WebKit browser experiment with memory-only website storage; test framework writes separately.
4. Add encrypted export/restore only for data types that pass actual round-trip and lock tests.
5. Port the other Noct apps and publish compatibility evidence per app and feature.
6. Return to Chromium or other outside apps through explicit adapters after the first-party contract is stable.

## Primary references

- [Apple WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)
- [Apple website data export](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/fetchdata(of:completionhandler:))
- [Apple website data restore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/restoredata(_:completionhandler:))
- [WebKit website data export implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.mm)
- [WebKit process architecture](https://docs.webkit.org/Getting%20Started/Introduction.html)
- [Chromium macOS build and update workflow](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)
