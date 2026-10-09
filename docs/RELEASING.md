# Release automation

The **Release** GitHub Actions workflow runs on every push to `main`, including merged pull requests. It publishes newly built universal macOS ZIP and DMG packages and a signed Sparkle update feed only after Swift tests, real APK execution checks, signatures, archive integrity, version metadata, and upload checksums pass. The **CI** workflow also checks pull requests without publishing.

## Version selection

The planner uses the highest published stable `vX.Y.Z` release and every commit since its tag. Drafts, prereleases, and other tag formats are excluded. The highest applicable increment wins:

| Commit message | Increment | Example starting at 0.3.0 |
| --- | --- | --- |
| `fix: correct APK import` | Patch | 0.3.1 |
| `feat: support another Android API` | Minor | 0.4.0 |
| `feat!: change the host API` | Major | 1.0.0 |
| A Conventional Commit with a `BREAKING CHANGE:` footer | Major | 1.0.0 |
| Other commits, including docs and build changes | Patch | 0.3.1 |

Use Conventional Commit titles when squash merging. A first release with no published stable version starts at `0.1.0`. Changes during the `0.x` phase follow the same explicit major/minor/patch rules.

The packaged app's `CFBundleShortVersionString`, `build-info.json`, `release.json`, and filenames contain the planned semantic version. `CFBundleVersion` is the source commit count, which increases as `main` gains commits. Source history must descend from the previous release; rewriting release history is rejected. The source plist supplies defaults for local development builds; the workflow stamps a copy inside the app without modifying source or creating a bot commit.

The bot also generates the signed appcast and GitHub release notes from commit subjects. It does **not** rewrite source metadata, UI copy, README content, authored release notes, or validation records. Contributors must update every affected maintained version reference and change description outside that generated output, using the planned version and actual Conventional Commit changes. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the required audit and pull request checklist.

## Manual runs and retries

In **Actions → Release → Run workflow**, select `main` and choose `auto`, `patch`, `minor`, or `major`. Manual selection overrides commit analysis for unreleased commits. An already released source commit, or an older queued commit, is skipped even when an increment is selected. Runs on other branches cannot publish.

Version allocation and publication are serialized. GitHub may replace an older pending run when several pushes arrive together; the next run includes every change since the previous published release. An active release is allowed to finish.

A build failure publishes nothing. An upload failure leaves a draft that can be resumed with **Re-run failed jobs** on the original run, even if `main` has since advanced. Draft assets may be replaced during a retry, but already published release assets are only verified and never overwritten. A same-source unpublished tag can be reused; a tag pointing to a different commit causes a failure. Finish the original failed run first, then run the workflow on current `main` to release the remaining commits. An abandoned unpublished draft and tag require deliberate cleanup; never move a published tag.

## Downloads and signing

Each public release includes:

- `Andriloft-<version>-macOS-universal.dmg`
- `Andriloft-<version>-macOS-universal.zip`
- `appcast.xml`, the signed in-app update feed pointing to the versioned ZIP.
- `SHA256SUMS.txt`
- `release.json`, recording the exact source SHA, bundle version, architectures, signing method, asset hashes, update signing configuration, and validation results.

The publishing job validates the manifest, the ZIP's embedded version/provenance, and the update signatures against the public key in the release source. It uploads all five assets into a draft, then downloads every uploaded file and compares hashes before publishing. The macOS build also extracts the ZIP and mounts the DMG to check each included app and execute the example APK.

The app uses free ad hoc signing and is not notarized. No Apple account or Developer ID certificate is required. First launch may require **System Settings → Privacy & Security → Open Anyway**, as described in [INSTALL.md](INSTALL.md).

In-app updates use [Sparkle](https://sparkle-project.org/documentation/), pinned to version `2.10.0`. **Check for Updates…** fetches `https://github.com/culpen90/Andriloft/releases/latest/download/appcast.xml`. Choosing **Install Update** downloads and verifies the ZIP, replaces the installed app, and restarts Andriloft automatically. Open Android windows close; the imported APK library stays in the user's Application Support directory. The feed includes this notice before installation. Install the app in a writable location outside the DMG, as described in the installation guide.

Sparkle's Ed25519 signatures are separate from Apple's code signing and cost nothing. Both the feed and ZIP must authenticate with the public key embedded as `SUPublicEDKey`; signed-feed verification has no expiration fallback. Archive signatures are checked before extraction. The feed identifies the source commit count as the Sparkle version and displays the semantic version to the user. Its archive URL includes the immutable release tag, so a newer Latest release cannot redirect an update already offered to another ZIP.

The build job requires the repository Actions secret `SPARKLE_PRIVATE_KEY`, containing the base64 private key exported by Sparkle's `generate_keys` tool. The release key is stored in the maintainer's macOS Keychain under account `dev.andriloft.mac`; the public half is committed in `Assets/Info.plist`. Keep a secure backup of the private key. Since the app has no Developer ID certificate, replacing a lost key requires users to install a new build manually. Never commit or print the private key. Release tools pass it on standard input, remove it from child environments, and suppress signing-process diagnostics that could echo malformed key input.

`generate_appcast` and `sign_update` come from the same pinned Swift Package Manager binary artifact as the app's framework. The build checks signatures using Sparkle and independently using OpenSSL Ed25519; publication repeats the public-key checks. The macOS workflows explicitly select Homebrew OpenSSL 3 because Apple's system LibreSSL does not provide these verification commands.

The workflow uses the repository's built-in `GITHUB_TOKEN`; only the publishing job receives `contents: write`. Actions must be enabled. Standard GitHub-hosted Actions are free for public repositories; private repositories have plan-specific usage limits. There is no paid bot service or personal access token to configure.

## Local validation

```sh
python3 -m unittest discover -s tools/tests -v
# Run from a clean committed source tree, choosing unused output filenames:
ANDRILOFT_VERSION=0.3.1 ANDRILOFT_BUILD_NUMBER="$(git rev-list --count HEAD)" \
  SPARKLE_PRIVATE_KEY="$(cat /secure/path/sparkle-private-key)" \
  ANDRILOFT_OPENSSL="$(brew --prefix openssl@3)/bin/openssl" ./tools/build-release.sh
```

`ANDRILOFT_VERSION` must be a stable `X.Y.Z` version without leading zeros. `ANDRILOFT_BUILD_NUMBER` must be a positive integer. Invalid values are rejected before building. Omitting these variables uses `Assets/Info.plist` defaults.

Install OpenSSL 3 with `brew install openssl@3` for local release builds. `ANDRILOFT_OPENSSL` can select its executable. `ANDRILOFT_SPARKLE_TOOLS` can select a `bin` directory from the pinned Sparkle distribution; otherwise the build uses its own Swift Package Manager artifact. A missing signing key, invalid signature, incorrect feed URL, or mismatched public key stops release publication.
