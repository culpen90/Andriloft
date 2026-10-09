#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/build/release}"
[[ "$#" -le 1 ]] || { printf 'Usage: %s [output-directory]\n' "$0" >&2; exit 1; }
cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
    printf 'Commit source changes before building a release.\n' >&2
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Assets/Info.plist)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid release version.\n' >&2; exit 1; }
PREFIX="Andriloft-$VERSION-macOS-universal"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
for name in "$PREFIX.zip" "$PREFIX.dmg" SHA256SUMS.txt release.json; do
    [[ ! -e "$OUTPUT/$name" ]] || { printf 'Output already exists: %s\n' "$OUTPUT/$name" >&2; exit 1; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/andriloft-release.XXXXXX")"
DMG_MOUNT=""
cleanup() {
    if [[ -n "$DMG_MOUNT" ]]; then hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/dist"
swift test --scratch-path "$WORK/tests" --xunit-output "$WORK/test-results.xml"
ANDRILOFT_UNIVERSAL=1 ANDRILOFT_SCRATCH_PATH="$WORK/swiftbuild" \
    ANDRILOFT_APP_OUTPUT="$WORK/Andriloft.app" \
    ANDRILOFT_DEMO_APK="$ROOT/Tests/AndriloftTests/Fixtures/HelloAndroid.apk" \
    "$ROOT/tools/package-app.sh"
APP="$WORK/Andriloft.app"
"$APP/Contents/MacOS/andriloft-check" --self-test "$APP/Contents/Resources/HelloAndroid.apk"
"$APP/Contents/MacOS/andriloft-check" --expect-unsupported "$ROOT/Tests/AndriloftTests/Fixtures/UnsupportedAndroid.apk"
EXECUTION_ARCHS=("$(uname -m)")
if [[ "${ANDRILOFT_VERIFY_ROSETTA:-0}" == "1" ]]; then
    [[ "$(uname -m)" == "arm64" ]] || { printf 'Rosetta checks require an Apple Silicon host.\n' >&2; exit 1; }
    /usr/bin/arch -x86_64 "$APP/Contents/MacOS/andriloft-check" --self-test "$APP/Contents/Resources/HelloAndroid.apk"
    EXECUTION_ARCHS+=(x86_64)
fi
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$WORK/dist/$PREFIX.zip"
mkdir -p "$WORK/extracted"
/usr/bin/ditto -x -k "$WORK/dist/$PREFIX.zip" "$WORK/extracted"
codesign --verify --deep --strict "$WORK/extracted/Andriloft.app"
"$WORK/extracted/Andriloft.app/Contents/MacOS/andriloft-check" --self-test "$WORK/extracted/Andriloft.app/Contents/Resources/HelloAndroid.apk"
mkdir -p "$WORK/dmg"
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP" "$WORK/dmg/Andriloft.app"
ln -s /Applications "$WORK/dmg/Applications"
cp docs/INSTALL.md "$WORK/dmg/Install.md"
hdiutil create -volname "Andriloft $VERSION" -srcfolder "$WORK/dmg" -ov -format UDZO "$WORK/dist/$PREFIX.dmg"
hdiutil verify "$WORK/dist/$PREFIX.dmg"
DMG_MOUNT="$WORK/mounted"
mkdir -p "$DMG_MOUNT"
hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT" "$WORK/dist/$PREFIX.dmg"
codesign --verify --deep --strict "$DMG_MOUNT/Andriloft.app"
"$DMG_MOUNT/Andriloft.app/Contents/MacOS/andriloft-check" --self-test "$DMG_MOUNT/Andriloft.app/Contents/Resources/HelloAndroid.apk"
hdiutil detach "$DMG_MOUNT"
DMG_MOUNT=""
python3 "$ROOT/tools/release-manifest.py" "$ROOT" "$APP" "$WORK/dist" "$WORK/test-results.xml" "${EXECUTION_ARCHS[@]}"
(cd "$WORK/dist" && /usr/bin/shasum -a 256 "$PREFIX.zip" "$PREFIX.dmg" release.json > SHA256SUMS.txt)
for name in "$PREFIX.zip" "$PREFIX.dmg" SHA256SUMS.txt release.json; do
    cp "$WORK/dist/$name" "$OUTPUT/$name"
done
printf 'Verified release assets: %s\n' "$OUTPUT"
