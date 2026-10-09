# Hello Android

This is an ordinary Java Android application. Its Activity builds a small interface with Android widgets, persists a tap counter with `SharedPreferences`, handles two `View.OnClickListener` callbacks, reads an `EditText`, and displays a `Toast`.

Build it from the repository root:

```sh
./tools/build-example.sh
```

The script uses an installed Android SDK and JDK to compile Java 8 class files into real DEX, package a binary Android manifest, and sign the result with a local example debug key. It does not boot Android or use an emulator. The output is `Examples/HelloAndroid/build/HelloAndroid.apk`.

The SDK is needed only to build Android examples. Andriloft itself is a native Swift macOS program and does not depend on the SDK at runtime. Override SDK discovery with `ANDROID_SDK_ROOT`, JDK discovery with `JAVA_HOME`, or select installed versions with `ANDROID_BUILD_TOOLS=36.0.0` and `ANDROID_PLATFORM=android-36`.

Run `./tools/package-app.sh --build-example` to include this APK in `build/Andriloft.app`.

The repository includes small compiled APK test fixtures so Swift tests and normal app packaging do not require an Android SDK. Regenerate them with `./tools/build-example.sh --update-fixtures`. The fixtures also exercise unsupported `WebView` failure reporting, custom Application and Activity lifecycle order, and an Activity calling `finish()` during creation.
