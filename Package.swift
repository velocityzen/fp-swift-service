// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "fp-swift-service",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: [
        .library(name: "FPService", targets: ["FPService"]),
        .library(name: "ProcessSignals", targets: ["ProcessSignals"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/velocityzen/fp-swift", from: "3.3.0"),
        .package(url: "https://github.com/velocityzen/fp-swift-bracket", from: "1.3.0"),
    ],
    targets: [
        // The core: FP, FPBracket and ProcessSignals. No Foundation.
        .target(
            name: "FPService",
            dependencies: [
                "ProcessSignals",
                .product(name: "FP", package: "fp-swift"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
            ]
        ),
        .target(name: "ProcessSignals"),
        .executableTarget(
            name: "Example",
            dependencies: [
                "FPService",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FP", package: "fp-swift"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
            ]
        ),
        // A service only stage 3 can stop, as a real process: the tests that
        // end a process launch and signal it.
        .executableTarget(
            name: "ServiceFixture",
            dependencies: [
                "FPService",
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
                "ServiceTestSupport",
                .product(name: "FP", package: "fp-swift"),
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
