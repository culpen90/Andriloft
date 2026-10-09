import Foundation
import Sparkle

/// Keeps Sparkle's native UI while treating Install Update as approval to finish and restart.
@MainActor final class InstallOnApprovalDriver: NSObject, SPUUserDriver {
    private let userDriver: any SPUUserDriver
    private var installApproved = false

    init(userDriver: any SPUUserDriver) {
        self.userDriver = userDriver
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        userDriver.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        installApproved = false
        userDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installApproved = false
        userDriver.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            self?.installApproved = choice == .install && !appcastItem.isInformationOnlyUpdate
            reply(choice)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        userDriver.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        userDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installApproved = false
        userDriver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installApproved = false
        userDriver.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        userDriver.showDownloadInitiated(cancellation: { [weak self] in
            self?.installApproved = false
            cancellation()
        })
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        userDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        userDriver.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        userDriver.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        userDriver.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installApproved {
            reply(.install)
        } else {
            userDriver.showReady(toInstallAndRelaunch: reply)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        userDriver.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        installApproved = false
        userDriver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        installApproved = false
        userDriver.dismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        userDriver.showUpdateInFocus?()
    }
}
