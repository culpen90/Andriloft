// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Andriloft",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Andriloft", targets: ["Andriloft"]),
        .executable(name: "andriloft-check", targets: ["AndriloftCheck"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib"),
        .target(name: "AndriloftCore", dependencies: ["CZlib"]),
        .target(name: "AndriloftRuntime", dependencies: ["AndriloftCore"]),
        .target(name: "AndriloftUpdates", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(
            name: "Andriloft",
            dependencies: ["AndriloftRuntime", "AndriloftUpdates"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "AndriloftCheck", dependencies: ["AndriloftRuntime"]),
        .testTarget(name: "AndriloftTests", dependencies: ["AndriloftRuntime"], resources: [.copy("Fixtures")]),
        .testTarget(name: "AndriloftUpdatesTests", dependencies: ["AndriloftUpdates"])
    ]
)
