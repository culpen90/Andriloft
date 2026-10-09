import Foundation
import CryptoKit
import AndriloftCore

public typealias DownloadProgress = @Sendable (Double?) -> Void

public protocol APKDownloading: Sendable {
    /// Returns a temporary file owned by the caller.
    func download(from url: URL, progress: @escaping DownloadProgress) async throws -> URL
}

/// The model can choose only a discovered candidate. It never supplies a download URL
/// or receives permission to run code, launch an app, or change the user's library.
public actor MarketplaceDownloadService {
    private let catalog: any MarketplaceCatalog
    private let selector: any VariantSelecting
    private let downloader: any APKDownloading
    private let directory: URL
    private var active: Set<String> = []

    public init(catalog: any MarketplaceCatalog = APKMirrorClient(), selector: any VariantSelecting = AntigravitySelector(), directory: URL? = nil, downloader: any APKDownloading = APKFileDownloader()) {
        self.catalog = catalog; self.selector = selector; self.downloader = downloader
        self.directory = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Andriloft", isDirectory: true)
    }

    public func apps(query: String) async throws -> [MarketplaceApp] {
        try await catalog.apps(query: query)
    }

    public func download(_ app: MarketplaceApp, progress: @escaping DownloadProgress) async throws -> URL {
        guard active.insert(app.id).inserted else { throw MarketplaceError.unavailable("This app is already downloading.") }
        defer { active.remove(app.id) }
        progress(nil)
        try Task.checkCancellation()
        let standalone = try await catalog.variants(for: app).filter { !$0.isBundle }
        guard !standalone.isEmpty else { throw MarketplaceError.noVariants }
        let variants = standalone.filter { $0.fileSize.map { $0 > 0 && $0 <= 512 * 1024 * 1024 } ?? true }
        guard !variants.isEmpty else { throw MarketplaceError.unavailable("Available APKs exceed the supported download size of 512 MiB.") }
        let selected = try await selector.select(from: variants)
        // Compare every field, so even a custom selector cannot change candidate metadata.
        guard variants.contains(selected), !selected.isBundle else { throw MarketplaceError.invalidSelection }
        try Task.checkCancellation()
        let source = try await catalog.downloadURL(for: selected)
        let temporary = try await downloader.download(from: source, progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try Self.validate(temporary, variant: selected)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Unique names preserve existing downloads; no untrusted path components are used.
        let fileName = "\(Self.safeName(app.name))-\(Self.safeName(selected.version))-\(UUID().uuidString.prefix(8)).apk"
        let destination = directory.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }

    static func validate(_ url: URL, variant: APKVariant) throws {
        do {
            let package = try APKPackage(url: url)
            if let expected = variant.sha256 {
                guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
                    throw MarketplaceError.invalidDownload("The file checksum could not be verified.")
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == expected.lowercased() else {
                    throw MarketplaceError.invalidDownload("The downloaded file did not match its published checksum. Please try again.")
                }
            }
            if let expected = variant.packageName, package.metadata.packageName != expected {
                throw MarketplaceError.invalidDownload("The downloaded file belongs to a different app.")
            }
            guard !package.dexData.isEmpty else {
                throw MarketplaceError.invalidDownload("This APK does not contain a standalone app.")
            }
            _ = try package.dexData.map { try DexFile(data: $0) }
        } catch let error as MarketplaceError { throw error }
        catch APKError.unsupportedArchive {
            throw MarketplaceError.invalidDownload("This APK exceeds Andriloft’s archive limits or uses an unsupported archive format.")
        }
        catch DexError.unsupported {
            throw MarketplaceError.invalidDownload("This APK uses Android bytecode that Andriloft does not support yet.")
        }
        catch DexError.limit {
            throw MarketplaceError.invalidDownload("This APK exceeds Andriloft’s bytecode validation limits.")
        }
        catch { throw MarketplaceError.invalidDownload("The downloaded file is not a valid standalone APK. Please try again.") }
    }

    static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let name = String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return name.isEmpty || name == "." || name == ".." ? "app" : name
    }
}
