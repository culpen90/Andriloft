#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/Examples/HelloAndroid"
OUTPUT="$EXAMPLE/build"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
UPDATE_FIXTURES=false
if [[ "${1:-}" == "--update-fixtures" ]]; then
    UPDATE_FIXTURES=true
elif [[ -n "${1:-}" ]]; then
    printf 'Usage: %s [--update-fixtures]\n' "$0" >&2
    exit 1
fi

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ -d "$SDK" ]] || fail "Android SDK not found. Set ANDROID_SDK_ROOT to an SDK containing a platform and build-tools."

if [[ -n "${ANDROID_BUILD_TOOLS:-}" ]]; then
    BUILD_TOOLS="$SDK/build-tools/$ANDROID_BUILD_TOOLS"
else
    BUILD_VERSION="$(for candidate in "$SDK"/build-tools/*; do basename "$candidate"; done | sed -nE '/^[0-9]+\.[0-9]+\.[0-9]+$/p' | sort -t . -k1,1n -k2,2n -k3,3n | tail -1)"
    BUILD_TOOLS="$SDK/build-tools/$BUILD_VERSION"
fi
[[ -x "$BUILD_TOOLS/aapt" && -x "$BUILD_TOOLS/d8" ]] || fail "Install Android SDK build-tools (tested with 36.0.0), or set ANDROID_BUILD_TOOLS to an installed version."

if [[ -n "${ANDROID_PLATFORM:-}" ]]; then
    ANDROID_JAR="$SDK/platforms/$ANDROID_PLATFORM/android.jar"
else
    PLATFORM_VERSION="$(for candidate in "$SDK"/platforms/android-*; do basename "$candidate"; done | sed 's/^android-//' | sed -nE '/^[0-9]+$/p' | sort -n | tail -1)"
    ANDROID_JAR="$SDK/platforms/android-$PLATFORM_VERSION/android.jar"
fi
[[ -f "$ANDROID_JAR" ]] || fail "Install an Android SDK platform (tested with android-36), or set ANDROID_PLATFORM to an installed platform."

if [[ -z "${JAVA_HOME:-}" ]]; then
    if [[ -x /usr/libexec/java_home ]]; then
        JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null || true)"
    fi
fi
[[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]] || fail "Install a JDK 17 or newer and set JAVA_HOME."
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

# An ordinary debug signature also makes this APK installable on a real Android device.
# This key is only for the example and stays in its ignored build directory.
mkdir -p "$OUTPUT"
if [[ ! -f "$OUTPUT/debug.keystore" ]]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$OUTPUT/debug.keystore" \
        -storepass android -keypass android -alias androiddebugkey -keyalg RSA \
        -keysize 2048 -validity 10000 -dname "CN=Andriloft Example, O=Andriloft, C=US" >/dev/null 2>&1
fi
build_apk() {
    local manifest="$1" name="$2"
    shift 2
    local classes="$OUTPUT/$name-classes" dex="$OUTPUT/$name-dex"
    mkdir -p "$classes" "$dex"
    # Source files are explicitly listed so stale/generated classes are never packaged.
    find "$classes" -type f -delete
    find "$dex" -type f -delete
    rm -f "$OUTPUT/$name-classes.jar" "$OUTPUT/$name-unsigned.apk" "$OUTPUT/$name-aligned.apk" "$OUTPUT/$name.apk"
    "$JAVA_HOME/bin/javac" --release 8 -Xlint:-options -classpath "$ANDROID_JAR" -d "$classes" "$@"
    "$JAVA_HOME/bin/jar" --create --file "$OUTPUT/$name-classes.jar" -C "$classes" .
    "$BUILD_TOOLS/d8" --lib "$ANDROID_JAR" --min-api 23 --output "$dex" "$OUTPUT/$name-classes.jar"
    "$BUILD_TOOLS/aapt" package -f -M "$manifest" -I "$ANDROID_JAR" -F "$OUTPUT/$name-unsigned.apk"
    (cd "$dex" && /usr/bin/zip -q "$OUTPUT/$name-unsigned.apk" classes.dex)
    "$BUILD_TOOLS/zipalign" -f 4 "$OUTPUT/$name-unsigned.apk" "$OUTPUT/$name-aligned.apk"
    "$BUILD_TOOLS/apksigner" sign --ks "$OUTPUT/debug.keystore" --ks-key-alias androiddebugkey \
        --ks-pass pass:android --key-pass pass:android --out "$OUTPUT/$name.apk" "$OUTPUT/$name-aligned.apk"
    "$BUILD_TOOLS/apksigner" verify "$OUTPUT/$name.apk"
    printf 'Built %s\n' "$OUTPUT/$name.apk"
}

build_apk "$EXAMPLE/AndroidManifest.xml" "HelloAndroid" "$EXAMPLE/src/dev/andriloft/hello/MainActivity.java"
if [[ "$UPDATE_FIXTURES" == true ]]; then
    build_apk "$EXAMPLE/unsupported/AndroidManifest.xml" "UnsupportedAndroid" "$EXAMPLE/unsupported/src/dev/andriloft/unsupported/MainActivity.java"
    build_apk "$EXAMPLE/lifecycle/AndroidManifest.xml" "LifecycleAndroid" \
        "$EXAMPLE/lifecycle/src/dev/andriloft/lifecycle/LifecycleApplication.java" \
        "$EXAMPLE/lifecycle/src/dev/andriloft/lifecycle/MainActivity.java"
    build_apk "$EXAMPLE/finish/AndroidManifest.xml" "FinishAndroid" "$EXAMPLE/finish/src/dev/andriloft/finish/MainActivity.java"
    mkdir -p "$ROOT/Tests/AndriloftTests/Fixtures"
    for fixture in HelloAndroid UnsupportedAndroid LifecycleAndroid FinishAndroid; do
        cp "$OUTPUT/$fixture.apk" "$ROOT/Tests/AndriloftTests/Fixtures/$fixture.apk"
    done
    printf 'Updated test APK fixtures.\n'
fi
