// swift-tools-version:6.2
import PackageDescription

// NanoClaw's voice contract without UIKit, CallKit or LiveKit, so `swift test` runs it on the Mac
// with no iOS simulator.
let package = Package(
    name: "HeyDanCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HeyDanCore", targets: ["HeyDanCore"])],
    targets: [
        .target(name: "HeyDanCore"),
        .testTarget(name: "HeyDanCoreTests", dependencies: ["HeyDanCore"]),
    ]
)
