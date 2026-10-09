import Darwin
import Foundation

/// Compatibility facts only: no host name, identifiers, paths, or personal data.
public struct MarketplaceComputerProfile: Codable, Equatable, Sendable {
    public let cpuArchitecture: String
    public let macOSVersion: String
    public let memoryGiB: Int
    public let logicalCPUCount: Int
    public let availableStorageMiB: Int64?

    public init(cpuArchitecture: String, macOSVersion: String, memoryGiB: Int,
                logicalCPUCount: Int, availableStorageMiB: Int64?) {
        self.cpuArchitecture = cpuArchitecture
        self.macOSVersion = macOSVersion
        self.memoryGiB = memoryGiB
        self.logicalCPUCount = logicalCPUCount
        self.availableStorageMiB = availableStorageMiB
    }

    public static func current(downloadDirectory: URL? = nil) -> MarketplaceComputerProfile {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        // Detect physical Apple Silicon even when an Intel build runs under Rosetta.
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let supportsArm64 = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
        let architecture = supportsArm64 ? "arm64" : "x86_64"
        #endif
        var volume = downloadDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        while !FileManager.default.fileExists(atPath: volume.path), volume.path != "/" {
            volume.deleteLastPathComponent()
        }
        let capacity = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let fallback = (try? FileManager.default.attributesOfFileSystem(forPath: volume.path)[.systemFreeSize]) as? NSNumber
        let freeBytes = capacity ?? fallback?.int64Value
        return MarketplaceComputerProfile(cpuArchitecture: architecture,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            memoryGiB: Int(info.physicalMemory / 1_073_741_824), logicalCPUCount: info.activeProcessorCount,
            availableStorageMiB: freeBytes.map { max(0, $0 / 1_048_576) })
    }
}
