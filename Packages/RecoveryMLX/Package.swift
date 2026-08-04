// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "RecoveryMLX",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecoveryMLX", targets: ["RecoveryMLX"]),
        .library(name: "RecoveryEvidenceKit", targets: ["RecoveryEvidenceKit"])
    ],
    dependencies: [
        // This exact commit includes MLXGuidedGeneration and trait-gated
        // FoundationModels integration without requiring the post-0.31.4
        // maskFill API. Default traits are disabled so MLXFoundationModels is
        // absent from the iOS 17 graph and Xcode 16.4 remains supported.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "d2424294a6c3bbd0de37a0761d80efc05e6813dd",
            traits: []
        ),
        // Direct dependency on the core MLX product so the runtime can bound
        // and clear the GPU buffer cache. 0.31.4 is the newest release in the
        // LM package's accepted range whose manifest remains compatible with
        // the Swift 6.1 toolchain shipped by the required Xcode 16.4.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            revision: "0d7842981ff6156c05aebedf23459a780b22c624"
        ),
        // CLI-only; the app never links it.
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "RecoveryMLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        // The evidence interchange contract and the authoritative board
        // layout, shared by the iOS app and the bricky-harness CLI. System
        // frameworks only (CoreGraphics/CoreText/ImageIO) so it stays cheap
        // to link everywhere.
        .target(name: "RecoveryEvidenceKit"),
        .executableTarget(
            name: "bricky-harness",
            dependencies: [
                "RecoveryMLX",
                "RecoveryEvidenceKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "RecoveryMLXTests",
            dependencies: ["RecoveryMLX"]
        ),
        .testTarget(
            name: "RecoveryEvidenceKitTests",
            dependencies: ["RecoveryEvidenceKit"]
        )
    ]
)
