# Andriloft

An experimental Android compatibility layer for macOS, inspired by Wine's API translation approach. Andriloft opens an APK, executes its managed DEX bytecode, and translates supported Android framework calls into native AppKit controls. It does not boot Android, use an emulator, or require an Android SDK to run.

**Andriloft is an experimental prototype with limited Android app compatibility.** The included, ordinary Android APK runs its activity code, Java button callbacks, editable input, and saved preferences on macOS. Most existing apps require many Android APIs that are not implemented yet.

## Download and install

Download the ready-to-run **[latest Andriloft release](https://github.com/culpen90/Andriloft/releases/latest)** for macOS 13 or newer. The universal app includes Apple Silicon and Intel executables; runtime validation has been performed on Apple Silicon.

- **DMG installer** (`Andriloft-<version>-macOS-universal.dmg`): open it and drag **Andriloft.app** into **Applications**.
- **ZIP archive** (`Andriloft-<version>-macOS-universal.zip`): extract it and move **Andriloft.app** into **Applications**.

No Android SDK or developer tools are needed to run the downloaded app. Open Andriloft, click **Try the example**, then **Run app**.

The app uses an ad hoc code signature and is not notarized or signed with an Apple Developer ID. If macOS blocks the first launch, follow the per-app **System Settings → Privacy & Security → Open Anyway** steps in the [installation guide](docs/INSTALL.md). This distribution requires no paid Apple Developer account. See the [latest published release notes](https://github.com/culpen90/Andriloft/releases/latest) and [current compatibility limits](#current-limits).

Choose **Check for Updates…** in Andriloft's sidebar or app menu, then **Install Update** when a new version is available. Andriloft verifies, downloads, installs, and restarts automatically, keeping your imported APK library and saved preferences. Open Android app windows close for the restart. Releases predating the updater need one manual installation of an updater-enabled build.

## App marketplace

Open **Marketplace**, browse the latest apps from APKMirror or search by name, and press **Download**. Connect your Google account once when prompted. Andriloft asks **Google Antigravity with high reasoning effort** to choose the best standalone APK, verifies the downloaded package, and saves it in `~/Downloads/Andriloft/`. The button shows ordinary preparation and download progress; prompts, reasoning, and variant selection stay out of the interface. Cancel and retry use the same button.

Andriloft prepares an app-owned copy of Google's signed Antigravity CLI. Google account setup opens the official CLI and browser sign-in flow; subsequent downloads reuse Google's saved credentials. Model inference runs remotely: no Gemma weights, Ollama server, or local inference engine is installed or started. App names, bounded release metadata, and basic computer compatibility specs (CPU architecture, macOS version, RAM, CPU count, and available storage) are sent to Google, while app files download from APKMirror. Google account availability and quota apply. See [marketplace implementation and validation](docs/MARKETPLACE.md) for the exact integration.

Antigravity compares actual release metadata, including stable/beta status, architecture, Android requirements, and DPI. It can choose an older release where that is a better fit. The final choice must refer to a discovered candidate; a failed selection stops the download and offers retry. Split APK bundles are excluded because Andriloft cannot import them. Downloading an APK does not establish that its Android APIs are supported. Control-click a downloaded card to **Show in Finder** or **Add to My apps**; downloaded code never runs automatically.

App listings and files come from [APKMirror](https://www.apkmirror.com/). Its [FAQ](https://www.apkmirror.com/faq/) explains standalone APKs and split bundles. If APKMirror is unavailable or requires an interactive browser check, the marketplace reports that the page could not load.

## Run

Requires macOS 13 or newer. Build with Xcode Command Line Tools and Swift 5.9 or newer:

```sh
./tools/package-app.sh
open build/Andriloft.app
```

Click **Try the example**, then **Run app**. The example's counter and greeting execute the APK's compiled Java code. You can also add APKs with **Add APK**, drag them into the window, or use Finder's Open With menu. Andriloft keeps a copy in `~/Library/Application Support/Andriloft/`.

The package script includes a precompiled demo APK; it needs no Android tools. The resulting app is signed locally with an ad hoc signature, without Developer ID notarization.

## What works

- Ordinary ZIP APKs, compiled Android manifests, launcher activities and activity aliases, default string resources, and multiple DEX files.
- DEX 035–040 parsing, a bounded register interpreter, application and activity class initialization, constructors, lifecycle callbacks, virtual method dispatch, fields, branches, arrays, and basic numeric operations.
- Programmatic `LinearLayout`, `TextView`, `Button`, and `EditText` mapped to real Mac controls; text, font size, colors, click handlers, and basic layout.
- A small Java surface including strings, StringBuilder, integer conversion, and a few math operations.
- Package-isolated `SharedPreferences`, `Log`, and Toast output in the library status bar.
- Import validation and specific unsupported API/opcode errors. Guest callbacks stop after an execution error.

Native layouts adapt Android views to Mac controls. Rendering is approximate: density, margins, text-control padding, layout weight, visibility variants, and many layout properties do not yet reproduce Android behavior.

## Current limits

AndroidX, Compose, XML layout inflation, Google Play services, WebView, Binder/services, network/media/device APIs, native JNI/Linux `.so` libraries, split APK installation, and Android exception handling are not implemented. Permissions listed in an APK do not grant host access. APK signing certificates are not verified by the importer. Files are interpreted in the app's own process; this prototype is not a security sandbox for hostile apps.

The runtime never silently launches an Android emulator. Unsupported calls report the method that could not run. Native libraries in an APK are listed as metadata and are never loaded.

## Build and validate

```sh
swift test
swift run andriloft-check --inspect Tests/AndriloftTests/Fixtures/HelloAndroid.apk
swift run andriloft-check --self-test Tests/AndriloftTests/Fixtures/HelloAndroid.apk
swift run andriloft-check --expect-unsupported Tests/AndriloftTests/Fixtures/UnsupportedAndroid.apk
./tools/package-app.sh
```

The integration checks execute the actual APK: `Activity.onCreate` creates AppKit controls, native button clicks invoke Java listeners, Java code reads the native input, and saved state survives activity recreation. Tests also cover malformed APK/DEX files, resource lookup, interpreter limits, method dispatch, and unsupported APIs.

If a synced Documents folder adds Finder metadata to test bundles and codesigning fails, use `swift test --scratch-path /tmp/andriloft-tests` to build the tests outside that folder.

You can also package the app outside a synced folder with `ANDRILOFT_APP_OUTPUT="$HOME/Applications/Andriloft.app" ./tools/package-app.sh`.

To rebuild the Java example and fixtures, install an Android SDK containing a stable platform, build-tools, and JDK 17 or newer:

```sh
ANDROID_SDK_ROOT="$HOME/Library/Android/sdk" ./tools/build-example.sh --update-fixtures
./tools/package-app.sh --build-example
```

Android tools are used only to compile test APKs. There is no Android runtime dependency in the macOS app.

To build distribution ZIP and DMG files from a clean committed source tree:

```sh
SPARKLE_PRIVATE_KEY="<exported Sparkle key>" ./tools/build-release.sh
```

This builds fresh universal Release executables, runs tests and APK execution checks, verifies the extracted ZIP and mounted DMG, and writes a signed update feed, checksums, and source provenance under `build/release/`. Local release publishing needs the exported Sparkle update key and OpenSSL 3; normal app builds do not. On Apple Silicon with Rosetta already installed, set `ANDRILOFT_VERIFY_ROSETTA=1` to also execute the Intel checker. macOS signing is ad hoc; no Apple account is required. See the [release guide](docs/RELEASING.md) for key handling.

## Automatic releases

Every push or merge to `main` automatically publishes a new GitHub release after tests and packaging checks pass. The bot examines all commits since the last published release: `feat:` increments minor, `!` or a `BREAKING CHANGE:` footer increments major, and other changes increment patch. Multiple changes use the largest increment.

Each version gets newly built universal ZIP and DMG downloads, a signed Sparkle appcast, matching app version metadata, an increasing build number, checksums, and source provenance. Releases remain drafts until all uploaded files have been downloaded again and verified. The bot uses GitHub's built-in token, free ad hoc macOS signing, and the repository's `SPARKLE_PRIVATE_KEY` secret to authenticate updates. No Apple Developer account or certificate is needed. See [the release guide](docs/RELEASING.md) for manual increments and failure recovery.

Contributors must also update source version defaults, current documentation, release notes, and compatibility information that the bot does not maintain. Follow the [contribution guide](CONTRIBUTING.md) before submitting a change. The [0.3.1 source release notes](docs/releases/v0.3.1.md) describe this version-reference correction; the download link above always resolves to the latest published release.

## Architecture

```text
APKPackage       bounded ZIP + binary manifest + resource string reader
   ↓
DexFile          DEX definitions, method code and constants
   ↓
DexVM            interpreter for supported application bytecode
   ↓
AndroidHost      Android/Java API shims, saved state, AppKit controls
   ↓
NativeAndroidSession  native window and guest lifecycle
```

`Sources/AndriloftCore` holds platform-independent parsing and execution. `Sources/AndriloftRuntime` holds the Mac framework bridge. `Sources/Andriloft` is the SwiftUI library, and `Sources/AndriloftCheck` provides repeatable APK execution checks. `Examples/HelloAndroid` contains Java source for the test app.

The bytecode reader follows the AOSP [DEX file format](https://source.android.com/docs/core/runtime/dex-format) and [Dalvik instruction format](https://source.android.com/docs/core/runtime/dalvik-bytecode). Framework behavior is developed against the [Android Activity API](https://developer.android.com/reference/android/app/Activity).

Next compatibility work should add regression APKs for each new API, improve resources and XML views, implement Java exceptions and library behavior, and then expand framework services. JNI and Linux ABI translation require a separate substantial implementation.
