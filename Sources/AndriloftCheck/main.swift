import Foundation
import AppKit
import AndriloftCore
import AndriloftRuntime

func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AndroidRuntimeError.invalidArgument(message) }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2, ["--inspect", "--self-test", "--expect-unsupported"].contains(arguments[0]) else {
        print("Usage: andriloft-check --inspect|--self-test|--expect-unsupported app.apk")
        exit(2)
    }
    let apk = try APKPackage(url: URL(fileURLWithPath: arguments[1]))
    let files = try apk.dexData.map { try DexFile(data: $0) }
    if arguments[0] == "--inspect" {
        print("App: \(apk.metadata.displayName) (\(apk.metadata.packageName))")
        print("Version: \(apk.metadata.versionName)")
        print("Launcher: \(apk.metadata.mainActivity ?? "none")")
        print("DEX: \(files.count); classes: \(files.reduce(0) { $0 + $1.classes.count }); native libraries: \(apk.nativeLibraries.count)")
        exit(0)
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    if arguments[0] == "--expect-unsupported" {
        let session = try NativeAndroidSession(package: apk)
        do {
            try session.start(showWindow: false)
            throw AndroidRuntimeError.invalidArgument("Expected WebView to be rejected")
        } catch AndroidRuntimeError.unsupportedAPI(let api) {
            try require(api.contains("WebView"), "Unexpected unsupported API: \(api)")
            print("PASS: unsupported WebView reports the exact Android API")
        }
        exit(0)
    }
    guard apk.metadata.packageName == "dev.andriloft.hello" else { throw AndroidRuntimeError.invalidArgument("--self-test requires the HelloAndroid example APK") }
    let suiteName = AndroidHost.preferenceSuiteName(packageName: apk.metadata.packageName, name: "counter")
    let suite = UserDefaults(suiteName: suiteName)!
    let previous = suite.persistentDomain(forName: suiteName)
    suite.removePersistentDomain(forName: suiteName)
    defer {
        suite.removePersistentDomain(forName: suiteName)
        if let previous { suite.setPersistentDomain(previous, forName: suiteName) }
    }
    let session = try NativeAndroidSession(package: apk)
    var message = ""
    var callbackError: Error?
    session.host.onMessage = { message = $0 }
    session.host.onFailure = { callbackError = $0 }
    try session.start(showWindow: false)
    guard let root = session.host.contentView else { throw AndroidRuntimeError.invalidArgument("No native content view") }
    let controls = descendants(root)
    let fields = controls.compactMap { $0 as? NSTextField }
    let buttons = controls.compactMap { $0 as? NSButton }
    try require(fields.contains { $0.stringValue == "Hello from Android" }, "DEX did not render the heading")
    try require(fields.contains { $0.stringValue == "Button taps: 0" }, "Initial counter incorrect")
    guard let count = buttons.first(where: { $0.title == "Count a tap" }), let greet = buttons.first(where: { $0.title == "Say hello" }), let input = fields.first(where: { $0.isEditable }) else {
        throw AndroidRuntimeError.invalidArgument("APK controls missing")
    }
    count.performClick(nil)
    count.performClick(nil)
    if let callbackError { throw callbackError }
    try require(fields.contains { $0.stringValue == "Button taps: 2" }, "Java click callback did not update the counter")
    try require(suite.integer(forKey: "count") == 2, "SharedPreferences did not persist the guest state")
    input.stringValue = "Andriloft"
    greet.performClick(nil)
    if let callbackError { throw callbackError }
    try require(message == "Hello, Andriloft!", "Java callback did not read native text input: \(message)")
    let reopened = try NativeAndroidSession(package: apk)
    try reopened.start(showWindow: false)
    try require(descendants(reopened.host.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Button taps: 2" }, "Guest state did not survive activity recreation")
    print("PASS: real APK manifest and DEX parsed")
    print("PASS: Activity.onCreate created native AppKit controls")
    print("PASS: Java button callbacks executed and updated text")
    print("PASS: native text input reached Java and Toast output")
    print("PASS: SharedPreferences survived activity recreation")
    print("Framework calls: \(session.host.invocationCount)")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
