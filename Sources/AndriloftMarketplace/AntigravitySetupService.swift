import Foundation
import AppKit

public enum AntigravitySetupStatus: Sendable, Equatable {
    case notInstalled, signedOut, ready
}

/// Account tokens stay in Google's CLI/Keychain; Andriloft never reads them.
public actor AntigravitySetupService {
    public static let shared = AntigravitySetupService()
    private let installation: AntigravityInstallation

    public init(installation: AntigravityInstallation = .shared) { self.installation = installation }

    public func status() async throws -> AntigravitySetupStatus {
        guard await installation.existingExecutable() != nil else { return .notInstalled }
        let binary = try await installation.executable()
        do {
            // The built-in command checks account access without sending a model prompt.
            let result = try await AntigravityCLI.run(arguments: ["--agent", AntigravityCLI.agentName, "--model", AntigravityRunner.model,
                "--sandbox", "-p", "/usage", "--output-format", "json", "--print-timeout", "20s"],
                                                     executable: binary, timeout: 30)
            guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
                  object["status"] as? String == "SUCCESS",
                  let command = object["command"] as? [String: Any], command["name"] as? String == "usage",
                  let data = command["data"] as? [String: Any],
                  let groups = data["groups"] as? [[String: Any]], !groups.isEmpty
            else { throw AntigravityError.unavailable }
            return .ready
        } catch AntigravityError.authenticationRequired { return .signedOut }
    }

    public func connectGoogleAccount() async throws {
        let binary = try await installation.executable()
        try Task.checkCancellation()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Andriloft/Antigravity/SignIn", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let command = directory.appendingPathComponent("Connect Google account.command")
        let script = "#!/bin/sh\ncd \(Self.shellQuote(directory.path)) || exit 1\nexec \(Self.shellQuote(binary.path))\n"
        try Data(script.utf8).write(to: command, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let opened = await MainActor.run { NSWorkspace.shared.open(command) }
        guard opened else { throw AntigravityError.unavailable }
    }

    static func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
