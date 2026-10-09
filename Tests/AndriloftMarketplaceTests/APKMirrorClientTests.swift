import XCTest
@testable import AndriloftMarketplace

final class APKMirrorClientTests: XCTestCase {
    private let base = URL(string: "https://www.apkmirror.com/")!
    private let appURL = URL(string: "https://www.apkmirror.com/apk/mozilla/firefox/")!
    private let releaseURL = URL(string: "https://www.apkmirror.com/apk/mozilla/firefox/firefox-157-0-1-release/")!

    func testAppSearchUsesAppIdentityAndExcludesSidebarAndDuplicateReleases() throws {
        let html = """
        <div id="content">
          <div class="appRow"><div class="table-row">
            <img src="/icon.png"><div><h5 class="appRowTitle"><a href="/apk/mozilla/firefox/">Firefox Fast &amp; Private Browser</a></h5>
            <a class="byDeveloper" href="/apk/mozilla/">by Mozilla</a></div>
          </div></div>
          <div class="appRow"><h5 class="appRowTitle"><a href="/apk/mozilla/firefox/firefox-157-release/">Firefox 157</a></h5></div>
        </div>
        <aside><h5 class="appRowTitle"><a href="/apk/other/ad/">An advertisement</a></h5></aside>
        """
        let apps = try APKMirrorClient.parseApps(html, baseURL: base)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].name, "Firefox Fast & Private Browser")
        XCTAssertEqual(apps[0].developer, "Mozilla")
        XCTAssertEqual(apps[0].pageURL, appURL)
        XCTAssertEqual(apps[0].iconURL, URL(string: "https://www.apkmirror.com/icon.png"))
    }

    func testHomePageVersionStrippedFromTitleUsingAdjacentMetadata() throws {
        let html = """
        <main id=content><div><div class=appRow><div class=table-row><h5 class=appRowTitle><a href='/apk/mozilla/firefox/firefox-157-release/'>Firefox 157.0</a></h5><a class=byDeveloper>by Mozilla</a></div></div>
        <div class=infoSlide><p><span class=infoSlide-name>Version:</span><span class=infoSlide-value>157.0</span></p></div></div></main>
        """
        XCTAssertEqual(try APKMirrorClient.parseApps(html, baseURL: base).first?.name, "Firefox")
    }

    func testVariantTableSeparatesAPKAndBundleAndParsesSDK() throws {
        let html = "<h1>Firefox 157.0.1 beta</h1><main id='primary'>" +
            row(version: "157.0.1", suffix: "2", architecture: "universal", android: "Android 12L+", dpi: "120-640dpi", format: "BUNDLE") +
            row(version: "157.0.1", suffix: "1", architecture: "arm64-v8a", android: "Android 8.0+", dpi: "nodpi", format: "APK") + "</main>"
        let variants = try APKMirrorClient.parseVariants(html, baseURL: releaseURL, appName: "Firefox")
        XCTAssertEqual(variants.count, 2)
        XCTAssertTrue(variants[0].isBundle)
        XCTAssertEqual(variants[0].minimumSDK, 32)
        XCTAssertFalse(variants[1].isBundle)
        XCTAssertEqual(variants[1].minimumSDK, 26)
        XCTAssertEqual(variants[1].architecture, "arm64-v8a")
        XCTAssertTrue(variants.allSatisfy(\.isPrerelease))
    }

    func testFileHashNeverUsesCertificateFingerprint() throws {
        let variant = APKVariant(appName: "Firefox", version: "157.0.1", pageURL: URL(string: "file-android-apk-download/", relativeTo: releaseURL)!.absoluteURL)
        let html = detail(package: "org.mozilla.firefox", sha: String(repeating: "b", count: 64))
        let enriched = try APKMirrorClient.enrich(variant, html: html)
        XCTAssertEqual(enriched.packageName, "org.mozilla.firefox")
        XCTAssertEqual(enriched.minimumSDK, 26)
        XCTAssertEqual(enriched.sha256, String(repeating: "b", count: 64))
        XCTAssertEqual(enriched.fileSize, 624_813_917)
    }

    func testDownloadTraversesLandingAndRejectsAdvertisement() throws {
        let html = "<main id='primary'><a href='https://advert.example/download.apk'>Download APK</a><a class='downloadButton' href='file-android-apk-download/download/?key=one&amp;forcebaseapk=true'>Download APK</a></main>"
        let landing = try APKMirrorClient.downloadLink(html, baseURL: releaseURL)
        XCTAssertEqual(URLComponents(url: landing, resolvingAgainstBaseURL: true)?.queryItems?.last?.value, "true")
        let final = try APKMirrorClient.downloadLink("<main id='content'><a id='download-link' href='/wp-content/themes/APKMirror/download.php?id=1&amp;key=two'>here</a></main>", baseURL: landing)
        XCTAssertEqual(final.path, "/wp-content/themes/APKMirror/download.php")
        XCTAssertThrowsError(try APKMirrorClient.downloadLink("<a class='downloadButton' href='https://evil.example/file.apk'>Download APK</a>", baseURL: base))
    }

    func testSourceValidationRequiresHTTPSAndAPKMirrorAuthority() {
        for value in ["http://www.apkmirror.com/file", "https://www.apkmirror.com.evil.example/file", "https://apkmirror.com@evil.example/file", "https://user@apkmirror.com/file", "https://apkmirror.com:444/file", "file:///tmp/app.apk"] {
            XCTAssertFalse(APKMirrorSourcePolicy.isAllowed(URL(string: value)!), value)
        }
        XCTAssertTrue(APKMirrorSourcePolicy.isAllowed(URL(string: "https://downloadr2.apkmirror.com/file.apk")!))
    }

    func testChallengeFailsWithoutInventedListings() throws {
        XCTAssertThrowsError(try APKMirrorClient.parseApps("<title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/cf-chl-test'></script>", baseURL: base)) { error in
            XCTAssertTrue(error.localizedDescription.contains("blocking"))
        }
    }

    func testDepthBoundRejectsPathologicalDocument() {
        let html = String(repeating: "<div>", count: 400) + "content" + String(repeating: "</div>", count: 400)
        XCTAssertThrowsError(try APKMirrorClient.parseApps(html, baseURL: base))
    }

    func testHTMLDecodesUnicodeAndIgnoresScriptPseudoMarkup() {
        let document = APKMirrorHTML("<script><h5>fake</h5></script><p title='a > b'>Wikiloc &#x1F30D; &amp; &#8211;</p>")
        XCTAssertEqual(document.root.first(where: { $0.tag == "p" })?.trimmedText, "Wikiloc 🌍 & –")
        XCTAssertEqual(document.root.first(where: { $0.tag == "p" })?.attributes["title"], "a > b")
        XCTAssertNil(document.root.first(where: { $0.tag == "h5" }))
    }

    func testRecentReleasesHaveSeparateStandaloneQuotasAndCache() async throws {
        let release2 = URL(string: "https://www.apkmirror.com/apk/mozilla/firefox/firefox-156-release/")!
        let appPage = "<main id='primary'>" + [releaseURL, release2].map { "<h5 class='appRowTitle'><a href='\($0.absoluteString)'>Firefox</a></h5>" }.joined() + "</main>"
        var pages: [URL: String] = [appURL: appPage]
        for (release, version) in [(releaseURL, "157"), (release2, "156")] {
            pages[release] = "<main id='primary'>" + (1...5).map { row(version: version, suffix: String($0), architecture: $0 == 5 ? "universal" : "arm64-v8a", android: "Android 8.0+", dpi: $0 == 5 ? "nodpi" : "\($0 * 80)dpi", format: "APK", release: release) }.joined() + "</main>"
            for index in 1...5 {
                pages[URL(string: "file-\(index)-android-apk-download/", relativeTo: release)!.absoluteURL] = detail(package: "org.mozilla.firefox", sha: String(repeating: "b", count: 64))
            }
        }
        let loader = FixtureLoader(pages: pages)
        let client = APKMirrorClient(pageLoader: loader, requestInterval: 0, releaseLimit: 2, candidateLimit: 4)
        let app = MarketplaceApp(name: "Firefox", developer: "Mozilla", pageURL: appURL)
        let variants = try await client.variants(for: app)
        XCTAssertEqual(variants.count, 4)
        XCTAssertEqual(variants.map(\.version), ["157", "157", "156", "156"])
        XCTAssertEqual(variants.filter { $0.architecture == "universal" }.count, 2)
        _ = try await client.variants(for: app)
        let loadCount = await loader.count
        XCTAssertEqual(loadCount, 7)
    }

    func testProviderTraversesRealDownloadStages() async throws {
        let variantURL = URL(string: "file-1-android-apk-download/", relativeTo: releaseURL)!.absoluteURL
        let landingURL = URL(string: "download/?key=one", relativeTo: variantURL)!.absoluteURL
        let loader = FixtureLoader(pages: [variantURL: "<main id='primary'><a class='downloadButton' href='download/?key=one'>Download APK</a></main>", landingURL: "<main id='content'><a id='download-link' href='/wp-content/themes/APKMirror/download.php?id=1&amp;key=two'>here</a></main>"])
        let client = APKMirrorClient(pageLoader: loader, requestInterval: 0)
        let url = try await client.downloadURL(for: APKVariant(appName: "Firefox", version: "157", pageURL: variantURL))
        XCTAssertEqual(url.absoluteString, "https://www.apkmirror.com/wp-content/themes/APKMirror/download.php?id=1&key=two")
    }

    private func row(version: String, suffix: String, architecture: String, android: String, dpi: String, format: String, release: URL? = nil) -> String {
        let url = URL(string: "file-\(suffix)-android-apk-download/", relativeTo: release ?? releaseURL)!.absoluteURL
        return """
        <div class="table-row headerFont"><div class="table-cell"><a href="\(url)">\(version)</a><span class="apkm-badge">\(format)</span><br><span>12345</span></div><div class="table-cell">\(architecture)</div><div class="table-cell">\(android)</div><div class="table-cell">\(dpi)</div></div>
        """
    }

    private func detail(package: String, sha: String) -> String {
        """
        <main id="primary"><div class="appspec-row"><div class="appspec-value">App: Firefox<br>Version: 157.0.1<br><span>Package: \(package)</span></div></div>
        <div class="appspec-row"><svg><use xlink:href="#apkm-icon-sdk"></use></svg><div>Min: Android 8.0 (Oreo, API 26)<br>Target: Android 17 (API 37)</div></div>
        <div class="appspec-row"><svg><use xlink:href="#apkm-icon-filesize"></use></svg><div>595.87 MB (624,813,917 bytes)</div></div>
        <a class="downloadButton" href="download/?key=one">Download APK</a></main>
        <div id="safeDownload"><h4>APK certificate fingerprints</h4>SHA-256: <span>\(String(repeating: "a", count: 64))</span><h4>APK file hashes</h4>SHA-256: <span>\(sha)</span></div>
        """
    }
}

private actor FixtureLoader: APKMirrorPageLoading {
    let pages: [URL: String]
    private(set) var count = 0
    init(pages: [URL: String]) { self.pages = pages }
    func load(_ url: URL) async throws -> APKMirrorPage {
        count += 1
        guard let html = pages[url] else { throw MarketplaceError.invalidResponse }
        return APKMirrorPage(html: html, url: url)
    }
}
