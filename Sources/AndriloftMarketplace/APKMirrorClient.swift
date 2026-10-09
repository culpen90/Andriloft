import Foundation

public enum APKMirrorSourcePolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host == "apkmirror.com" || host.hasSuffix(".apkmirror.com")
    }
    static func pageURL(_ value: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL, isAllowed(url),
              ["www.apkmirror.com", "apkmirror.com"].contains(url.host?.lowercased() ?? "") else { throw MarketplaceError.unsafeURL }
        return withoutFragment(url)
    }
    static func withoutFragment(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url ?? url
    }
}

public struct APKMirrorPage: Sendable {
    public let html: String
    public let url: URL
    public init(html: String, url: URL) { self.html = html; self.url = url }
}

public protocol APKMirrorPageLoading: Sendable {
    func load(_ url: URL) async throws -> APKMirrorPage
}

/// Reads public APKMirror pages using normal offscreen WebKit navigation on macOS.
/// A challenge remains an ordinary failed request; this client never solves it.
public actor APKMirrorClient: MarketplaceCatalog {
    private let loader: any APKMirrorPageLoading
    private let requestInterval: TimeInterval
    private let releaseLimit: Int
    private let candidateLimit: Int
    private let cacheDuration: TimeInterval
    private var cache: [URL: (Date, APKMirrorPage)] = [:]
    private var pending: [URL: Task<APKMirrorPage, Error>] = [:]
    private var previous: Task<APKMirrorPage, Error>?

    public init(pageLoader: any APKMirrorPageLoading = APKMirrorBrowserPageLoader(), requestInterval: TimeInterval = 3, cacheDuration: TimeInterval = 300, releaseLimit: Int = 3, candidateLimit: Int = 24) {
        loader = pageLoader; self.requestInterval = max(0, requestInterval); self.cacheDuration = max(0, cacheDuration)
        self.releaseLimit = max(1, min(5, releaseLimit)); self.candidateLimit = max(1, min(24, candidateLimit))
    }

    public func apps(query: String) async throws -> [MarketplaceApp] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://www.apkmirror.com/")!
        if !query.isEmpty {
            components.queryItems = [URLQueryItem(name: "post_type", value: "app_release"), URLQueryItem(name: "searchtype", value: "app"), URLQueryItem(name: "s", value: String(query.prefix(200)))]
        }
        let page = try await page(components.url!)
        let result = try Self.parseApps(page.html, baseURL: page.url)
        if result.isEmpty, !query.isEmpty, page.html.localizedCaseInsensitiveContains("No results") { return [] }
        guard !result.isEmpty else { throw MarketplaceError.unavailable("APKMirror’s catalog is temporarily unavailable. Please try again later.") }
        return result
    }

    public func variants(for app: MarketplaceApp) async throws -> [APKVariant] {
        let appURL = try APKMirrorSourcePolicy.pageURL(app.pageURL.absoluteString, relativeTo: app.pageURL)
        let listing = try await page(appURL)
        let releases = try Self.releaseURLs(listing.html, baseURL: listing.url, appURL: appURL)
        var result: [APKVariant] = [], bundles: [APKVariant] = []
        let releasesToRead = Array(releases.prefix(releaseLimit))
        let perRelease = max(1, candidateLimit / max(1, releasesToRead.count))
        for releaseURL in releasesToRead {
            try Task.checkCancellation()
            let release = try await page(releaseURL)
            let variants = try Self.parseVariants(release.html, baseURL: release.url, appName: app.name)
            // Reserve standalone candidates for each recent release. An enormous
            // latest-release bundle table must not crowd out older APK choices.
            bundles += variants.filter(\.isBundle).prefix(2)
            let standalone = Self.sampleStandalone(variants.filter { !$0.isBundle }, limit: perRelease)
            for variant in standalone where !result.contains(where: { $0.id == variant.id }) {
                guard result.count < candidateLimit else { break }
                let detail = try await page(variant.pageURL)
                result.append(try Self.enrich(variant, html: detail.html))
            }
        }
        guard !result.isEmpty else { throw MarketplaceError.noVariants }
        return result + bundles.prefix(max(0, 32 - result.count))
    }

    public func downloadURL(for variant: APKVariant) async throws -> URL {
        guard !variant.isBundle else { throw MarketplaceError.noVariants }
        var url = try APKMirrorSourcePolicy.pageURL(variant.pageURL.absoluteString, relativeTo: variant.pageURL)
        var visited = Set<URL>()
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard visited.insert(url).inserted else { throw MarketplaceError.invalidResponse }
            let response = try await page(url, useCache: !url.path.contains("/download/"))
            let step = try Self.downloadLink(response.html, baseURL: response.url)
            if step.path.hasSuffix("/download.php") || step.path.lowercased().hasSuffix(".apk") { return step }
            guard step.path.hasPrefix(variant.pageURL.path.trimmingTrailingSlash + "/") else { throw MarketplaceError.unsafeURL }
            url = step
        }
        throw MarketplaceError.unavailable("APKMirror could not prepare the download. Please try again later.")
    }

    private func page(_ url: URL, useCache: Bool = true) async throws -> APKMirrorPage {
        guard APKMirrorSourcePolicy.isAllowed(url) else { throw MarketplaceError.unsafeURL }
        try Task.checkCancellation()
        if useCache, let entry = cache[url], Date().timeIntervalSince(entry.0) < cacheDuration { return entry.1 }
        let task: Task<APKMirrorPage, Error>
        if let existing = pending[url] { task = existing }
        else {
            let predecessor = previous, loader = loader, interval = requestInterval
            task = Task {
                if let predecessor { _ = await predecessor.result; try Task.checkCancellation(); try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                try Task.checkCancellation()
                let page = try await loader.load(url)
                guard APKMirrorSourcePolicy.isAllowed(page.url), page.html.utf8.count <= 8 * 1024 * 1024 else { throw MarketplaceError.invalidResponse }
                try Self.checkPage(page.html)
                return page
            }
            pending[url] = task; previous = task
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            pending[url] = nil
            if useCache { cache[url] = (Date(), result) }
            if cache.count > 80 { cache = cache.filter { Date().timeIntervalSince($0.value.0) < cacheDuration } }
            return result
        } catch { pending[url] = nil; throw error }
    }

    static func checkPage(_ html: String) throws {
        let lower = html.lowercased()
        let blockedTitle = !APKMirrorHTML.matches(#"(?is)<title[^>]*>\s*(?:just a moment|403 forbidden|access denied|attention required|verify you are human)"#, html).isEmpty
        if lower.contains("cf-chl-") || blockedTitle {
            throw MarketplaceError.unavailable("APKMirror is temporarily blocking this request. Please try again later.")
        }
    }

    static func parseApps(_ html: String, baseURL: URL) throws -> [MarketplaceApp] {
        try checkPage(html)
        let document = APKMirrorHTML(html)
        guard document.isValid else { throw MarketplaceError.invalidResponse }
        var result: [MarketplaceApp] = [], seen = Set<URL>()
        for heading in document.main.descendants(where: { $0.hasClass("appRowTitle") }) {
            guard let link = heading.first(where: { $0.tag == "a" }), let href = link.attributes["href"] else { continue }
            let source = try APKMirrorSourcePolicy.pageURL(href, relativeTo: baseURL)
            let components = source.path.split(separator: "/")
            guard components.count >= 3, components[0] == "apk" else { continue }
            let appURL = URL(string: "/apk/\(components[1])/\(components[2])/", relativeTo: baseURL)!.absoluteURL
            guard seen.insert(appURL).inserted else { continue }
            let row = heading.ancestor { $0.hasClass("appRow") || $0.hasClass("table-row") } ?? heading.parent ?? heading
            let developerText = row.first { $0.hasClass("byDeveloper") }?.trimmedText
            let developer = developerText?.replacingOccurrences(of: #"^by\s+"#, with: "", options: [.regularExpression, .caseInsensitive]) ?? String(components[1]).replacingOccurrences(of: "-", with: " ").capitalized
            var name = link.trimmedText
            if components.count > 3 {
                // On the home page the card title contains the release version; its
                // adjacent infoSlide has the exact version text, including betas.
                let wrapper = row.ancestor { $0.hasClass("appRow") } ?? row
                if let parent = wrapper.parent, let index = parent.children.firstIndex(where: { $0 === wrapper }), index + 1 < parent.children.count {
                    let suffix = parent.children.dropFirst(index + 1).first(where: { $0.tag != "#text" })
                    if let info = suffix, info.hasClass("infoSlide"), let version = info.first(where: { $0.hasClass("infoSlide-value") })?.trimmedText {
                        let version = version.components(separatedBy: " for Android")[0]
                        if name.hasSuffix(" " + version) { name = String(name.dropLast(version.count + 1)) }
                        else if name.hasSuffix(" " + version + " beta") { name = String(name.dropLast(version.count + 6)) }
                    }
                }
            }
            let icon = row.first { $0.tag == "img" }?.attributes["src"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            result.append(MarketplaceApp(name: name, developer: developer, pageURL: appURL, iconURL: icon.flatMap { APKMirrorSourcePolicy.isAllowed($0) ? $0 : nil }))
            if result.count >= 40 { break }
        }
        return result
    }

    static func releaseURLs(_ html: String, baseURL: URL, appURL: URL) throws -> [URL] {
        let document = APKMirrorHTML(html)
        guard document.isValid else { throw MarketplaceError.invalidResponse }
        var result: [URL] = [], seen = Set<URL>()
        if baseURL.path.trimmingTrailingSlash.hasSuffix("-release") { result.append(baseURL); seen.insert(baseURL) }
        for heading in document.main.descendants(where: { $0.hasClass("appRowTitle") }) {
            guard let href = heading.first(where: { $0.tag == "a" })?.attributes["href"] else { continue }
            let url = try APKMirrorSourcePolicy.pageURL(href, relativeTo: baseURL)
            if url.path.hasPrefix(appURL.path.trimmingTrailingSlash + "/"), url.path.trimmingTrailingSlash.hasSuffix("-release"), seen.insert(url).inserted { result.append(url) }
        }
        guard !result.isEmpty else { throw MarketplaceError.noVariants }
        return result
    }

    static func parseVariants(_ html: String, baseURL: URL, appName: String) throws -> [APKVariant] {
        try checkPage(html)
        let document = APKMirrorHTML(html)
        guard document.isValid else { throw MarketplaceError.invalidResponse }
        var result: [APKVariant] = [], seen = Set<URL>()
        let prerelease = isPrerelease(document.root.first(where: { $0.tag == "h1" })?.trimmedText ?? "")
        for row in document.main.descendants(where: { $0.hasClass("table-row") }) {
            let cells = row.children.filter { $0.hasClass("table-cell") || $0.tag == "td" }
            guard cells.count == 4, let link = cells[0].first(where: { $0.tag == "a" && ($0.attributes["href"] ?? "").contains("android-apk-download/") }), let href = link.attributes["href"] else { continue }
            let url = try APKMirrorSourcePolicy.pageURL(href, relativeTo: baseURL)
            guard url.path.hasPrefix(baseURL.path.trimmingTrailingSlash + "/"), seen.insert(url).inserted else { continue }
            let badges = cells[0].descendants { $0.hasClass("apkm-badge") }.map(\.trimmedText)
            // An unknown format is not silently assumed to be a standalone APK.
            guard badges.contains("APK") || badges.contains("BUNDLE") else { continue }
            let version = link.trimmedText
            let architecture = cells[1].trimmedText, dpi = cells[3].trimmedText
            guard !version.isEmpty, !architecture.isEmpty, !dpi.isEmpty else { continue }
            result.append(APKVariant(appName: appName, version: version, pageURL: url, architecture: architecture, minimumSDK: minimumSDK(cells[2].trimmedText), dpi: dpi, isBundle: badges.contains("BUNDLE"), isPrerelease: prerelease || isPrerelease(version)))
        }
        return result
    }

    static func enrich(_ variant: APKVariant, html: String) throws -> APKVariant {
        try checkPage(html)
        let document = APKMirrorHTML(html)
        guard document.isValid else { throw MarketplaceError.invalidResponse }
        let specs = document.main.descendants { $0.hasClass("appspec-row") }
        let package = specs.compactMap { APKMirrorHTML.groups(#"\bPackage:\s*([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)"#, $0.trimmedText).first?.first }.first
        let sdkRow = specs.first { $0.first(where: { $0.attributes["xlink:href"] == "#apkm-icon-sdk" }) != nil }?.trimmedText ?? ""
        let sdk = APKMirrorHTML.groups(#"Min:.*?\bAPI\s+(\d+)"#, sdkRow).first?.first.flatMap(Int.init) ?? variant.minimumSDK
        let sizeRow = specs.first { $0.first(where: { $0.attributes["xlink:href"] == "#apkm-icon-filesize" }) != nil }?.trimmedText ?? ""
        let fileSize = APKMirrorHTML.groups(#"\b([0-9][0-9,]*)\s+bytes\b"#, sizeRow).first?.first.flatMap { Int64($0.replacingOccurrences(of: ",", with: "")) }
        var sha256: String?
        if let safe = document.root.first(where: { $0.attributes["id"] == "safeDownload" }) {
            // Certificate fingerprints are not APK bytes checksums.
            let text = safe.trimmedText
            if let range = text.range(of: "APK file hashes", options: .caseInsensitive) {
                sha256 = APKMirrorHTML.groups(#"SHA-256:\s*([a-f0-9]{64})\b"#, String(text[range.upperBound...])).first?.first?.lowercased()
            }
        }
        guard package != nil, document.main.first(where: { $0.hasClass("downloadButton") }) != nil else { throw MarketplaceError.invalidResponse }
        return APKVariant(appName: variant.appName, version: variant.version, pageURL: variant.pageURL, architecture: variant.architecture, minimumSDK: sdk, dpi: variant.dpi, isBundle: variant.isBundle, isPrerelease: variant.isPrerelease, packageName: package, sha256: sha256, fileSize: fileSize ?? variant.fileSize)
    }

    static func downloadLink(_ html: String, baseURL: URL) throws -> URL {
        try checkPage(html)
        let document = APKMirrorHTML(html)
        guard document.isValid else { throw MarketplaceError.invalidResponse }
        let anchor = document.main.first { $0.tag == "a" && $0.attributes["id"] == "download-link" } ?? document.main.first { $0.tag == "a" && $0.hasClass("downloadButton") }
        guard let href = anchor?.attributes["href"] else { throw MarketplaceError.unavailable("APKMirror could not prepare the download. Please try again later.") }
        let url = try APKMirrorSourcePolicy.pageURL(href, relativeTo: baseURL)
        guard url.path.hasSuffix("/download.php") || url.path.trimmingTrailingSlash.hasSuffix("android-apk-download/download") || url.path.lowercased().hasSuffix(".apk") else { throw MarketplaceError.unsafeURL }
        return url
    }

    private static func isPrerelease(_ value: String) -> Bool {
        !APKMirrorHTML.matches(#"(?i)\b(beta|alpha|nightly|canary|preview|dev)\b|\d[a-b]\d|\brc\d*\b"#, value).isEmpty
    }
    private static func sampleStandalone(_ variants: [APKVariant], limit: Int) -> [APKVariant] {
        // Use distinct metadata groups, preserving the website's order within a
        // group. Universal and density-independent files cover the most devices.
        let sorted = variants.enumerated().sorted { lhs, rhs in
            func score(_ variant: APKVariant) -> Int { (variant.architecture == "universal" ? 2 : 0) + (variant.dpi == "nodpi" ? 1 : 0) }
            let left = score(lhs.element), right = score(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        var groups = Set<String>(), result: [APKVariant] = []
        for variant in sorted {
            let key = "\(variant.architecture)/\(variant.minimumSDK.map(String.init) ?? "unknown")/\(variant.dpi)"
            if groups.insert(key).inserted { result.append(variant) }
            if result.count == limit { break }
        }
        if result.count < limit { result += sorted.filter { candidate in !result.contains(where: { $0.id == candidate.id }) }.prefix(limit - result.count) }
        return result
    }
    static func minimumSDK(_ value: String) -> Int? {
        if let number = APKMirrorHTML.groups(#"\bAPI\s*(\d+)"#, value).first?.first { return Int(number) }
        guard let version = APKMirrorHTML.groups(#"Android\s+([0-9]+(?:\.[0-9]+)*(?:L|W)?)"#, value).first?.first else { return nil }
        let versions = ["1.0":1,"1.1":2,"1.5":3,"1.6":4,"2.0":5,"2.0.1":6,"2.1":7,"2.2":8,"2.3":9,"2.3.3":10,"3.0":11,"3.1":12,"3.2":13,"4.0":14,"4.0.3":15,"4.1":16,"4.2":17,"4.3":18,"4.4":19,"4.4W":20,"5.0":21,"5.1":22,"6.0":23,"7.0":24,"7.1":25,"8.0":26,"8.1":27,"9":28,"10":29,"11":30,"12":31,"12L":32,"13":33,"14":34,"15":35,"16":36,"17":37]
        return versions[version] ?? versions[version + ".0"]
    }
}

private extension String {
    var trimmingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
