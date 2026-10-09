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

The final locally signed app is at `~/Applications/Andriloft.app`; the project build script supports `ANDRILOFT_APP_OUTPUT` to choose another location. Packaging strips generated Finder metadata before signing. Tests used a scratch directory outside synced Documents to avoid file-provider metadata on resource bundles.

This validates the defined v0.1 API subset and included APK fixtures. It does not establish compatibility with general third-party Android apps, AndroidX/Compose, or native Android libraries. See README.md for the implemented surface and known limits.

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
