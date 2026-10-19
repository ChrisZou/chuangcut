// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChuangCutCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChuangCutCore", targets: ["ChuangCutCore"]),
        .executable(name: "chuangcut-cli", targets: ["chuangcut-cli"]),
    ],
    targets: [
        .target(name: "ChuangCutCore"), .executableTarget(name: "chuangcut-cli", dependencies: ["ChuangCutCore"]),
        .testTarget(name: "ChuangCutCoreTests", dependencies: ["ChuangCutCore"], resources: [.copy("Fixtures")]),
    ])
