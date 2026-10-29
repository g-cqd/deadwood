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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // swift-system: a safe, Sendable stderr handle. Foundation's FileHandle
        // is corelibs-only and would re-link ~51 MiB of ICU into every Linux binary.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        // IndexStoreDB backs the opt-in `--index-store` reachability mode. It
        // is linked only on macOS (its `libIndexStore.dylib` discovery is
        // macOS-only), and every consumer sits behind `#if canImport`, so the
        // Linux build never sees a symbol from it.
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git",
            revision: "64aa0b26913249c4e7c21d351a215fba02702003"
        ),
        // The published JSON package uses Aemi's kernel and runtime products.
        // The repository identity remains ADJSON; select its AemiJSON product.
        // Only the internal facts cache uses this codec; report byte formats stay stable.
        .package(
            url: "https://github.com/g-cqd/AemiJSON.git",
            revision: "5542d37ff0edb17c822b48fe69bff6e792354c57"
        ),
        // The project model the analyzers share: entry points project files
        // and test frameworks create, code regions, generated files.
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "191f42626514259ff9cbdaa097adea9d584da672"
        ),
    ],
    targets: [
        .target(
            name: "DeadwoodCore",
            dependencies: [
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "IndexStoreSupport", package: "analyzerkit", condition: .when(platforms: [.macOS])),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "WordPiece", package: "analyzerkit"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(
                    name: "IndexStoreDB",
                    package: "indexstore-db",
                    condition: .when(platforms: [.macOS])
                ),
                // Fast JSON coders for the facts cache (FactsCache.swift).
                .product(name: "AemiJSON", package: "AemiJSON"),
                // HF tokenizer for HFSemanticEmbeddingProvider.swift (macOS only).
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "deadwood",
            dependencies: [
                "DeadwoodCore",
                .product(name: "AnalyzerCLI", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "DeadwoodCoreTests",
            dependencies: [
                "DeadwoodCore", .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "WordPiece", package: "analyzerkit"),
            ],
            exclude: ["Goldens"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
