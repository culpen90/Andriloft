# APKMirror marketplace

The marketplace is a native SwiftUI catalog. Its single download action calls `MarketplaceDownloadService`: discover real APKMirror releases, exclude split bundles, ask Antigravity to compare the candidates, resolve the selected source page, download the file, validate its APK/DEX structure and any available identity/checksum metadata, then move it into Downloads. It does not import or execute the file until the user explicitly chooses a library action.

## Cloud selection with your Google account

`AntigravitySelector` sends bounded release metadata to Google's official Antigravity CLI using a remote Gemini model, high reasoning effort, and a strict JSON answer restricted to an existing candidate index. Only a completed single-turn response with recorded thinking tokens and a valid index can begin file resolution. The app validates the model's exact JSON answer; no prose, extra keys, fabricated URLs or out-of-range indices are accepted. CLI timeout snapshots are rejected even if they incorrectly report success. Reasoning and CLI diagnostics are discarded, and no heuristic fallback substitutes for the model's choice.

The app prepares the official signed CLI **1.3.2** in `~/Library/Application Support/Andriloft/Antigravity/1.3.2/`. Downloads use pinned Apple Silicon and Intel archives from Google's updater, verify SHA-512, and require the executable's code signature to identify Google LLC (team `EQHXZ8M8AV`). Shell profiles and existing user CLI settings are not changed. Each selection uses a temporary workspace and a dedicated zero-tool agent with user customizations disabled; inherited hooks, plugins, rules, skills and MCP servers cannot participate. The stream verifies the remote model and agent identity and rejects executable tool calls. Request logs are discarded. The CLI requires macOS 12; Andriloft retains its macOS 13 minimum.

The Google account control opens a one-time setup sheet. Setup launches Google's interactive CLI in Terminal and its browser sign-in flow. Andriloft checks the official `/usage` response before reporting a connected account or continuing the requested download. Google maintains the credentials; Andriloft does not collect passwords or read tokens. Subsequent downloads run non-interactively. Expired sessions prompt account setup again, and quota or network errors leave a retryable download.

App names and bounded version, architecture, SDK, DPI, prerelease and size metadata go to Google. A small computer profile supplies physical CPU architecture (including Apple Silicon when running under Rosetta), macOS version, total RAM, logical CPU count, and available storage on the download volume, rounded to MiB. It includes no computer name, serial number, user name, paths, or personal files. Andriloft’s Android API and native-library limitations remain the primary compatibility constraints; host architecture does not imply support for Android native libraries. APK files come directly from APKMirror and do not go to the model. Google's account terms, data settings and usage limits apply. No local model weights or inference engine are used.

The CLI is used because it supports personal Google account sign-in. The current Python SDK requires a Gemini API key or Google Cloud credentials and does not use personal Antigravity account authentication.

Official references: [CLI authentication](https://antigravity.google/docs/cli/install/), [headless requests and structured output](https://antigravity.google/docs/cli/headless/), [SDK credentials](https://antigravity.google/docs/sdk/overview/).

## Source and file handling

Catalog requests use ordinary native WebKit page navigation, with bounded reads, caching, and request spacing. The provider parses actual app rows, release tables, variant details, and download landing links. It neither fabricates listings nor solves CAPTCHA or access challenges. Browser cookies are shared with the file downloader so public file links can follow the same browsing session.

Catalog pages and initial file sources must use HTTPS and the exact APKMirror domain or its subdomains. File redirects also permit APKMirror's observed Cloudflare R2 account `eb5e7388c3df147b74dd2379b7cf8323.r2.cloudflarestorage.com`, restricted to its download path, APKMirror APK filenames, and signed AWS URLs with at most a one-hour expiry. Other hosts are rejected. Downloads are bounded to the importer's 512 MiB archive limit, HTML/JSON responses are rejected, and the existing APK and DEX parsers validate the completed file. Published file SHA-256 and package identity are checked when supplied by APKMirror; a file checksum is distinct from a signing-certificate fingerprint. Andriloft's importer still does not verify APK signing certificates.

The in-memory ZIP reader preserves Android's case-sensitive resource paths, including obfuscated pairs such as `res/-P.png` and `res/-p.png`. Exact duplicate paths, canonically equivalent Unicode names, traversal, overlaps, oversized expansion, and invalid CRCs remain rejected. APK contents are not extracted to the host filesystem.

Files receive sanitized unique names, preserving earlier downloads. Partial files are removed on failure or cancellation. App downloads remain separate from Andriloft's own signed Sparkle update flow.

## Developer checks

```sh
swift test --scratch-path /tmp/andriloft-marketplace-tests
swift run andriloft-check --marketplace-search VLC
swift run andriloft-check --marketplace-variants https://www.apkmirror.com/apk/videolabs/vlc/
```

The checker also supports `--marketplace-download <app-url>` to exercise the complete real path, including Google account access and cloud selection and saving the chosen APK. Live requests are deliberately separate from unit tests: source availability, page markup, bandwidth, account access, and Google service availability are external dependencies. Run it only when those downloads are intended. Current observed validation is recorded in [VALIDATION.md](../VALIDATION.md).
