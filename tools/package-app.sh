#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="$(python3 "$ROOT/tools/check-release-version.py" resolve "$ROOT/Assets/Info.plist")"
read -r VERSION BUILD_NUMBER <<< "$VERSIONS"
APP="${ANDRILOFT_APP_OUTPUT:-$ROOT/build/Andriloft.app}"
DEMO="${ANDRILOFT_DEMO_APK:-$ROOT/Examples/HelloAndroid/build/HelloAndroid.apk}"
if [[ ! -f "$DEMO" ]]; then
    if [[ -n "${ANDRILOFT_DEMO_APK:-}" ]]; then
        printf 'Configured example APK does not exist: %s\n' "$DEMO" >&2
        exit 1
    fi
    DEMO="$ROOT/Tests/AndriloftTests/Fixtures/HelloAndroid.apk"
fi

if [[ "${1:-}" == "--build-example" ]]; then
    "$ROOT/tools/build-example.sh"
    DEMO="$ROOT/Examples/HelloAndroid/build/HelloAndroid.apk"
elif [[ -n "${1:-}" ]]; then
    printf 'Usage: %s [--build-example]\n' "$0" >&2
    exit 1
fi

cd "$ROOT"
BUILD_FLAGS=(-c release)
if [[ -n "${ANDRILOFT_SCRATCH_PATH:-}" ]]; then
    BUILD_FLAGS+=(--scratch-path "$ANDRILOFT_SCRATCH_PATH")
fi
if [[ "${ANDRILOFT_UNIVERSAL:-0}" == "1" ]]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
elif [[ "${ANDRILOFT_UNIVERSAL:-0}" != "0" ]]; then
    printf 'ANDRILOFT_UNIVERSAL must be 0 or 1.\n' >&2
    exit 1
fi
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
SPARKLE_ROOT="${ANDRILOFT_SCRATCH_PATH:-$ROOT/.build}/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { printf 'Resolved Sparkle framework is missing: %s\n' "$SPARKLE_FRAMEWORK" >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
# Preserve symlinks, executables, and the upstream signatures of Sparkle's helpers.
/usr/bin/ditto --norsrc --noextattr --noqtn "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_ROOT/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp "$ROOT/Assets/Info.plist" "$APP/Contents/Info.plist"
python3 "$ROOT/tools/check-release-version.py" stamp "$APP/Contents/Info.plist" "$VERSION" "$BUILD_NUMBER"
cp "$BIN_DIR/Andriloft" "$APP/Contents/MacOS/Andriloft"
cp "$BIN_DIR/andriloft-check" "$APP/Contents/MacOS/andriloft-check"
chmod +x "$APP/Contents/MacOS/Andriloft" "$APP/Contents/MacOS/andriloft-check"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/andriloft-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
swift "$ROOT/tools/make-icon.swift" "$ICON_WORK/Andriloft.iconset"
iconutil -c icns "$ICON_WORK/Andriloft.iconset" -o "$APP/Contents/Resources/Andriloft.icns"
if [[ -f "$DEMO" ]]; then
    cp "$DEMO" "$APP/Contents/Resources/HelloAndroid.apk"
else
    printf 'No demo APK found; run tools/build-example.sh to build the bundled example.\n' >&2
fi
plutil -lint "$APP/Contents/Info.plist"
python3 - "$APP" "$ROOT" <<'PY'
import json, pathlib, plistlib, subprocess, sys
app, root = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip())
payload = {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
           "source_sha": source_sha, "source_dirty": dirty, "configuration": "release",
           "signing": "ad-hoc", "notarized": False}
(app / "Contents/Resources/build-info.json").write_text(json.dumps(payload, indent=2) + "\n")
PY
/usr/bin/xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/andriloft-check"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
codesign --verify --strict --all-architectures "$APP/Contents/MacOS/andriloft-check"
if [[ "${ANDRILOFT_UNIVERSAL:-0}" == "1" ]]; then
    for executable in Andriloft andriloft-check; do
        ARCHS="$(lipo -archs "$APP/Contents/MacOS/$executable")"
        if [[ "$ARCHS" != "arm64 x86_64" && "$ARCHS" != "x86_64 arm64" ]]; then
            printf '%s is not universal: %s\n' "$executable" "$ARCHS" >&2
            exit 1
        fi
    done
fi
printf 'Packaged %s\n' "$APP"
