// swift-tools-version: 6.0
import PackageDescription
import Foundation

// SDK RED (vendor/R3DSDK, hors dépôt : la licence interdit de redistribuer les en-têtes) : lié seulement s'il est présent.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let redLib = root + "/vendor/R3DSDK/Lib/mac64/libR3DSDK-libcpp.a"
let hasRed = FileManager.default.fileExists(atPath: redLib)

let package = Package(
    name: "KyNEDIT",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CBRAW", path: "Sources/CBRAW", cxxSettings: [.unsafeFlags(["-std=c++17"])], linkerSettings: [.linkedFramework("CoreFoundation")]),
        .target(name: "CRED", path: "Sources/CRED",
                cxxSettings: [.unsafeFlags(["-std=c++17", "-fobjc-arc", "-I", root + "/vendor/R3DSDK/Include"])],
                linkerSettings: hasRed ? [.unsafeFlags([redLib]), .linkedFramework("Metal"), .linkedFramework("Foundation")] : []),
        .executableTarget(name: "KyNEDIT", dependencies: ["CBRAW", "CRED"], path: "Sources/KyNEDIT")
    ],
    cxxLanguageStandard: .cxx17
)
