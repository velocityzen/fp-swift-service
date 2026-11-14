// swift-tools-version: 6.4

import PackageDescription

// Same isolation semantics as the FPService target.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

// A separate package so the library itself never depends on
// the benchmark package: run `swift package benchmark` from this directory.
let package = Package(
    name: "fp-swift-service-benchmarks",
    // Matches the library's minimum. Benchmarks run on macOS only.
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(name: "fp-swift-service", path: ".."),
        .package(url: "https://github.com/velocityzen/fp-swift-bracket", from: "2.1.0"),
        .package(
            url: "https://github.com/ordo-one/benchmark",
            .upToNextMajor(from: "1.38.1")
        ),
    ],
    targets: [
        .target(
            name: "BenchmarkSupport",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark")
            ],
            swiftSettings: swiftSettings
        )
    ],
    swiftLanguageModes: [.v6]
)

// Each suite is its own executable under Benchmarks/, which is where the
// benchmark plugin discovers them.
for suite in ["ServiceBenchmarks", "ShutdownBenchmarks", "SignalBenchmarks"] {
    package.targets.append(
        .executableTarget(
            name: suite,
            dependencies: [
                "BenchmarkSupport",
                .product(name: "FPService", package: "fp-swift-service"),
                .product(name: "ProcessSignals", package: "fp-swift-service"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/\(suite)",
            swiftSettings: swiftSettings,
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark")
            ]
        )
    )
}
