// swift-tools-version: 6.0
import PackageDescription

// Trains the "Hey Lotti" sound classifier (HeyLotti.mlmodel) on macOS with Create ML.
// Uses LottiKit's LC3 codec so the training audio sounds like the G2 microphone.
let package = Package(
    name: "WakeWord",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../lotti-kit")],
    targets: [
        .executableTarget(name: "wake-word", dependencies: [.product(name: "LottiKit", package: "lotti-kit")], path: "Sources/WakeWordTool"),
    ]
)
