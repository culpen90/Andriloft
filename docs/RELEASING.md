# Release automation

The **Release** GitHub Actions workflow runs on every push to `main`, including merged pull requests. It publishes newly built universal macOS ZIP and DMG packages only after Swift tests, real APK execution checks, signatures, archive integrity, version metadata, and upload checksums pass. The **CI** workflow also checks pull requests without publishing.

## Version selection

The planner uses the highest published stable `vX.Y.Z` release and every commit since its tag. Drafts, prereleases, and other tag formats are excluded. The highest applicable increment wins:

| Commit message | Increment | Example starting at 0.1.0 |
| --- | --- | --- |
| `fix: correct APK import` | Patch | 0.1.1 |
| `feat: support another Android API` | Minor | 0.2.0 |
| `feat!: change the host API` | Major | 1.0.0 |
| A Conventional Commit with a `BREAKING CHANGE:` footer | Major | 1.0.0 |
| Other commits, including docs and build changes | Patch | 0.1.1 |

Use Conventional Commit titles when squash merging. A first release with no published stable version starts at `0.1.0`. Changes during the `0.x` phase follow the same explicit major/minor/patch rules.

The packaged app's `CFBundleShortVersionString`, `build-info.json`, `release.json`, and filenames contain the planned semantic version. `CFBundleVersion` is the source commit count, which increases as `main` gains commits. Source history must descend from the previous release; rewriting release history is rejected. The source plist supplies defaults for local development builds; the workflow stamps a copy inside the app without modifying source or creating a bot commit.

## Manual runs and retries

In **Actions → Release → Run workflow**, select `main` and choose `auto`, `patch`, `minor`, or `major`. Manual selection overrides commit analysis for unreleased commits. An already released source commit, or an older queued commit, is skipped even when an increment is selected. Runs on other branches cannot publish.

Version allocation and publication are serialized. GitHub may replace an older pending run when several pushes arrive together; the next run includes every change since the previous published release. An active release is allowed to finish.

A build failure publishes nothing. An upload failure leaves a draft that can be resumed with **Re-run failed jobs** on the original run, even if `main` has since advanced. Draft assets may be replaced during a retry, but already published release assets are only verified and never overwritten. A same-source unpublished tag can be reused; a tag pointing to a different commit causes a failure. Finish the original failed run first, then run the workflow on current `main` to release the remaining commits. An abandoned unpublished draft and tag require deliberate cleanup; never move a published tag.

## Downloads and signing

Each public release includes:

- `Andriloft-<version>-macOS-universal.dmg`
- `Andriloft-<version>-macOS-universal.zip`
- `SHA256SUMS.txt`
- `release.json`, recording the exact source SHA, bundle version, architectures, signing method, asset hashes, and validation results.

The publishing job validates both the manifest and the ZIP's embedded version/provenance, uploads all four assets into a draft, then downloads every uploaded file and compares hashes before publishing. The macOS build also extracts the ZIP and mounts the DMG to check each included app and execute the example APK.

The app uses free ad hoc signing and is not notarized. No Apple account, Developer ID certificate, or signing secrets are used. First launch may require **System Settings → Privacy & Security → Open Anyway**, as described in [INSTALL.md](INSTALL.md).

The workflow uses the repository's built-in `GITHUB_TOKEN`; only the publishing job receives `contents: write`. Actions must be enabled. Standard GitHub-hosted Actions are free for public repositories; private repositories have plan-specific usage limits. There is no paid bot service or personal access token to configure.

## Local validation

```sh
python3 -m unittest discover -s tools/tests -v
# Run from a clean committed source tree, choosing unused output filenames:
ANDRILOFT_VERSION=0.1.1 ANDRILOFT_BUILD_NUMBER=6 ./tools/build-release.sh
```

`ANDRILOFT_VERSION` must be a stable `X.Y.Z` version without leading zeros. `ANDRILOFT_BUILD_NUMBER` must be a positive integer. Invalid values are rejected before building. Omitting these variables uses `Assets/Info.plist` defaults.
