// swift-tools-version: 6.4
import PackageDescription

// Strict-by-default: warnings are errors; upcoming features are on so the code
// is already valid under the next language mode's semantics, and strict memory
// safety keeps the unsafe surface at zero. Swift 6 language mode (below)
// already includes complete strict concurrency.
let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "deadwood",
    // macOS 15+: the parallel BFS visited-set and the regex cache sit on the
    // stdlib Synchronization module (Atomic/Mutex), which landed in 15.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DeadwoodCore", targets: ["DeadwoodCore"]),
        .executable(name: "deadwood", targets: ["deadwood"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // IndexStoreDB backs the opt-in `--index-store` reachability mode. It
        // is linked only on macOS (its `libIndexStore.dylib` discovery is
        // macOS-only), and every consumer sits behind `#if canImport`, so the
        // Linux build never sees a symbol from it.
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git",
            revision: "cb3b960568f18a3cc018923f5824323b5c4edd0b"
        ),
    ],
    targets: [
        .target(
            name: "DeadwoodCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(
                    name: "IndexStoreDB",
                    package: "indexstore-db",
                    condition: .when(platforms: [.macOS])
                ),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "deadwood",
            dependencies: [
                "DeadwoodCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "DeadwoodCoreTests",
            dependencies: ["DeadwoodCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
