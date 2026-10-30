// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "fp-swift-service",
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26), .watchOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "FPService", targets: ["FPService"]),
        .library(name: "ProcessSignals", targets: ["ProcessSignals"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/velocityzen/fp-swift", from: "4.0.0"),
        .package(url: "https://github.com/velocityzen/fp-swift-bracket", from: "2.0.0"),
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
    ],
    swiftLanguageModes: [.v6]
)

// As in fp-swift and fp-swift-bracket: async functions and closures run on
// the caller's actor, so their non-Sendable arguments can come from
// @MainActor code.
var callerIsolation: [SwiftSetting] { [.enableUpcomingFeature("NonisolatedNonsendingByDefault")] }
