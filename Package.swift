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
        // analyzerkit's revision, written exactly as analyzerkit writes it: SwiftPM refuses one package required in
        // two spellings, even a revision and a branch naming the same commit (analyzerkit ADR-0025).
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git", revision: "0390867818c28241af4650eb4ef29af5669335a3"),
        // The published JSON package uses Aemi's kernel and runtime products.
        // The repository identity remains ADJSON; select its AemiJSON product.
        // Only the internal facts cache uses this codec; report byte formats stay stable.
        .package(
            url: "https://github.com/g-cqd/AemiJSON.git",
            revision: "08695007cbd23d2b6dbb2181e6f9b3dcf1666f83"
        ),
        // The project model the analyzers share: entry points project files
        // and test frameworks create, code regions, generated files.
        // The facts cache's payload codec; analyzerkit's revision, written as analyzerkit writes it (ADR-0025).
        .package(
            url: "https://github.com/g-cqd/AemiProtobuf.git", revision: "4947dd13e9f591d6ae7d90780fcd4a6990a62735"),
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "1b113fcc81454bd57ebc782331af781522a6eb69"
        ),
    ],
    targets: [
        .target(
            name: "DeadwoodCore",
            dependencies: [
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "CorpusScan", package: "analyzerkit"),
                .product(name: "IndexStoreSupport", package: "analyzerkit", condition: .when(platforms: [.macOS])),
                .product(name: "AnalyzerConfiguration", package: "analyzerkit"),
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
                // The facts cache's payload coders (Cache/FactsProtobufCoding.swift); AemiJSON is the JSON path's.
                .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "AemiProtobuf", package: "AemiProtobuf"),
                .product(name: "AemiProtobufCore", package: "AemiProtobuf"),
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
                .product(name: "CorpusScan", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "DeadwoodCoreTests",
            dependencies: [
                "DeadwoodCore", .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "CorpusScan", package: "analyzerkit"),
                .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "AemiProtobuf", package: "AemiProtobuf"),
                .product(name: "WordPiece", package: "analyzerkit"),
            ],
            exclude: ["Goldens"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
