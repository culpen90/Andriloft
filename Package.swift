// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Andriloft",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Andriloft", targets: ["Andriloft"]),
        .executable(name: "andriloft-check", targets: ["AndriloftCheck"])
    ],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib"),
        .target(name: "AndriloftCore", dependencies: ["CZlib"]),
        .target(name: "AndriloftRuntime", dependencies: ["AndriloftCore"]),
        .executableTarget(name: "Andriloft", dependencies: ["AndriloftRuntime"]),
        .executableTarget(name: "AndriloftCheck", dependencies: ["AndriloftRuntime"]),
        .testTarget(name: "AndriloftTests", dependencies: ["AndriloftRuntime"], resources: [.copy("Fixtures")])
    ]
)
