import Foundation

public struct MarketplaceApp: Identifiable, Codable, Equatable, Sendable {
    public var id: String { pageURL.absoluteString }
    public let name: String
    public let developer: String
    public let pageURL: URL
    public let iconURL: URL?
    public init(name: String, developer: String, pageURL: URL, iconURL: URL? = nil) {
        self.name = name; self.developer = developer; self.pageURL = pageURL; self.iconURL = iconURL
    }
}

public struct APKVariant: Identifiable, Codable, Equatable, Sendable {
    public var id: String { pageURL.absoluteString }
    public let appName: String
    public let version: String
    public let pageURL: URL
    public let architecture: String
    public let minimumSDK: Int?
    public let dpi: String
    public let isBundle: Bool
    public let isPrerelease: Bool
    public let packageName: String?
    public let sha256: String?
    public let fileSize: Int64?
    public init(appName: String, version: String, pageURL: URL, architecture: String = "universal", minimumSDK: Int? = nil, dpi: String = "nodpi", isBundle: Bool = false, isPrerelease: Bool = false, packageName: String? = nil, sha256: String? = nil, fileSize: Int64? = nil) {
        self.appName = appName; self.version = version; self.pageURL = pageURL; self.architecture = architecture; self.minimumSDK = minimumSDK; self.dpi = dpi; self.isBundle = isBundle; self.isPrerelease = isPrerelease; self.packageName = packageName; self.sha256 = sha256; self.fileSize = fileSize
    }
}

public protocol MarketplaceCatalog: Sendable {
    func apps(query: String) async throws -> [MarketplaceApp]
    func variants(for app: MarketplaceApp) async throws -> [APKVariant]
    func downloadURL(for variant: APKVariant) async throws -> URL
}

public protocol VariantSelecting: Sendable {
    func select(from variants: [APKVariant]) async throws -> APKVariant
}

public enum MarketplaceError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case invalidResponse
    case noVariants
    case unsafeURL
    case invalidSelection
    case invalidDownload(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .invalidResponse: return "The marketplace could not load this page. Please try again."
        case .noVariants: return "No standalone APK is available for this app."
        case .unsafeURL: return "The download source could not be verified."
        case .invalidSelection: return "A download could not be selected. Please try again."
        case .invalidDownload(let message): return message
        }
    }
}
