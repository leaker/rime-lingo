// swift-tools-version: 6.2
import PackageDescription

let strictSwift: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault")
]

let package = Package(
    name: "RimeLingoKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RimeKit", targets: ["RimeKit"]),
        .library(name: "RimeLingoCore", targets: ["RimeLingoCore"]),
        .library(name: "RimeLingoPanel", targets: ["RimeLingoPanel"]),
        .library(name: "RimeLingoAI", targets: ["RimeLingoAI"]),
        .executable(name: "rimelingo", targets: ["rimelingo"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0")
    ],
    targets: [
        // librime 1.17 prebuilt, assembled by scripts/fetch-librime.sh.
        .binaryTarget(name: "CRime", path: "Frameworks/CRime.xcframework"),

        // Thin, typed Swift wrapper over the librime C API.
        .target(name: "RimeKit", dependencies: ["CRime"], swiftSettings: strictSwift),

        // Configuration model, patch writer, importer, dictionary packages.
        .target(
            name: "RimeLingoCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            resources: [.copy("Resources/catalog.json"), .copy("Resources/registry.json")],
            swiftSettings: strictSwift
        ),

        // AppKit candidate panel shared by the input method and the settings preview.
        .target(name: "RimeLingoPanel", dependencies: ["RimeLingoCore"], swiftSettings: strictSwift),

        // Optional AI assistant. Never touches composition buffers or user dictionaries.
        .target(name: "RimeLingoAI", dependencies: ["RimeLingoCore"], swiftSettings: strictSwift),

        .executableTarget(
            name: "rimelingo",
            dependencies: [
                "RimeKit", "RimeLingoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: strictSwift
        ),

        .testTarget(name: "RimeKitTests", dependencies: ["RimeKit"]),
        .testTarget(name: "RimeLingoCoreTests", dependencies: ["RimeLingoCore", "RimeKit"], exclude: ["Fixtures"]),
        .testTarget(name: "RimeLingoPanelTests", dependencies: ["RimeLingoPanel"]),
        .testTarget(name: "RimeLingoAITests", dependencies: ["RimeLingoAI"])
    ]
)
