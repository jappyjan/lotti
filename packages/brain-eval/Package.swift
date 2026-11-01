// swift-tools-version: 6.0
import PackageDescription

// Prompt and eval harness for Lotti's brain (spike S3; M5 builds on it).
// Model-agnostic: the runner takes any FoundationModels `LanguageModel`, so Apple's on-device
// model, Private Cloud Compute and MLX models (Gemma 4) all run through the same code.
let package = Package(
    name: "BrainEval",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BrainEval", targets: ["BrainEval"]),
    ],
    targets: [
        .target(name: "BrainEval", resources: [.copy("Fixtures")]),
        .testTarget(name: "BrainEvalTests", dependencies: ["BrainEval"]),
    ]
)
