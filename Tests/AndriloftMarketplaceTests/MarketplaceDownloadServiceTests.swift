import XCTest
import CryptoKit
@testable import AndriloftMarketplace

final class MarketplaceDownloadServiceTests: XCTestCase {
    private let app = MarketplaceApp(name: "../Hello/Android", developer: "Example", pageURL: URL(string: "https://www.apkmirror.com/apk/example/hello/")!)
    private func variant(_ version: String, bundle: Bool = false, package: String? = "dev.andriloft.hello", hash: String? = nil) -> APKVariant {
        APKVariant(appName: "Hello Android", version: version, pageURL: URL(string: "https://www.apkmirror.com/apk/example/hello/hello-\(version)-release/")!, isBundle: bundle, packageName: package, sha256: hash)
    }

    func testDownloadsModelsSelectedOlderVersionAndPreservesExistingFiles() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = folder.appendingPathComponent("existing.apk")
        try Data("keep me".utf8).write(to: previous)
        let fixture = Bundle.module.url(forResource: "HelloAndroid", withExtension: "apk", subdirectory: "Fixtures")!
        let hash = SHA256.hash(data: try Data(contentsOf: fixture)).map { String(format: "%02x", $0) }.joined()
        let older = variant("1", hash: hash)
        let catalog = CatalogStub(candidates: [variant("3", bundle: true), variant("2"), older])
        let selector = SelectorStub(selected: older)
        let transfer = FileStub(source: fixture)
        let service = MarketplaceDownloadService(catalog: catalog, selector: selector, directory: folder, downloader: transfer)
        let result = try await service.download(app) { _ in }
        XCTAssertEqual(result.deletingLastPathComponent(), folder)
        XCTAssertFalse(result.lastPathComponent.contains("/"))
        XCTAssertTrue(result.lastPathComponent.contains("-1-"))
        XCTAssertEqual(try Data(contentsOf: result), try Data(contentsOf: fixture))
        XCTAssertEqual(try String(contentsOf: previous), "keep me")
        let offered = await selector.offered
        XCTAssertEqual(offered, [variant("2"), older])
        let resolved = await catalog.resolved
        XCTAssertEqual(resolved, older)
    }

    func testRejectsInventedSelectionBeforeResolvingOrDownloading() async throws {
        let catalog = CatalogStub(candidates: [variant("1")])
        let selector = SelectorStub(selected: variant("99"))
        let service = MarketplaceDownloadService(catalog: catalog, selector: selector, downloader: FailingFileStub())
        do { _ = try await service.download(app) { _ in }; XCTFail("Invented candidate accepted") }
        catch { XCTAssertEqual(error as? MarketplaceError, .invalidSelection) }
        let resolved = await catalog.resolved
        XCTAssertNil(resolved)
    }

    func testNoBundlesReachModel() async throws {
        let catalog = CatalogStub(candidates: [variant("1", bundle: true)])
        let selector = SelectorStub(selected: variant("1", bundle: true))
        let service = MarketplaceDownloadService(catalog: catalog, selector: selector, downloader: FailingFileStub())
        do { _ = try await service.download(app) { _ in }; XCTFail("Bundle accepted") }
        catch { XCTAssertEqual(error as? MarketplaceError, .noVariants) }
        let offered = await selector.offered
        XCTAssertTrue(offered.isEmpty)
    }

    func testKnownOversizedAPKsNeverReachSelector() async throws {
        let oversized = APKVariant(appName: "Firefox", version: "157", pageURL: URL(string: "https://www.apkmirror.com/apk/mozilla/firefox/oversized/")!, fileSize: 624_813_917)
        let small = variant("1")
        let selector = SelectorStub(selected: variant("99"))
        let service = MarketplaceDownloadService(catalog: CatalogStub(candidates: [oversized, small]), selector: selector, downloader: FailingFileStub())
        do { _ = try await service.download(app) { _ in }; XCTFail("Invented candidate accepted") }
        catch { XCTAssertEqual(error as? MarketplaceError, .invalidSelection) }
        let offered = await selector.offered
        XCTAssertEqual(offered, [small])
    }

    func testInvalidPayloadAndWrongIdentityLeaveNoCompletedFile() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fake) }
        try Data("<html>Access denied</html>".utf8).write(to: fake)
        let fixture = Bundle.module.url(forResource: "HelloAndroid", withExtension: "apk", subdirectory: "Fixtures")!
        for (source, selected) in [(fake, variant("1")), (fixture, variant("1", package: "different.app")), (fixture, variant("1", hash: String(repeating: "0", count: 64)))] {
            let service = MarketplaceDownloadService(catalog: CatalogStub(candidates: [selected]), selector: SelectorStub(selected: selected), directory: folder, downloader: FileStub(source: source))
            do { _ = try await service.download(app) { _ in }; XCTFail("Bad payload accepted") }
            catch { XCTAssertNotNil(error as? MarketplaceError) }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    func testSelectorFailureDoesNotFallBackToNewestAPK() async throws {
        let service = MarketplaceDownloadService(catalog: CatalogStub(candidates: [variant("2"), variant("1")]), selector: FailingSelectorStub(), downloader: FailingFileStub())
        do { _ = try await service.download(app) { _ in }; XCTFail("Selection failure was hidden") }
        catch { XCTAssertEqual(error as? MarketplaceError, .invalidSelection) }
    }

    func testCancelledSelectionDoesNotBeginDownload() async throws {
        let service = MarketplaceDownloadService(catalog: CatalogStub(candidates: [variant("1")]), selector: CancelledSelectorStub(), downloader: FailingFileStub())
        do { _ = try await service.download(app) { _ in }; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testDownloadSourcesRequireExactHTTPSAPKMirrorDomain() {
        for source in ["https://www.apkmirror.com/file.apk", "https://download.apkmirror.com/file.apk"] { XCTAssertTrue(APKFileDownloader.isTrusted(URL(string: source)!)) }
        for source in ["http://www.apkmirror.com/file.apk", "https://apkmirror.com.evil.example/file.apk", "https://evilapkmirror.com/file.apk", "https://user@apkmirror.com/file.apk", "https://apkmirror.com:444/file.apk", "file:///tmp/app.apk"] { XCTAssertFalse(APKFileDownloader.isTrusted(URL(string: source)!)) }
    }

    func testOnlyAPKMirrorsObservedSignedCDNCanReceiveRedirects() {
        let host = "eb5e7388c3df147b74dd2379b7cf8323.r2.cloudflarestorage.com"
        let path = "/downloadprod/wp-content/uploads/2026/10/app_apkmirror.com.apk"
        let query = "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=account&X-Amz-Date=20261009T195500Z&X-Amz-Expires=3600&X-Amz-Signature=\(String(repeating: "a", count: 64))"
        let signed = URL(string: "https://\(host)\(path)\(query)")!
        XCTAssertTrue(APKFileDownloader.isAllowedDownloadDestination(signed))
        XCTAssertFalse(APKFileDownloader.isTrusted(signed), "CDN links may only enter through checked redirects")
        for invalid in [
            "https://other.r2.cloudflarestorage.com\(path)\(query)",
            "http://\(host)\(path)\(query)",
            "https://\(host)/other/app_apkmirror.com.apk\(query)",
            "https://\(host)\(path)",
            "https://\(host)\(path)\(query)&X-Amz-Expires=999999"
        ] { XCTAssertFalse(APKFileDownloader.isAllowedDownloadDestination(URL(string: invalid)!)) }
    }

    private func makeDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marketplace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private actor CatalogStub: MarketplaceCatalog {
    let candidates: [APKVariant]
    var resolved: APKVariant?
    init(candidates: [APKVariant]) { self.candidates = candidates }
    func apps(query: String) -> [MarketplaceApp] { [] }
    func variants(for app: MarketplaceApp) -> [APKVariant] { candidates }
    func downloadURL(for variant: APKVariant) -> URL { resolved = variant; return URL(string: "https://download.apkmirror.com/app.apk")! }
}

private actor SelectorStub: VariantSelecting {
    let selected: APKVariant
    var offered: [APKVariant] = []
    init(selected: APKVariant) { self.selected = selected }
    func select(from variants: [APKVariant]) -> APKVariant { offered = variants; return selected }
}

private struct FailingSelectorStub: VariantSelecting {
    func select(from variants: [APKVariant]) throws -> APKVariant { throw MarketplaceError.invalidSelection }
}
private struct CancelledSelectorStub: VariantSelecting {
    func select(from variants: [APKVariant]) throws -> APKVariant { throw CancellationError() }
}
private struct FileStub: APKDownloading {
    let source: URL
    func download(from url: URL, progress: @escaping DownloadProgress) throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("marketplace-fixture-\(UUID().uuidString).apk")
        try FileManager.default.copyItem(at: source, to: temporary)
        progress(0.5)
        return temporary
    }
}
private struct FailingFileStub: APKDownloading {
    func download(from url: URL, progress: @escaping DownloadProgress) throws -> URL { XCTFail("Download should not begin"); throw MarketplaceError.invalidResponse }
}
