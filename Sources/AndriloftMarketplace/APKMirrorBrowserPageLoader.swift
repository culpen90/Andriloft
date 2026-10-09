import Foundation
import WebKit

/// Offscreen native navigation retains the site's own cookies between catalog
/// requests. No site controls, challenge buttons, or consent forms are clicked.
public actor APKMirrorBrowserPageLoader: APKMirrorPageLoading {
    private var renderer: APKMirrorWebPageRenderer?
    public init() {}
    public func load(_ url: URL) async throws -> APKMirrorPage {
        guard APKMirrorSourcePolicy.isAllowed(url) else { throw MarketplaceError.unsafeURL }
        if renderer == nil { renderer = await APKMirrorWebPageRenderer() }
        return try await renderer!.load(url)
    }
}

@MainActor private final class APKMirrorWebPageRenderer: NSObject, WKNavigationDelegate {
    private struct Request {
        let id: UUID
        let url: URL
        let continuation: CheckedContinuation<APKMirrorPage, Error>
    }
    private let webView: WKWebView
    private var queue: [Request] = []
    private var active: Request?
    private var timeout: Task<Void, Never>?
    private var navigation: WKNavigation?
    private var rulesReady: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // Rendering the public page need not send requests to advertising and
        // tracking providers. APKMirror's own assets and CDN remain first party.
        rulesReady = Task { [weak self] in
            let rules = #"[{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block"}}]"#
            if let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "AndriloftMarketplaceFirstParty", encodedContentRuleList: rules) {
                self?.webView.configuration.userContentController.add(list)
            }
        }
    }

    func load(_ url: URL) async throws -> APKMirrorPage {
        let id = UUID()
        await rulesReady?.value
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Request(id: id, url: url, continuation: continuation))
                beginNext()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } })
    }

    private func beginNext() {
        guard active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        active = request
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        navigation = webView.load(urlRequest)
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, self.active?.id == request.id else { return }
            self.finish(.failure(MarketplaceError.unavailable("APKMirror took too long to respond. Please try again later.")))
        }
    }

    private func cancel(_ id: UUID) {
        if active?.id == id { finish(.failure(CancellationError())) }
        else if let index = queue.firstIndex(where: { $0.id == id }) { queue.remove(at: index).continuation.resume(throwing: CancellationError()) }
    }

    private func finish(_ result: Result<APKMirrorPage, Error>) {
        guard let request = active else { return }
        active = nil; timeout?.cancel(); timeout = nil; navigation = nil
        webView.stopLoading()
        request.continuation.resume(with: result)
        beginNext()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, APKMirrorSourcePolicy.isAllowed(url), navigationAction.targetFrame != nil else {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame == true { finish(.failure(MarketplaceError.unsafeURL)) }
            return
        }
        // Do not let the landing page's automatic file navigation initiate an
        // unmanaged download. The checked URL is handed to our file downloader.
        if url.path.hasSuffix("/download.php") || url.path.lowercased().hasSuffix(".apk") { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url, APKMirrorSourcePolicy.isAllowed(url) else {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame { finish(.failure(MarketplaceError.unsafeURL)) }
            return
        }
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        if let response = navigationResponse.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            decisionHandler(.cancel)
            let message = [403, 429, 503].contains(response.statusCode) ? "APKMirror is temporarily blocking this request. Please try again later." : "APKMirror could not load this page. Please try again later."
            finish(.failure(MarketplaceError.unavailable(message))); return
        }
        guard navigationResponse.response.mimeType?.contains("html") == true else { decisionHandler(.cancel); finish(.failure(MarketplaceError.invalidResponse)); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, let request = active else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = webView.url, APKMirrorSourcePolicy.isAllowed(url) else { throw MarketplaceError.unsafeURL }
                let value = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
                guard let html = value as? String, html.utf8.count <= 8 * 1024 * 1024 else { throw MarketplaceError.invalidResponse }
                try APKMirrorClient.checkPage(html)
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                for cookie in cookies where cookie.domain == "apkmirror.com" || cookie.domain == ".apkmirror.com" || cookie.domain.hasSuffix(".apkmirror.com") { HTTPCookieStorage.shared.setCookie(cookie) }
                guard self.active?.id == request.id else { return }
                self.finish(.success(APKMirrorPage(html: html, url: url)))
            } catch {
                guard self.active?.id == request.id else { return }
                self.finish(.failure(Self.ordinaryError(error)))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(.failure(Self.ordinaryError(error))) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(.failure(Self.ordinaryError(error))) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(MarketplaceError.invalidResponse)) }
    private static func ordinaryError(_ error: Error) -> Error {
        if error is MarketplaceError || error is CancellationError { return error }
        return MarketplaceError.unavailable("APKMirror could not load this page. Please check your connection and try again.")
    }
}
