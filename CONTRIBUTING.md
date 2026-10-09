# Contributing to Andriloft

Andriloft is an experimental Android compatibility layer for macOS. Keep changes focused, describe the user-visible behavior, and add regression coverage when extending APK parsing, DEX execution, Android APIs, updates, or marketplace behavior. Contributions use the repository's [MIT license](LICENSE); preserve license notices and third-party attribution.

## Build and check

Use macOS 13 or newer with Xcode Command Line Tools, Swift 5.9 or newer, and Python 3. The package resolves its pinned Sparkle dependency automatically. Normal builds and tests use checked-in APK fixtures and need no Android SDK.

Run the checks used by [CI](.github/workflows/ci.yml):

```sh
python3 -m unittest discover -s tools/tests -v
swift test
swift run andriloft-check --self-test Tests/AndriloftTests/Fixtures/HelloAndroid.apk
swift run andriloft-check --expect-unsupported Tests/AndriloftTests/Fixtures/UnsupportedAndroid.apk
```

Update-signature tests need OpenSSL 3. If needed, install it with `brew install openssl@3` and set `ANDRILOFT_OPENSSL` to `$(brew --prefix openssl@3)/bin/openssl`. If Finder metadata in a synced Documents folder interferes with test-bundle signing, use `swift test --scratch-path /tmp/andriloft-tests`.

For app or packaging changes, also run:

```sh
./tools/package-app.sh
open build/Andriloft.app
```

Check the changed UI and the bundled example. New runtime support should include a real regression APK. Rebuild examples and fixtures with `./tools/build-example.sh --update-fixtures`; this requires JDK 17 or newer and an Android SDK with a stable platform and build-tools. See [the example guide](Examples/HelloAndroid/README.md). Full signed distribution checks require a clean committed tree and the maintainer's update-signing key; follow [RELEASING.md](docs/RELEASING.md). Never commit signing keys or account credentials.

## Conventional Commits and the target version

Use a Conventional Commit subject such as `fix: correct displayed version` or `feat(runtime): support another Android API`. Use the same format for the PR title, and preserve it as the final squash-merge subject. The [release planner](tools/plan-release.py) examines every commit since the highest published stable `vX.Y.Z` release and chooses the largest applicable increment:

| Commit metadata | Increment | Example from published `0.3.0` |
| --- | --- | --- |
| `fix:`, `perf:`, `docs:`, `chore:`, `build:`, and other types | Patch | `0.3.1` |
| `feat:` or `feat(scope):` | Minor | `0.4.0` |
| A valid Conventional Commit with `!`, or a `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer | Major | `1.0.0` |

A breaking footer must start its own paragraph or follow another footer and must describe the break. These rules also apply before `1.0.0`; an incompatible change does not automatically get a minor bump. Non-conventional messages also produce a patch, but contributors must use meaningful Conventional Commit metadata. A manual workflow increment can override automatic analysis and must be reflected in the version audit.

At the start of a change, determine its expected target from the latest published release, all unreleased commits, and the intended commit type. For example, the version-display correction following published `0.3.0` targets `0.3.1`; its source notes describe a pending release until publication. A planned version is not evidence that the release exists.

After committing the changes, preview the planner using the same release data as automation:

```sh
git fetch origin --tags
mkdir -p build/automation
gh api --paginate 'repos/culpen90/Andriloft/releases?per_page=100' --jq '.[]' \
  | jq -s '.' > build/automation/releases.json
GH_REPO=culpen90/Andriloft python3 tools/plan-release.py \
  --releases build/automation/releases.json \
  --output build/automation/plan.json --notes build/automation/notes.md
```

This preview requires GitHub CLI, `jq`, complete Git history, and release tags. If the checkout is shallow, first run `git fetch --unshallow origin`. The planner reads committed history at `HEAD`, so uncommitted changes and an intended future squash title are not included. Confirm the final merge metadata with the reviewer. Refresh the plan and every affected manual version reference if the base release, unreleased commits, merge title, or manual increment changes before merging.

## Mandatory version and information audit

**Every contributor must update every maintained Andriloft version reference and related information that release automation does not update, in the same change.** Derive the version from the Conventional Commit metadata above and derive the description from what the change actually implements. Updating a number alone is insufficient when behavior, compatibility, setup, or validation has changed.

| Release automation owns | Contributors must maintain |
| --- | --- |
| Planned release version and Git commit-count build number; versions stamped into the packaged `Contents/Info.plist`; generated `build-info.json` and `release.json`; versioned ZIP/DMG names; signed appcast; checksums; GitHub release tag and notes generated from commit subjects | Source development defaults in [Assets/Info.plist](Assets/Info.plist); UI labels, help and capability descriptions; [README.md](README.md); installation, marketplace and release guides; authored `docs/releases/vX.Y.Z.md` notes and current links; compatibility claims; [VALIDATION.md](VALIDATION.md) and other maintained information affected by the change |

The bot stamps a copy of the plist inside the app and creates generated release assets. It does **not** edit source files, refresh authored documentation, or write a version-update commit. Set the source semantic version to the planned release and its local build default to the expected Git commit count of the final release commit (`git rev-list --count HEAD` for a committed candidate). Recheck the count after rebasing or squashing; the release workflow supplies the exact count for distributed builds. Prefer reading the packaged bundle version in UI instead of embedding a second version literal.

Before requesting review:

- Search tracked sources and documentation for the previous version and relevant release, capability, and setup text. Inspect every match; cover all maintained references, including examples and links.
- Update source defaults, UI/help, current docs, and authored notes for the target version. Explain new behavior, fixes, supported APIs, remaining limits, and migration or setup changes that apply. Keep a link to published downloads distinct from pending release notes.
- Update validation information with the commands, source/build, date, platform, and outcomes actually observed. Keep prior results labeled as historical and state any checks still pending; do not present old evidence as a new pass.
- Preserve historical release notes and immutable release URLs, the planner's first-release `0.1.0` bootstrap value, deliberate version test fixtures, Android example app versions, dependency versions, and format/protocol versions unless the change specifically updates them. They are not current Andriloft version claims.

## Pull request checklist

- [ ] The commit subjects and final PR title describe the changes and select the intended release increment, including any breaking footer.
- [ ] The target version was checked against the latest release and unreleased changes; the mandatory version and information audit is complete.
- [ ] Source defaults, current links, authored release notes, compatibility limits, and relevant documentation agree with the planned behavior and version.
- [ ] Relevant Swift/Python and real APK checks passed; changed UI or packaging was exercised where applicable, with limitations recorded accurately.
- [ ] `git diff --check` passes, generated distribution assets and credentials are absent, and fixtures or dependency changes have a clear purpose.

Describe the problem, resulting behavior, target release version, and validation in the PR. Wait for CI and maintainer review before merging; every push to `main` starts the release workflow, so the merge must already contain the complete manual version and information updates.
