import Foundation
import XCTest
@testable import AndriloftMarketplace

final class AntigravityInstallationTests: XCTestCase {
    func testUnsignedCachedExecutableIsRejectedBeforeItCanRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("andriloft-unsigned-cli-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent(AntigravityInstallation.version, isDirectory: true)
            .appendingPathComponent("agy")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        let executionMarker = directory.appendingPathComponent("executed")
        let script = "#!/bin/sh\n/usr/bin/touch \(AntigravitySetupService.shellQuote(executionMarker.path))\n"
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let installation = AntigravityInstallation(directory: directory)
        let detected = await installation.existingExecutable()
        XCTAssertEqual(detected, binary)

        do {
            _ = try await AntigravitySetupService(installation: installation).status()
            XCTFail("Account checks must reject an unsigned cached CLI before executing it.")
        } catch { XCTAssertEqual(error as? AntigravityError, .installationFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: executionMarker.path))
        XCTAssertEqual(try Data(contentsOf: binary), Data(script.utf8))
    }

    func testStatusForMissingInstallationDoesNotInstallOrCreateFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("andriloft-missing-cli-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installation = AntigravityInstallation(directory: directory)
        let status = try await AntigravitySetupService(installation: installation).status()
        XCTAssertEqual(status, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
