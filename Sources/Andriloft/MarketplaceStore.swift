import AppKit
import SwiftUI
import AndriloftMarketplace

enum MarketplaceDownloadState: Equatable {
    case preparing
    case downloading(Double)
    case cancelling
    case completed(URL)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .downloading, .cancelling: return true
        case .completed, .failed: return false
        }
    }

    var fileURL: URL? {
        if case .completed(let url) = self { return url }
        return nil
    }

    var isCancelling: Bool {
        if case .cancelling = self { return true }
        return false
    }
}

enum MarketplaceAccountState: Equatable {
    case checking
    case notInstalled
    case signedOut
    case ready
    case unavailable
}

@MainActor final class MarketplaceStore: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { search(debounce: true) } }
    }
    @Published private(set) var apps: [MarketplaceApp] = []
    @Published private(set) var isLoading = false
    @Published private(set) var searchError: String?
    @Published private(set) var downloads: [String: MarketplaceDownloadState] = [:]
    @Published private(set) var accountState: MarketplaceAccountState = .checking
    @Published var isAccountSetupPresented = false
    @Published private(set) var isSettingUpAccount = false
    @Published private(set) var signInWindowOpened = false
    @Published private(set) var accountSetupError: String?

    private let service: MarketplaceDownloadService
    private let accountSetup: AntigravitySetupService
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadIDs: [String: UUID] = [:]
    private var hasLoaded = false
    private var accountTask: Task<Void, Never>?
    private var accountID = UUID()
    private var pendingDownload: MarketplaceApp?

    init(service: MarketplaceDownloadService = MarketplaceDownloadService(), accountSetup: AntigravitySetupService = .shared) {
        self.service = service
        self.accountSetup = accountSetup
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        search(debounce: false)
        checkAccountConnection()
    }

    func refresh() { search(debounce: false) }

    func download(_ app: MarketplaceApp) {
        startDownload(app, checkAccount: true)
    }

    private func startDownload(_ app: MarketplaceApp, checkAccount: Bool) {
        guard downloadTasks[app.id] == nil else { return }
        let requestID = UUID()
        downloadIDs[app.id] = requestID
        downloads[app.id] = .preparing
        downloadTasks[app.id] = Task { [weak self] in
            guard let self else { return }
            do {
                if checkAccount {
                    let status = try await accountSetup.status()
                    try Task.checkCancellation()
                    guard downloadIDs[app.id] == requestID else { return }
                    accountState = Self.accountState(for: status)
                    if accountState != .ready {
                        pendingDownload = app
                        accountSetupError = nil
                        isAccountSetupPresented = true
                        downloads.removeValue(forKey: app.id)
                        finishDownloadTask(app, requestID: requestID)
                        return
                    }
                }
                let url = try await service.download(app) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, downloadIDs[app.id] == requestID,
                              downloads[app.id]?.isCancelling != true else { return }
                        if let progress, progress.isFinite {
                            downloads[app.id] = .downloading(min(1, max(0, progress)))
                        } else {
                            downloads[app.id] = .preparing
                        }
                    }
                }
                try Task.checkCancellation()
                guard downloadIDs[app.id] == requestID else { return }
                downloads[app.id] = .completed(url)
            } catch is CancellationError {
                guard downloadIDs[app.id] == requestID else { return }
                downloads.removeValue(forKey: app.id)
            } catch {
                guard downloadIDs[app.id] == requestID else { return }
                if Task.isCancelled { downloads.removeValue(forKey: app.id) }
                else if let authError = error as? AntigravityError, case .authenticationRequired = authError {
                    accountState = .signedOut
                    pendingDownload = app
                    accountSetupError = nil
                    isAccountSetupPresented = true
                    downloads.removeValue(forKey: app.id)
                }
                else {
                    downloads[app.id] = .failed(Self.userFacingMessage(
                        for: error, fallback: "The download could not be completed. Please try again."
                    ))
                }
            }
            finishDownloadTask(app, requestID: requestID)
        }
    }

    private func finishDownloadTask(_ app: MarketplaceApp, requestID: UUID) {
        guard downloadIDs[app.id] == requestID else { return }
        downloadTasks.removeValue(forKey: app.id)
        downloadIDs.removeValue(forKey: app.id)
    }

    func showAccountSetup() {
        accountSetupError = nil
        isAccountSetupPresented = true
        checkAccountConnection()
    }

    func dismissAccountSetup() {
        isAccountSetupPresented = false
        pendingDownload = nil
        cancelAccountActivity()
    }

    func accountSetupDidDismiss() {
        // A fresh authentication error may have opened another sheet while the
        // previous one was closing. Its requested download must remain pending.
        guard !isAccountSetupPresented else { return }
        pendingDownload = nil
        cancelAccountActivity()
    }

    private func cancelAccountActivity() {
        // Invalidate both the task and its generation: an in-flight successful
        // check must never resume a request after the user cancelled setup.
        accountID = UUID()
        accountTask?.cancel()
        accountTask = nil
        isSettingUpAccount = false
        if accountState == .checking { accountState = .unavailable }
    }

    func connectGoogleAccount() {
        guard !isSettingUpAccount else { return }
        accountTask?.cancel()
        let requestID = UUID()
        accountID = requestID
        isSettingUpAccount = true
        accountSetupError = nil
        accountTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await accountSetup.connectGoogleAccount()
                try Task.checkCancellation()
                guard accountID == requestID else { return }
                // Opening Google's setup window is not proof that sign-in succeeded.
                signInWindowOpened = true
                accountState = .signedOut
            } catch {
                guard !Task.isCancelled, accountID == requestID else { return }
                accountSetupError = "Google account setup could not open. Please try again."
            }
            guard accountID == requestID else { return }
            isSettingUpAccount = false
            accountTask = nil
        }
    }

    func checkAccountConnection(resumePendingDownload: Bool = false) {
        guard !isSettingUpAccount else { return }
        accountTask?.cancel()
        let requestID = UUID()
        accountID = requestID
        accountState = .checking
        accountSetupError = nil
        accountTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await accountSetup.status()
                try Task.checkCancellation()
                guard accountID == requestID else { return }
                accountState = Self.accountState(for: status)
                if resumePendingDownload {
                    if accountState == .ready {
                        let app = pendingDownload
                        pendingDownload = nil
                        isAccountSetupPresented = false
                        if let app { startDownload(app, checkAccount: false) }
                    } else {
                        accountSetupError = "Finish signing in with Google in the setup window, then check again."
                    }
                }
            } catch {
                guard !Task.isCancelled, accountID == requestID else { return }
                accountState = .unavailable
                accountSetupError = "Your Google account connection could not be checked. Please try again."
            }
            guard accountID == requestID else { return }
            accountTask = nil
        }
    }

    private static func accountState(for status: AntigravitySetupStatus) -> MarketplaceAccountState {
        switch status {
        case .notInstalled: return .notInstalled
        case .signedOut: return .signedOut
        case .ready: return .ready
        }
    }

    func cancelDownload(_ app: MarketplaceApp) {
        guard let task = downloadTasks[app.id] else { return }
        // Wait for cleanup before enabling another attempt, and ignore any progress
        // already queued by the cancelled download.
        downloads[app.id] = .cancelling
        task.cancel()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func search(debounce: Bool) {
        searchTask?.cancel()
        let requestID = UUID()
        searchID = requestID
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        searchError = nil
        apps = []
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(nanoseconds: 350_000_000) }
                try Task.checkCancellation()
                let results = try await service.apps(query: text)
                try Task.checkCancellation()
                guard searchID == requestID else { return }
                apps = results
                isLoading = false
            } catch {
                guard !Task.isCancelled, searchID == requestID else { return }
                searchError = Self.userFacingMessage(
                    for: error, fallback: "Apps could not load. Please check your connection and try again."
                )
                isLoading = false
            }
        }
    }

    private static func userFacingMessage(for error: Error, fallback: String) -> String {
        // Only deliberate app-facing messages may reach the cards. Underlying
        // transport, process, and file errors may reveal private preparation details.
        if let marketplaceError = error as? MarketplaceError { return marketplaceError.localizedDescription }
        if let accountError = error as? AntigravityError { return accountError.localizedDescription }
        return fallback
    }
}
