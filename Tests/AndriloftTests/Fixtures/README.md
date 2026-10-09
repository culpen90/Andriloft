# Real Android APK fixtures

`HelloAndroid.apk` is compiled from `Examples/HelloAndroid/src/dev/andriloft/hello/MainActivity.java`. `UnsupportedAndroid.apk` is compiled from its `unsupported` source directory and calls `android.webkit.WebView`, which the initial compatibility layer does not support.

`LifecycleAndroid.apk` comes from the `lifecycle` source directory. Its custom Application logs `application`, then its Activity logs `class-init`, `constructor`, `create`, `start`, `resume`, `pause`, `stop`, and `destroy` using the `Lifecycle` log tag. Its interface contains a TextView.

`FinishAndroid.apk` comes from the `finish` source directory. Its Activity logs `create` using the `Finish` log tag and calls `finish()` immediately. A correct lifecycle calls `destroy` once without calling `start` or `resume`.

All fixtures contain a standard binary Android manifest and DEX bytecode produced with the Android SDK tools. They are signed with an example debug key; that key has no production use. No Android OS or emulator is used to build or run them through Andriloft.

Regenerate from source with:

```sh
./tools/build-example.sh --update-fixtures
```

The fixtures let Swift tests run without installing an Android SDK. App packaging uses the checked-in HelloAndroid fixture when a freshly built example is unavailable.
