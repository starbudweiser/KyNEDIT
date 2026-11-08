// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KyNEDIT",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CBRAW", path: "Sources/CBRAW", cxxSettings: [.unsafeFlags(["-std=c++17"])], linkerSettings: [.linkedFramework("CoreFoundation")]),
        .executableTarget(name: "KyNEDIT", dependencies: ["CBRAW"], path: "Sources/KyNEDIT")
    ],
    cxxLanguageStandard: .cxx17
)
