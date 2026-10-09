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
