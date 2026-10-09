import XCTest
import AppKit
import AndriloftCore
import AndriloftRuntime

final class RuntimeTests: XCTestCase {
    func testApplicationInitializationAndCompleteActivityLifecycle() throws {
        _ = NSApplication.shared
        let url = try XCTUnwrap(Bundle.module.url(forResource: "LifecycleAndroid", withExtension: "apk", subdirectory: "Fixtures"))
        let session = try NativeAndroidSession(package: APKPackage(url: url))
        var events: [String] = []
        session.host.onMessage = { events.append($0) }
        try session.start(showWindow: false)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(events, ["Lifecycle: application", "Lifecycle: class-init", "Lifecycle: constructor", "Lifecycle: create", "Lifecycle: start", "Lifecycle: resume"])
        session.stop()
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(Array(events.suffix(3)), ["Lifecycle: pause", "Lifecycle: stop", "Lifecycle: destroy"])
        session.stop()
        XCTAssertEqual(events.count, 9, "Teardown must happen only once")
    }

    func testFinishingOnCreateNeverResumesOrOpensActivity() throws {
        _ = NSApplication.shared
        let url = try XCTUnwrap(Bundle.module.url(forResource: "FinishAndroid", withExtension: "apk", subdirectory: "Fixtures"))
        let session = try NativeAndroidSession(package: APKPackage(url: url))
        var events: [String] = []
        session.host.onMessage = { events.append($0) }
        try session.start(showWindow: false)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.window)
        XCTAssertEqual(events, ["Finish: create", "Finish: destroy"])
    }

    func testActualAPKExecutesCallbacksAndPersistsState() throws {
        _ = NSApplication.shared
        let url = try XCTUnwrap(Bundle.module.url(forResource: "HelloAndroid", withExtension: "apk", subdirectory: "Fixtures"))
        let apk = try APKPackage(url: url)
        let suiteName = AndroidHost.preferenceSuiteName(packageName: apk.metadata.packageName, name: "counter")
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let prior = suite.persistentDomain(forName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName); if let prior { suite.setPersistentDomain(prior, forName: suiteName) } }
        let session = try NativeAndroidSession(package: apk)
        var failure: Error?
        var message = ""
        session.host.onFailure = { failure = $0 }
        session.host.onMessage = { message = $0 }
        try session.start(showWindow: false)
        let controls = flatten(try XCTUnwrap(session.host.contentView))
        let fields = controls.compactMap { $0 as? NSTextField }
        let buttons = controls.compactMap { $0 as? NSButton }
        XCTAssertTrue(fields.contains { $0.stringValue == "Button taps: 0" })
        let count = try XCTUnwrap(buttons.first { $0.title == "Count a tap" })
        count.performClick(nil)
        XCTAssertNil(failure)
        XCTAssertTrue(fields.contains { $0.stringValue == "Button taps: 1" })
        XCTAssertEqual(suite.integer(forKey: "count"), 1)
        try XCTUnwrap(fields.first { $0.isEditable }).stringValue = "Native Mac"
        try XCTUnwrap(buttons.first { $0.title == "Say hello" }).performClick(nil)
        XCTAssertNil(failure)
        XCTAssertEqual(message, "Hello, Native Mac!")
        let second = try NativeAndroidSession(package: apk)
        try second.start(showWindow: false)
        XCTAssertTrue(flatten(try XCTUnwrap(second.host.contentView)).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Button taps: 1" })
    }

    func testUnsupportedAPKReturnsActionableAPIFailure() throws {
        _ = NSApplication.shared
        let url = try XCTUnwrap(Bundle.module.url(forResource: "UnsupportedAndroid", withExtension: "apk", subdirectory: "Fixtures"))
        let session = try NativeAndroidSession(package: APKPackage(url: url))
        XCTAssertThrowsError(try session.start(showWindow: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("WebView"), error.localizedDescription)
        }
    }

    private func flatten(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(flatten) }
}
