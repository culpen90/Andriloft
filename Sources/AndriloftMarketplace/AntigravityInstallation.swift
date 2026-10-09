import Foundation
import CryptoKit

/// Installs Google's signed CLI without changing shell profiles or user settings.
public actor AntigravityInstallation {
    public static let shared = AntigravityInstallation()
    public static let version = "1.3.2"
    private let directory: URL
    private var preparing = false

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Andriloft/Antigravity", isDirectory: true)
    }

    public func existingExecutable() -> URL? {
        let url = directory.appendingPathComponent(Self.version, isDirectory: true).appendingPathComponent("agy")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public func executable() async throws -> URL {
        while preparing { try await Task.sleep(nanoseconds: 100_000_000) }
        preparing = true
        defer { preparing = false }
        try Task.checkCancellation()
        if let existing = existingExecutable() {
            try Self.verifySignature(existing)
            return existing
        }
        let destination = directory.appendingPathComponent(Self.version, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("andriloft-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        #if arch(arm64)
        let asset = Self.arm64Asset
        #else
        let asset = Self.intelAsset
        #endif
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (download, response) = try await session.download(from: asset.url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == asset.url,
              let size = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 200 * 1024 * 1024 else { throw AntigravityError.installationFailed }
        let handle = try FileHandle(forReadingFrom: download)
        defer { try? handle.close() }
        var hash = SHA512()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha512 else {
            throw AntigravityError.installationFailed
        }
        try Task.checkCancellation()
        try Self.execute("/usr/bin/tar", arguments: ["-xzf", download.path, "-C", staging.path, "antigravity"])
        let binary = staging.appendingPathComponent("antigravity")
        let values = try binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AntigravityError.installationFailed }
        try Self.verifySignature(binary)
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let installed = destination.appendingPathComponent("agy")
        try FileManager.default.moveItem(at: binary, to: installed)
        return installed
    }

    private static func verifySignature(_ binary: URL) throws {
        try execute("/usr/bin/codesign", arguments: ["--verify", "--strict", "-R",
            "=identifier \"cli\" and anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\"", binary.path])
    }

    private static func execute(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AntigravityError.installationFailed }
    }

    // Official updater manifests, captured for this release. Both payloads must also
    // satisfy Apple's Google LLC code-signing requirement before execution.
    static let arm64Asset = Asset(url: URL(string: "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.3.2-5813501495738368/darwin-arm/cli_mac_arm64.tar.gz")!,
        sha512: "02dd409d8d40bdae4a97196c81ee009b90bbe4673ae380f0cd2b2b4eff05556d0668e9182d6d61f1cebc8a0b0c3594e11d514071175f41d71011e82bb31c9f22")
    static let intelAsset = Asset(url: URL(string: "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.3.2-5813501495738368/darwin-x64/cli_mac_x64.tar.gz")!,
        sha512: "fd7a26466bba15d4f858e9ecd455bd4d1da2ee49a31572b752c29e802332a087a9ed90365ca17b3455dd5786712405a148ac42c7a557b41c044c92559409b16e")
    struct Asset { let url: URL; let sha512: String }
}
