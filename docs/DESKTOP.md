# Relay Desktop (Windows / macOS / Linux)

Relay's client is a **Flutter** app, so the desktop builds are **native** —
there is no Electron/web wrapper. The same `lib/` code runs on mobile, Web, and
all three desktop targets; `windows/`, `macos/`, and `linux/` are the standard
Flutter desktop runner projects.

## Important: each OS builds its own target

Desktop binaries **cannot be cross-compiled**. You must build each target on
that OS:

| Target        | Build host required        | Can a Linux box produce it? |
|---------------|----------------------------|-----------------------------|
| Windows       | Windows + Visual Studio     | No                          |
| macOS         | macOS + Xcode               | No                          |
| Linux/Debian  | Linux                       | Yes                         |

macOS apps in particular **must** be built and signed on a Mac — there is no
workaround.

## Prerequisites

### Windows
- Windows 10/11 (x64)
- **Visual Studio 2022 or 2026** with the *"Desktop development with C++"*
  workload (MSVC, Windows 10/11 SDK, CMake). VS 2026 (Community 18.6, MSVC
  14.51) is verified working — see "Windows build gotchas" below for the one
  coroutine workaround its newer STL needs.
- Flutter SDK on PATH. Desktop is on by default; if needed:
  `flutter config --enable-windows-desktop`

### macOS
- macOS 10.15+ (the project's deployment target is 10.15)
- **Xcode** + command line tools, and **CocoaPods** (`sudo gem install cocoapods`)
- `flutter config --enable-macos-desktop`

### Linux / Debian
- `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`
- For credential storage at runtime: `libsecret-1-0` + a keyring
  (`gnome-keyring`), used by `flutter_secure_storage`.
- `flutter config --enable-linux-desktop`

## Build & run

```bash
flutter pub get

# Dev run:
flutter run -d windows      # or: -d macos / -d linux

# Release build:
flutter build windows --release
flutter build macos --release
flutter build linux --release
```

Artifacts:
- **Windows:** `build/windows/x64/runner/Release/` — `relay.exe` plus DLLs
  (`flutter_windows.dll`, plugin DLLs) and a `data/` folder. The whole folder is
  portable; zip it to share. Last verified 2026-06-04 with Flutter 3.44.1 + VS
  Community 2026.
- **macOS:** `build/macos/Build/Products/Release/Relay.app`
- **Linux:** `build/linux/x64/release/bundle/` — `relay` plus `lib/` and
  `data/`.

## Windows build gotchas

Two environment issues will block a Windows build even though the Dart/C++
source is fine. Both are toolchain quirks, not bugs in Relay.

### 1. Non-ASCII (CJK) project path breaks the toolchain

If the repo lives under a path containing non-ASCII characters (e.g. a Chinese
folder name), the Flutter Windows toolchain mishandles it through the system
ANSI code page:

- `flutter analyze` crashes in its LSP channel
  (`FormatException: Unexpected end of input`).
- `flutter build windows` fails with
  `CUSTOMBUILD : error : Unable to read file: ...\app.dill`, where the path
  shows mojibake.

**Workarounds:**
- Build from an **ASCII-only path** (move/clone the repo somewhere like
  `D:\code\Relay`). This is the reliable fix.
- For static analysis specifically, use **`dart analyze`** instead of
  `flutter analyze` — it does not go through the failing LSP channel and works
  even on a CJK path.

### 2. VS 2026 MSVC rejects `flutter_local_notifications_windows`

VS 2026's MSVC (14.51) turns the deprecated `<experimental/coroutine>` header
into a **hard error** (`STL1011` / `C2338`). The bundled C++ in
`flutter_local_notifications_windows` still includes that header, so the plugin
fails to compile.

**Workaround** — define the silence macro for the whole build via the `CL`
environment variable (cl.exe prepends it to every compile):

```powershell
$env:CL = "/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS"
flutter build windows --release
```

```bash
# bash / git-bash
export CL="/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS"
flutter build windows --release
```

This is non-invasive (touches no generated project files). A permanent fix is to
add that define to the plugin target in CMake, or to bump
`flutter_local_notifications` once upstream migrates to the C++20 `<coroutine>`
header. VS 2022 does not need this workaround.

> Note: if you copy the repo to a fresh path to dodge issue #1, run
> `flutter clean` first so stale `*/flutter/ephemeral/.plugin_symlinks`
> entries don't trigger `PathExistsException` (errno 183) when Flutter
> recreates the plugin symlinks.

## Connecting on desktop

- **No camera QR scanner on desktop.** `mobile_scanner` only exists on
  mobile/macOS, so the desktop credential screen hides the camera option and
  offers **"Upload QR image"** and **"Paste credential"** instead. Generate the
  credential on the backend host (see the main README "Credential QR" section),
  then upload the PNG or paste the payload, and enter the passphrase.
- A backend exposed through **Cloudflare Quick Tunnel** uses the same
  `https://*.trycloudflare.com` URL as mobile/Web credentials. Regenerate the
  QR after the tunnel URL rotates.
- For a plain **`http://<LAN-or-public-ip>:port`** backend: macOS normally
  blocks cleartext HTTP via App Transport Security; we set
  `NSAllowsLocalNetworking` so local HTTP works. Windows/Linux have no such
  restriction.

## Platform notes / known limitations

- **Camera QR scan:** mobile only (see above). Desktop uses upload/paste.
- **Native notifications:** quota alerts use `flutter_local_notifications`.
  Android/iOS/macOS and Windows use native system notifications while the app is
  alive and connected to SSE. Linux still falls back to an in-app system message.
- **Secure storage backends:** Windows Credential Manager / macOS Keychain /
  Linux libsecret. On Linux a keyring daemon must be available.
- **macOS App Sandbox:** the app is sandboxed. Both `DebugProfile.entitlements`
  and `Release.entitlements` include `com.apple.security.network.client`
  (required to reach the backend) — without it the Release build cannot make any
  network request.

## macOS signing & distribution

- **Local / personal use:** an unsigned `.app` runs, but Gatekeeper warns on
  first launch. Right-click → **Open**, or strip quarantine:
  `xattr -dr com.apple.quarantine Relay.app`.
- **Distribution:** requires an Apple **Developer ID** signature + **notarization**.
  Open `macos/Runner.xcworkspace` in Xcode, set the signing team, then archive,
  or sign/notarize the built `.app` with `codesign` + `notarytool`.
- Bundle id: `dev.relay.app` (in `macos/Runner/Configs/AppInfo.xcconfig`).

## Windows packaging

- The `Release/` folder is portable — zip and distribute (target needs the VC++
  runtime, which is usually present).
- Optional installers: the `msix` Dart package for an MSIX, or Inno Setup / NSIS
  for a classic installer. Not set up in-repo yet.

## What is configured in-repo

- **Windows:** product/window title "Relay", company `Relay`,
  icon `windows/runner/resources/app_icon.ico`, binary `relay.exe`.
- **macOS:** `PRODUCT_NAME = Relay`, bundle id `dev.relay.app`, copyright,
  app icon, sandbox entitlements with network client, ATS local networking.
- **Linux:** standard GTK runner; binary `relay`.
