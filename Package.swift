// swift-tools-version: 6.4
import PackageDescription

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
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DeadwoodCore", targets: ["DeadwoodCore"]),
        .executable(name: "deadwood", targets: ["deadwood"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git",
            revision: "0390867818c28241af4650eb4ef29af5669335a3"
        ),
        .package(
            url: "https://github.com/g-cqd/AemiJSON.git",
            revision: "75deac170071149540c436bdab47a5c6d5520a4a"
        ),
        .package(
            url: "https://github.com/g-cqd/AemiProtobuf.git",
            revision: "3da9bdee8af8a7e2c6e1d8bb8a5525160331c473"
        ),
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "678bf5543d3029456c4852cf8829f5598d49652c"
        ),
    ],
    targets: [
        .target(
            name: "DeadwoodCore",
            dependencies: [
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "CorpusScan", package: "analyzerkit"),
                .product(name: "SymbolFacts", package: "analyzerkit"),
                .product(name: "IndexStoreSupport", package: "analyzerkit", condition: .when(platforms: [.macOS])),
                .product(name: "AnalyzerConfiguration", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "SemanticEmbedding", package: "analyzerkit"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(
                    name: "IndexStoreDB",
                    package: "indexstore-db",
                    condition: .when(platforms: [.macOS])
                ),
                .product(name: "AemiProtobuf", package: "AemiProtobuf"),
                .product(name: "AemiProtobufCore", package: "AemiProtobuf"),
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
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "CorpusScan", package: "analyzerkit"),
                .product(name: "SymbolFacts", package: "analyzerkit"),
                .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "AemiProtobuf", package: "AemiProtobuf"),
                .product(name: "WordPiece", package: "analyzerkit"),
                .product(name: "SemanticEmbedding", package: "analyzerkit"),
            ],
            exclude: ["Goldens"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
