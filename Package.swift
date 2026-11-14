// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LimitBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LimitBarCore"),
        .executableTarget(name: "LimitBar", dependencies: ["LimitBarCore"]),
        .testTarget(name: "LimitBarCoreTests", dependencies: ["LimitBarCore"]),
    ]
)
