// swift-tools-version: 6.0
import PackageDescription

// The menu bar app. Built and bundled by build.sh; no Xcode project.
let package = Package(
    name: "Pixelvisor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pixelvisor", path: "Sources"),
        .testTarget(name: "PixelvisorTests", dependencies: ["Pixelvisor"], path: "Tests"),
    ]
)
