// swift-tools-version: 6.1
import PackageDescription

// Isolated, local-only benchmark package (modeled on arcleak/Benchmarks): a
// harness or toolchain incompatibility here can never block the main build,
// and CI does not run it. Baselines are committed for before/after tables.
let package = Package(
    name: "benchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.27.0"),
    ],
    targets: [
        .executableTarget(
            name: "DeadwoodBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "DeadwoodCore", package: "deadwood"),
            ],
            path: "Benchmarks/DeadwoodBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
        .testTarget(
            name: "BenchmarksSmokeTests",
            dependencies: [.product(name: "DeadwoodCore", package: "deadwood")]
        ),
    ]
)
