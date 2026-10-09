#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ANDRILOFT_APP_OUTPUT:-$ROOT/build/Andriloft.app}"
DEMO="$ROOT/Examples/HelloAndroid/build/HelloAndroid.apk"
if [[ ! -f "$DEMO" ]]; then
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
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Assets/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/Andriloft" "$APP/Contents/MacOS/Andriloft"
cp "$BIN_DIR/andriloft-check" "$APP/Contents/MacOS/andriloft-check"
chmod +x "$APP/Contents/MacOS/Andriloft" "$APP/Contents/MacOS/andriloft-check"
swift "$ROOT/tools/make-icon.swift" "$ROOT/build/Andriloft.iconset"
iconutil -c icns "$ROOT/build/Andriloft.iconset" -o "$APP/Contents/Resources/Andriloft.icns"
if [[ -f "$DEMO" ]]; then
    cp "$DEMO" "$APP/Contents/Resources/HelloAndroid.apk"
else
    printf 'No demo APK found; run tools/build-example.sh to build the bundled example.\n' >&2
fi
plutil -lint "$APP/Contents/Info.plist"
/usr/bin/xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Packaged %s\n' "$APP"
