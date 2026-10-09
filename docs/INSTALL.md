# Install Andriloft

Andriloft requires **macOS 13 or newer**. Each universal download contains executables for **Apple Silicon (`arm64`)** and **Intel (`x86_64`)**. Native GUI validation was performed on Apple Silicon; physical Intel Macs and older supported macOS versions have not been exercised. The release manifest records execution checks for each tested architecture.

The download is a production Swift Release build of the macOS application, with the example APK included. You do not need Xcode, Swift, Java, an Android SDK, or an Apple Developer account to run it. The compatibility layer itself is experimental: most existing third-party Android apps are not supported.

## Download

Get the files from the [latest official GitHub release](https://github.com/culpen90/Andriloft/releases/latest). Replace `<version>` below with that release's version:

| File | Purpose |
| --- | --- |
| `Andriloft-<version>-macOS-universal.dmg` | Drag-and-drop installer. |
| `Andriloft-<version>-macOS-universal.zip` | The same app in a ZIP archive. |
| `SHA256SUMS.txt` | SHA-256 checksums for the release files. |
| `release.json` | Build, version, and signing metadata. |

To check a download, run `shasum -a 256` on the downloaded file in Terminal and compare the result with its matching line in `SHA256SUMS.txt`.

## Install the app

1. Open the DMG and drag **Andriloft.app** onto the **Applications** shortcut. If you use the ZIP, extract it and move **Andriloft.app** into **Applications** in Finder.
2. Eject the DMG, if used.
3. Open **Andriloft** from **Applications**.

## First launch and Gatekeeper

This release has an **ad hoc code signature**. It has no Apple Developer ID signature and is not notarized by Apple. An ad hoc signature lets macOS verify bundle integrity; it does not establish a verified developer identity. The release is distributed through GitHub without a paid Apple Developer membership or the Mac App Store.

macOS may block the downloaded app on its first launch. If you trust the official release and want to open it:

1. Try opening **Andriloft.app** from **Applications**, then dismiss the blocked-launch alert.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the security message about Andriloft and click **Open Anyway**.
4. Confirm **Open** in the next prompt and authenticate if macOS requests it.

This grants an exception for Andriloft. Apple's [Safely open apps on your Mac](https://support.apple.com/en-us/102445) explains this supported process. A managed Mac may restrict these settings. If macOS reports that the app is damaged or will harm your computer, check the download and its checksum instead of treating that warning as the normal unidentified-developer prompt.

## Update inside Andriloft

Choose **Check for Updates…** in the sidebar or the **Andriloft** menu. When a newer version is available, choose **Install Update**. Andriloft downloads and verifies the signed update, installs it, and restarts automatically. Open Android app windows close during the restart; your imported APK library and saved preferences remain in place.

Updates use free Sparkle signing and ad hoc macOS signing. No Apple Developer account or subscription is required. macOS may ask for your password if you do not have permission to replace the installed app. Run Andriloft from **Applications**, after ejecting the installation DMG.

Versions released before the updater was added need one manual installation of an updater-enabled version. Future releases can then be installed from within the app. A failed download or signature check leaves the installed version in place and displays an error; retry the check when connectivity is restored.

## Run an APK

Click **Try the example**, then **Run app** to launch the included Android example. Its buttons and editable input execute compiled Java DEX bytecode through native macOS controls.

To import another APK, click **Add APK**, drop an APK into Andriloft's window, or use Finder's **Open With → Andriloft**. Andriloft keeps imported copies under `~/Library/Application Support/Andriloft/` and saves guest preferences in separate macOS preference stores for each Android package.

Use APKs from sources you trust. APK code runs inside Andriloft's process; the compatibility layer is not a sandbox for hostile APKs, and APK signing certificates are not verified. AndroidX, Compose, native Android libraries/JNI, Google Play services, and many Android APIs are not implemented. Unsupported calls produce an error instead of starting Android. See the [release notes](https://github.com/culpen90/Andriloft/releases/latest) and [README](https://github.com/culpen90/Andriloft/blob/main/README.md) for the implemented subset.

## Remove the app

Quit Andriloft and move **Andriloft.app** from **Applications** to the Trash. Imported APKs remain in `~/Library/Application Support/Andriloft/`; remove that folder separately if you also want to delete the library. Removing the app or library does not clear the guest preference stores.
