// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "fp-swift-service",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "FPService", targets: ["FPService"]),
        .library(name: "ProcessSignals", targets: ["ProcessSignals"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/velocityzen/fp-swift", from: "4.4.2"),
        .package(url: "https://github.com/velocityzen/fp-swift-bracket", from: "2.1.0"),
        // Property-based tests. Test targets only, so the libraries' users
        // never fetch it.
        .package(url: "https://github.com/velocityzen/hegel-swift", .upToNextMinor(from: "0.51.8")),
    ],
    targets: [
        // The core: FPBracket (which brings FP) and ProcessSignals. No Foundation.
        .target(
            name: "FPService",
            dependencies: [
                "ProcessSignals",
                .product(name: "FPBracket", package: "fp-swift-bracket"),
            ],
            swiftSettings: callerIsolation
        ),
        .target(name: "ProcessSignals", swiftSettings: callerIsolation),
        .executableTarget(
            name: "Example",
            dependencies: [
                "FPService",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
            ]
        ),
        // A service only stage 3 can stop, as a real process: the tests that
        // end a process launch and signal it. Also runs a service with no
        // file descriptor left, in a process of its own.
        .executableTarget(
            name: "ServiceFixture",
            dependencies: [
                "FPService",
                "ProcessSignals",
                .product(name: "FPBracket", package: "fp-swift-bracket"),
            ],
            path: "Tests/ServiceFixture"
        ),
        .target(
            name: "ServiceTestSupport",
            dependencies: [
                "ProcessSignals",
                .product(name: "FP", package: "fp-swift"),
            ],
            path: "Tests/ServiceTestSupport"
        ),
        .testTarget(
            name: "FPServiceTests",
            dependencies: [
                "FPService",
                "ProcessSignals",
                "ServiceTestSupport",
                .product(name: "FPBracket", package: "fp-swift-bracket"),
            ]
        ),
        .testTarget(
            name: "ProcessSignalsTests",
            dependencies: ["ProcessSignals", "ServiceTestSupport"]
        ),
        // Hegel's engine is built for macOS and Linux only, so on the other
        // platforms these targets are empty: every file is behind
        // `#if os(macOS) || os(Linux)`.
        .testTarget(
            name: "FPServicePropertyTests",
            dependencies: [
                "FPService",
                "ProcessSignals",
                "ServiceTestSupport",
                .product(name: "FPBracket", package: "fp-swift-bracket"),
                hegel,
            ],
            swiftSettings: callerIsolation
        ),
        .testTarget(
            name: "ProcessSignalsPropertyTests",
            dependencies: ["ProcessSignals", "ServiceTestSupport", hegel],
            swiftSettings: callerIsolation
        ),
    ],
    swiftLanguageModes: [.v6]
)

// As in fp-swift and fp-swift-bracket: async functions and closures run on
// the caller's actor, so their non-Sendable arguments can come from
// @MainActor code. The property tests too, as in hegel-swift: a test case
// is not Sendable, and stays with the property that drew it.
var callerIsolation: [SwiftSetting] { [.enableUpcomingFeature("NonisolatedNonsendingByDefault")] }

/// Hegel for the property tests, where its engine is built.
var hegel: Target.Dependency {
    .product(name: "HegelTesting", package: "hegel-swift", condition: .when(platforms: [.macOS, .linux]))
}
