// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KyNEDIT",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KyNEDIT", path: "Sources/KyNEDIT")
    ]
)
