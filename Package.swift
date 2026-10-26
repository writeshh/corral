// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Corral",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Corral"),
        .testTarget(name: "CorralTests", dependencies: ["Corral"]),
    ]
)
