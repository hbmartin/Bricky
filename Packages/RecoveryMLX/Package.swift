// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "RecoveryMLX",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RecoveryMLX", targets: ["RecoveryMLX"])],
    dependencies: [
        // 3.31.4 predates MLXGuidedGeneration. This exact post-3.31.4 commit
        // is the first pinned integration used by Bricky; default traits are
        // disabled so MLXFoundationModels is absent from the iOS 17 graph.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "cd1ab3dd98ceb02d095490aa25e61298ea3e2f5b",
            traits: []
        ),
        // Direct dependency on the core MLX product so the runtime can bound
        // and clear the GPU buffer cache. 0.31.6 matches the version already
        // resolved transitively through mlx-swift-lm.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            from: "0.31.6"
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
