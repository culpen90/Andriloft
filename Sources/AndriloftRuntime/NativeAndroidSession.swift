import AppKit
import AndriloftCore

public final class NativeAndroidSession: NSObject, NSWindowDelegate {
    public let package: APKPackage
    public let host: AndroidHost
    public let vm: DexVM
    public private(set) var activity: DexObject?
    public private(set) var application: DexObject?
    public private(set) var window: NSWindow?
    public var onClose: (() -> Void)?
    private var didCreate = false
    private var didStart = false
    private var didResume = false
    public var isRunning: Bool { didResume && !host.isFinished }

    public init(package: APKPackage) throws {
        guard package.metadata.mainActivity != nil else { throw AndroidRuntimeError.missingActivity }
        self.package = package
        host = AndroidHost(packageName: package.metadata.packageName, strings: package.strings)
        vm = DexVM(files: try package.dexData.map { try DexFile(data: $0) }, host: host)
        super.init()
        host.virtualMachine = vm
        host.onFinish = { [weak self] in self?.stop() }
    }

    /// Starts the actual APK activity. AppKit access must occur on the main thread.
    public func start(showWindow: Bool = true) throws {
        precondition(Thread.isMainThread)
        guard activity == nil else { throw AndroidRuntimeError.invalidArgument("This activity has already started") }
        if showWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = package.metadata.displayName
            window.appearance = NSAppearance(named: .aqua)
            window.minSize = NSSize(width: 360, height: 300)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            host.window = window
        }
        do {
            let application: DexObject
            if let name = package.metadata.applicationClass {
                application = try vm.newObject(type: "L\(name.replacingOccurrences(of: ".", with: "/"));")
            } else { application = DexObject(type: "Landroid/app/Application;") }
            self.application = application
            host.applicationObject = application
            _ = try vm.invoke(receiver: application, name: "<init>", descriptor: "()V", arguments: [])
            _ = try vm.invoke(receiver: application, name: "onCreate", descriptor: "()V", arguments: [])
            let activityName = package.metadata.mainActivity!
            let activity = try vm.newObject(type: "L\(activityName.replacingOccurrences(of: ".", with: "/"));")
            self.activity = activity
            _ = try vm.invoke(receiver: activity, name: "<init>", descriptor: "()V", arguments: [])
            _ = try vm.invoke(receiver: activity, name: "onCreate", descriptor: "(Landroid/os/Bundle;)V", arguments: [.null])
            didCreate = true
            if host.isFinished { stop(); return }
            _ = try vm.invoke(receiver: activity, name: "onStart", descriptor: "()V", arguments: [])
            didStart = true
            if host.isFinished { stop(); return }
            _ = try vm.invoke(receiver: activity, name: "onResume", descriptor: "()V", arguments: [])
            didResume = true
            if host.isFinished { stop(); return }
            guard host.contentView != nil else { throw AndroidRuntimeError.invalidArgument("The activity did not create a supported native view.") }
            window?.makeKeyAndOrderFront(nil)
            if showWindow { NSApp.activate(ignoringOtherApps: true) }
        } catch {
            window?.close()
            window = nil
            throw error
        }
    }

    public func windowWillClose(_ notification: Notification) {
        finishLifecycle()
        onClose?()
    }
    public func stop() {
        if let window { window.close(); self.window = nil }
        else { finishLifecycle(); onClose?() }
    }
    private func finishLifecycle() {
        if let activity, host.failure == nil {
            do {
                if didResume { _ = try vm.invoke(receiver: activity, name: "onPause", descriptor: "()V", arguments: []) }
                if didStart { _ = try vm.invoke(receiver: activity, name: "onStop", descriptor: "()V", arguments: []) }
                if didCreate { _ = try vm.invoke(receiver: activity, name: "onDestroy", descriptor: "()V", arguments: []) }
            } catch { host.onFailure?(error) }
        }
        didCreate = false; didStart = false; didResume = false
    }
}
