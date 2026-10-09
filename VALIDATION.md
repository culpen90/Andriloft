# Local validation — 2026-10-09

Validated on Apple Silicon (`arm64`), macOS 26.6.2, using Swift 6.4. Intel and older macOS versions have not been exercised.

## Results

- `swift test` with a temporary scratch directory outside synced Documents: 23 tests passed, 0 failures.
- Packaged release `.app` includes a real, signed Android example APK and needs no Android SDK at runtime.
- Release `andriloft-check --self-test` passed with `PATH=/usr/bin:/bin` and both Android SDK environment variables pointing to nonexistent directories.
- Real APK code created AppKit controls, executed Java listeners, updated the counter, read native input, emitted a greeting, and restored SharedPreferences after activity recreation.
- Lifecycle fixture verified Application startup before Activity static initialization, then create/start/resume and pause/stop/destroy.
- Startup-finish fixture verified destruction without start/resume or a displayed window.
- WebView fixture failed with an explicit unsupported Android API error.
- Visible Mac UI check: imported bundled APK, opened native activity window, clicked its counter, entered `Andriloft`, and observed `Hello, Andriloft!` in the library status bar.

The original runtime validation app was saved at `~/Applications/Andriloft.app`; the project build script supports `ANDRILOFT_APP_OUTPUT` to choose another location. Packaging strips generated Finder metadata before signing. Tests used a scratch directory outside synced Documents to avoid file-provider metadata on resource bundles.

These initial runtime checks validate the Android API subset and included APK fixtures implemented at that time. They do not establish compatibility with general third-party Android apps, AndroidX/Compose, or native Android libraries. The later update and marketplace checks are recorded below; see README.md for the current implemented surface and known limits.

## In-app update validation

Validated locally on 2026-10-09 with Sparkle 2.10.0 and free ad hoc macOS signing:

- All 35 Swift XCTest cases passed: 23 runtime cases and 12 update approval/cancellation/forwarding cases.
- All 62 Python release-tool tests passed, including tampered feed/archive rejection, trusted public-key checks, and signing-key handling.
- A newly built universal app passed strict signature verification, both binary slices target macOS 13, and its executable resolves Sparkle from the bundled Frameworks directory.
- The packaged checker executed the real Android example and reported the expected unsupported WebView call.
- The production-key ZIP and signed appcast passed Sparkle's own checks and independent OpenSSL Ed25519 verification.
- An isolated GUI fixture created with `tools/prepare-update-smoke.py` updated from `0.0.1 (1)` to `0.0.2 (2)`. Clicking **Install Update** once downloaded, verified, installed, and relaunched the app from the same path, with a new process ID and no second restart confirmation.
- The isolated library index and imported example APK retained identical SHA-256 hashes. The relaunched app displayed the existing library entry and the new version.
- A second check displayed **You're up to date**. Stopping the local feed server displayed a recoverable update error; dismissing it returned to the usable app.

The fixture uses a unique app identity and Application Support folder; it does not replace the user's installed app or real APK library. Its localhost HTTP allowance exists only in the temporary fixture. Production requires HTTPS, signed feeds without an expiration fallback, and verified archives before extraction. This local test does not exercise a managed Mac, an administrator authorization prompt, a physical Intel Mac, or the public release feed before publication.

## Marketplace and cloud selection validation

Observed on 2026-10-09 on this 8 GB Apple Silicon Mac:

- `xcrun swift test --scratch-path /tmp/andriloft-antigravity-tests` passed all 82 XCTest cases: 24 runtime/parser cases, 12 update cases, and 46 marketplace cases. Coverage includes exact candidate selection, positive reasoning usage, bounded computer facts, stream completion, authentication errors, supported safe CLI permission modes, partial timeout rejection, process cancellation, download cleanup, source restrictions and file validation.
- The universal release app was built at `~/Applications/Andriloft Marketplace.app`. It passed deep strict code-signature verification, and both executable slices target macOS 13. The packaged checker still passed the real Android example's native controls, callbacks, text input, Toast and preferences self-test.
- The packaged native UI loaded 15 real APKMirror app listings and icons. Searching for nzb360 returned its real app identity. The Google account sheet confirmed actual account access and disclosed that basic computer compatibility specs go to Google; no model work appeared in the catalog.
- The final persistent package launched from `~/Applications/Andriloft Marketplace.app` with a live 15-app catalog, connected Google account and the original Hello Android library entry. The previously installed `/Applications/Andriloft.app` was left untouched.
- The production catalog collected five standalone variants from three real nzb360 releases (25.2, 25.1, and 25).
- A fresh invocation of the exact private zero-tool agent and production environment used remote `gemini-3.8-flash-high` with high reasoning effort. It completed in 5.95 seconds, recorded 362 thinking tokens, and selected the expected newest stable universal APK from a three-row comparison. The completed stream contained no tool steps. No local model or inference server was started.
- The real production `andriloft-check --marketplace-download https://www.apkmirror.com/apk/kevin-foreman/nzb360/` path discovered releases, asked Gemini to choose, followed APKMirror's signed R2 redirect, validated and saved nzb360 25.2. Its 15,055,715 bytes matched the published SHA-256 `dd83a26ccb2b81196bf43bd95b9be1b63201127b707aabb05c604e98e2f98d95`. The completed file was independently inspected and hashed after saving.
- A separate native UI check pressed nzb360's **Download** exactly once. The same live operation showed **Preparing…**, **Downloading 99%**, then a disabled checkmarked **Downloaded** button. It saved `nzb360---Media-Server-Manager-25.2-BE4DAE19.apk` in `~/Downloads/Andriloft/`; the saved size and SHA-256 matched the production checker download above. No reasoning, model diagnostics, Terminal or account prompts appeared during this already-connected download. **My apps** still contained its original Hello Android entry, and the downloaded APK was neither imported nor run.
- The production APK reader parsed `com.kevinforeman.nzb360`, version 25.2, minimum SDK 26, and all three DEX files. Valid case-distinct resource names survived import validation; duplicate, canonical Unicode collision, traversal, size, and CRC protections remain covered by tests.

These results validate real cloud selection and a complete APKMirror download. They do not establish that nzb360 or other marketplace apps can execute in Andriloft's limited Android runtime. No downloaded marketplace APK was imported or run automatically. Personal Google account access was exercised using an existing signed-in account; fresh browser sign-in, physical Intel hardware, older macOS versions, quota exhaustion and access challenges were not exercised.

## Version-reference correction validation

Observed on 2026-10-09 on Apple Silicon using Xcode's Swift 6.4. The candidate working tree was based on `v0.3.0` (`26f26f2`); its local package reported `0.3.1 (9)` and accurately recorded `source_dirty: true` before the correction was committed.

- `xcrun swift test --scratch-path /tmp/andriloft-version-validation.yFogVq/swift-tests` passed the runtime, update, and marketplace test suites. All 62 Python release-tool tests passed.
- `tools/package-app.sh`, with Xcode's toolchain on `PATH` and temporary output/scratch directories, built and signed a fresh Release app. Its plist and `build-info.json` both contained semantic version `0.3.1` and build `9`; package signature checks passed.
- Both the debug and packaged Release checkers passed the real HelloAndroid APK self-test and the expected unsupported WebView check.
- The packaged native app visibly displayed `Experimental · 0.3.1` in the sidebar and `What runs in Andriloft 0.3.1` on the compatibility screen. The capability heading read `Supported Android APIs` without the old v0.1 label.
- Twenty local documentation links resolved, eight shell examples parsed with `bash -n`, the source plist resolved to `0.3.1 9`, and `git diff --check` passed.

The separate Swift 6.3 installation on the default shell path could not compile against this Mac's newer SDK; packaging passed with Xcode's Swift 6.4. These checks validate a local development candidate, not publication of v0.3.1, a new Android compatibility feature, or a full signed universal distribution build.
