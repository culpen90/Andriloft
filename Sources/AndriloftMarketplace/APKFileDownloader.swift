import Foundation

public struct APKFileDownloader: APKDownloading {
    public init() {}
    public func download(from url: URL, progress: @escaping DownloadProgress) async throws -> URL {
        guard Self.isTrusted(url) else { throw MarketplaceError.unsafeURL }
        return try await APKDownloadTransfer(url: url, progress: progress).run()
    }

    public static func isTrusted(_ url: URL) -> Bool {
        APKMirrorSourcePolicy.isAllowed(url)
    }

    /// APKMirror's download endpoint currently redirects to this specific R2
    /// account. Catalog navigation and initial download sources remain APKMirror.
    static func isAllowedDownloadDestination(_ url: URL) -> Bool {
        if isTrusted(url) { return true }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              url.host?.lowercased() == "eb5e7388c3df147b74dd2379b7cf8323.r2.cloudflarestorage.com",
              url.path.hasPrefix("/downloadprod/wp-content/uploads/"),
              url.lastPathComponent.hasSuffix("_apkmirror.com.apk"),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems else { return false }
        let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, _ in "" })
        guard values["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256",
              let signature = values["X-Amz-Signature"], signature.count == 64, signature.allSatisfy({ $0.isHexDigit }),
              let expiry = values["X-Amz-Expires"].flatMap(Int.init), (1...3600).contains(expiry),
              let credentials = values["X-Amz-Credential"], !credentials.isEmpty,
              let date = values["X-Amz-Date"], date.count == 16 else { return false }
        return true
    }
}

private final class APKDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let maximumBytes: Int64 = 512 * 1024 * 1024
    private let url: URL
    private let progress: DownloadProgress
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: Error?
    private var downloaded: URL?

    init(url: URL, progress: @escaping DownloadProgress) { self.url = url; self.progress = progress }

    func run() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 600
                config.httpCookieStorage = .shared
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("Andriloft/1.0 (macOS; APKMirror download)", forHTTPHeaderField: "User-Agent")
                request.setValue("https://www.apkmirror.com/", forHTTPHeaderField: "Referer")
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                progress(0)
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = response.url, APKFileDownloader.isAllowedDownloadDestination(source),
              let target = request.url, APKFileDownloader.isAllowedDownloadDestination(target) else {
            failure = MarketplaceError.unsafeURL
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumBytes || totalBytesExpectedToWrite > Self.maximumBytes {
            failure = MarketplaceError.invalidDownload("This APK exceeds the supported download size of 512 MiB.")
            downloadTask.cancel(); return
        }
        progress(totalBytesExpectedToWrite > 0 ? min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200, let finalURL = response.url, APKFileDownloader.isAllowedDownloadDestination(finalURL) else {
            failure = MarketplaceError.unavailable("The download could not be completed. Please try again later."); return
        }
        guard response.mimeType != "text/html", response.mimeType != "application/json" else {
            failure = MarketplaceError.invalidDownload("The source returned a web page instead of an APK. Please try again later."); return
        }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= Self.maximumBytes else { throw MarketplaceError.invalidDownload("The APK download was empty or too large.") }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("andriloft-download-\(UUID().uuidString).apk")
            try FileManager.default.moveItem(at: location, to: destination)
            downloaded = destination
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancelled
        self.session = nil
        self.task = nil
        lock.unlock()
        let resultError = wasCancelled ? CancellationError() : failure ?? error
        if let resultError {
            if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
            continuation?.resume(throwing: resultError)
        } else if let downloaded { continuation?.resume(returning: downloaded) }
        else { continuation?.resume(throwing: MarketplaceError.invalidResponse) }
        session.finishTasksAndInvalidate()
    }
}
