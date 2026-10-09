import XCTest
import Sparkle
@testable import AndriloftUpdates

@MainActor
final class InstallOnApprovalDriverTests: XCTestCase {
    func testInstallApprovalFinishesWithoutASecondConfirmation() throws {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        let item = SUAppcastItem.empty()
        let state = try makeUpdateState()
        var initialReply: SPUUserUpdateChoice?
        driver.showUpdateFound(with: item, state: state) { initialReply = $0 }

        XCTAssertTrue(native.presentedItem === item)
        XCTAssertTrue(native.presentedState === state)
        XCTAssertNil(initialReply)
        native.updateReply?(.install)
        XCTAssertEqual(initialReply, .install)

        var readyReply: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { readyReply = $0 })
        XCTAssertEqual(readyReply, .install)
        XCTAssertEqual(native.readyPromptCount, 0)
    }

    func testDismissAndSkipDoNotAuthorizeInstallation() throws {
        for choice: SPUUserUpdateChoice in [.dismiss, .skip] {
            let native = RecordingUserDriver()
            let driver = InstallOnApprovalDriver(userDriver: native)
            var initialReply: SPUUserUpdateChoice?
            driver.showUpdateFound(with: SUAppcastItem.empty(), state: try makeUpdateState()) { initialReply = $0 }
            native.updateReply?(choice)
            XCTAssertEqual(initialReply, choice)

            var readyReply: SPUUserUpdateChoice?
            driver.showReady(toInstallAndRelaunch: { readyReply = $0 })
            XCTAssertNil(readyReply)
            XCTAssertEqual(native.readyPromptCount, 1)
            native.readyReply?(.dismiss)
            XCTAssertEqual(readyReply, .dismiss)
        }
    }

    func testBackgroundDownloadStillNeedsUserApproval() {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        var reply: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { reply = $0 })
        XCTAssertNil(reply)
        XCTAssertEqual(native.readyPromptCount, 1)
        native.readyReply?(.install)
        XCTAssertEqual(reply, .install)
    }

    func testDismissingInstallationClearsEarlierApproval() throws {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        driver.showUpdateFound(with: SUAppcastItem.empty(), state: try makeUpdateState()) { _ in }
        native.updateReply?(.install)
        driver.dismissUpdateInstallation()
        XCTAssertEqual(native.dismissCount, 1)

        var reply: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { reply = $0 })
        XCTAssertNil(reply)
        XCTAssertEqual(native.readyPromptCount, 1)
    }

    func testNewCheckDoesNotReuseEarlierApproval() throws {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        driver.showUpdateFound(with: SUAppcastItem.empty(), state: try makeUpdateState()) { _ in }
        native.updateReply?(.install)

        var checkCancelled = false
        driver.showUserInitiatedUpdateCheck { checkCancelled = true }
        native.checkCancellation?()
        XCTAssertTrue(checkCancelled)

        var reply: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { reply = $0 })
        XCTAssertNil(reply)
        XCTAssertEqual(native.readyPromptCount, 1)
    }

    func testShowingAnotherUpdateDoesNotReuseEarlierApproval() throws {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        let state = try makeUpdateState()
        driver.showUpdateFound(with: SUAppcastItem.empty(), state: state) { _ in }
        native.updateReply?(.install)
        driver.showUpdateFound(with: SUAppcastItem.empty(), state: state) { _ in }

        var reply: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { reply = $0 })
        XCTAssertNil(reply)
        XCTAssertEqual(native.readyPromptCount, 1)
    }

    func testInformationalUpdateDoesNotAuthorizeInstallation() throws {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        // This public constructor is sufficient for a fixture; version-dependent fields are not used.
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": "2",
            "link": "https://example.invalid/release"
        ]))
        XCTAssertTrue(item.isInformationOnlyUpdate)
        driver.showUpdateFound(with: item, state: try makeUpdateState()) { _ in }
        native.updateReply?(.install)

        var reply: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { reply = $0 })
        XCTAssertNil(reply)
        XCTAssertEqual(native.readyPromptCount, 1)
    }

    func testAnUpdateErrorClearsEarlierApproval() throws {
        for noUpdateFound in [false, true] {
            let native = RecordingUserDriver()
            let driver = InstallOnApprovalDriver(userDriver: native)
            driver.showUpdateFound(with: SUAppcastItem.empty(), state: try makeUpdateState()) { _ in }
            native.updateReply?(.install)
            let error = NSError(domain: "AndriloftUpdatesTests", code: 17)
            if noUpdateFound {
                driver.showUpdateNotFoundWithError(error) {}
            } else {
                driver.showUpdaterError(error) {}
            }

            var reply: SPUUserUpdateChoice?
            driver.showReady(toInstallAndRelaunch: { reply = $0 })
            XCTAssertNil(reply)
            XCTAssertEqual(native.readyPromptCount, 1)
        }
    }

    func testCancellingADownloadClearsEarlierApproval() throws {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        driver.showUpdateFound(with: SUAppcastItem.empty(), state: try makeUpdateState()) { _ in }
        native.updateReply?(.install)
        var downloadCancelled = false
        driver.showDownloadInitiated { downloadCancelled = true }
        native.downloadCancellation?()
        XCTAssertTrue(downloadCancelled)

        var reply: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { reply = $0 })
        XCTAssertNil(reply)
        XCTAssertEqual(native.readyPromptCount, 1)
    }

    func testNativeDownloadProgressAndCancellationAreForwarded() {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        var cancelled = false
        driver.showDownloadInitiated { cancelled = true }
        driver.showDownloadDidReceiveExpectedContentLength(8192)
        driver.showDownloadDidReceiveData(ofLength: 4096)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.5)

        XCTAssertEqual(native.progressEvents, [.downloadStarted, .expectedLength(8192), .receivedLength(4096), .extracting, .extractionProgress(0.5)])
        native.downloadCancellation?()
        XCTAssertTrue(cancelled)
    }

    func testNativeErrorsAndAcknowledgementsAreForwarded() {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        let error = NSError(domain: "AndriloftUpdatesTests", code: 17)
        var notFoundAcknowledged = false
        var errorAcknowledged = false
        driver.showUpdateNotFoundWithError(error) { notFoundAcknowledged = true }
        driver.showUpdaterError(error) { errorAcknowledged = true }
        driver.showUpdateReleaseNotesFailedToDownloadWithError(error)

        XCTAssertTrue(native.notFoundError as NSError? === error)
        XCTAssertTrue(native.updaterError as NSError? === error)
        XCTAssertTrue(native.releaseNotesError as NSError? === error)
        XCTAssertFalse(notFoundAcknowledged)
        XCTAssertFalse(errorAcknowledged)
        native.notFoundAcknowledgement?()
        native.errorAcknowledgement?()
        XCTAssertTrue(notFoundAcknowledged)
        XCTAssertTrue(errorAcknowledged)
    }

    func testNativeInstallationRetryAndCompletionAreForwarded() {
        let native = RecordingUserDriver()
        let driver = InstallOnApprovalDriver(userDriver: native)
        var terminationRetried = false
        var completionAcknowledged = false
        driver.showInstallingUpdate(withApplicationTerminated: false) { terminationRetried = true }
        driver.showUpdateInstalledAndRelaunched(true) { completionAcknowledged = true }
        XCTAssertEqual(native.applicationTerminated, false)
        XCTAssertEqual(native.relaunched, true)
        native.terminationRetry?()
        native.installationAcknowledgement?()
        XCTAssertTrue(terminationRetried)
        XCTAssertTrue(completionAcknowledged)
    }

    private func makeUpdateState() throws -> SPUUserUpdateState {
        // Sparkle exposes state construction through NSSecureCoding, not a public initializer.
        try XCTUnwrap(SPUUserUpdateState(coder: UpdateStateDecoder()))
    }
}

private final class UpdateStateDecoder: NSCoder {
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int {
        SPUUserUpdateStage.notDownloaded.rawValue
    }
    override func decodeBool(forKey key: String) -> Bool { true }
}

@MainActor
private final class RecordingUserDriver: NSObject, SPUUserDriver {
    enum ProgressEvent: Equatable {
        case downloadStarted
        case expectedLength(UInt64)
        case receivedLength(UInt64)
        case extracting
        case extractionProgress(Double)
    }

    var presentedItem: SUAppcastItem?
    var presentedState: SPUUserUpdateState?
    var updateReply: ((SPUUserUpdateChoice) -> Void)?
    var readyReply: ((SPUUserUpdateChoice) -> Void)?
    var readyPromptCount = 0
    var dismissCount = 0
    var checkCancellation: (() -> Void)?
    var downloadCancellation: (() -> Void)?
    var progressEvents: [ProgressEvent] = []
    var notFoundError: Error?
    var updaterError: Error?
    var releaseNotesError: Error?
    var notFoundAcknowledgement: (() -> Void)?
    var errorAcknowledgement: (() -> Void)?
    var applicationTerminated: Bool?
    var terminationRetry: (() -> Void)?
    var relaunched: Bool?
    var installationAcknowledgement: (() -> Void)?

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {}
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { checkCancellation = cancellation }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        presentedItem = appcastItem
        presentedState = state
        updateReply = reply
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { releaseNotesError = error }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        notFoundError = error
        notFoundAcknowledgement = acknowledgement
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updaterError = error
        errorAcknowledgement = acknowledgement
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        progressEvents.append(.downloadStarted)
        downloadCancellation = cancellation
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { progressEvents.append(.expectedLength(expectedContentLength)) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { progressEvents.append(.receivedLength(length)) }
    func showDownloadDidStartExtractingUpdate() { progressEvents.append(.extracting) }
    func showExtractionReceivedProgress(_ progress: Double) { progressEvents.append(.extractionProgress(progress)) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyPromptCount += 1
        readyReply = reply
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        self.applicationTerminated = applicationTerminated
        terminationRetry = retryTerminatingApplication
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        self.relaunched = relaunched
        installationAcknowledgement = acknowledgement
    }
    func dismissUpdateInstallation() { dismissCount += 1 }
}
