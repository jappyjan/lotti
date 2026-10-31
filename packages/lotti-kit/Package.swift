// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LottiKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LottiKit", targets: ["LottiKit"]),
    ],
    targets: [
        .target(name: "LottiKit"),
        .testTarget(name: "LottiKitTests", dependencies: ["LottiKit"]),
    ]
)
