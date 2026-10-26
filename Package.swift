// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "fp-swift-service",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: [
        .library(name: "FPService", targets: ["FPService"]),
        .library(name: "ProcessSignals", targets: ["ProcessSignals"]),
        .executable(name: "Example", targets: ["Example"]),
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
        // Process signals as an AsyncStream, on Dispatch signal sources. No
        // package dependencies.
        .target(name: "ProcessSignals"),
        // The README's example, as a runnable CLI (the library → CLI rule).
        .executableTarget(
            name: "Example",
            dependencies: [
                "FPService",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FP", package: "fp-swift"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
            ]
        ),
        .testTarget(
            name: "FPServiceTests",
            dependencies: [
                "FPService",
                .product(name: "FP", package: "fp-swift"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
            ]
        ),
        .testTarget(
            name: "ProcessSignalsTests",
            dependencies: ["ProcessSignals"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
