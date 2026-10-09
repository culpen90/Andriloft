import AppKit
import Combine
import Sparkle

@MainActor public final class AppUpdater: ObservableObject {
    @Published public private(set) var canCheckForUpdates = false
    public let version: String
    private var updater: SPUUpdater?
    private var startupError: Error?

    public init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        // `swift run` is not an installed app bundle and must not try to replace its executable.
        guard bundle.bundleURL.pathExtension == "app" else { return }
        let standardDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let driver = InstallOnApprovalDriver(userDriver: standardDriver)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        do { try updater.start() } catch {
            startupError = error
            canCheckForUpdates = true
        }
    }

    public func checkForUpdates() {
        if let startupError {
            let alert = NSAlert(error: startupError)
            alert.runModal()
        } else if canCheckForUpdates {
            updater?.checkForUpdates()
        }
    }
}
