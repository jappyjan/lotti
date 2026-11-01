// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LottiKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LottiKit", targets: ["LottiKit"]),
    ],
    targets: [
        .target(name: "LottiKit", dependencies: ["CLC3"]),
        // Google's liblc3, vendored: decodes the glasses' LC3 microphone stream.
        .target(name: "CLC3", exclude: ["LICENSE", "README.md"], cSettings: [.unsafeFlags(["-w"])]),
        .testTarget(name: "LottiKitTests", dependencies: ["LottiKit", "CLC3"]),
    ]
)
