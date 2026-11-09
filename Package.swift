// swift-tools-version:5.10
import PackageDescription

// PlaybackCore is pure Swift (timecode math, sheet import, file matching, LTC, validation) and
// builds and tests anywhere, including Linux. The app target is SwiftUI and AVFoundation, so it
// only exists on macOS.

var products: [Product] = [
    .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
]
var targets: [Target] = [
    .target(name: "PlaybackCore"),
    .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"]),
]

#if os(macOS)
products.append(.executable(name: "VividPlayback", targets: ["VividPlayback"]))
targets.append(
    .executableTarget(
        name: "VividPlayback",
        dependencies: ["PlaybackCore"],
        exclude: ["Resources"]
    )
)
#endif

let package = Package(
    name: "VividPlayback",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
