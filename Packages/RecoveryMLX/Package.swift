// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "RecoveryMLX",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RecoveryMLX", targets: ["RecoveryMLX"])],
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
        )
    ]
)
