// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "YuyinCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "YuyinCore", targets: ["YuyinCore"]),
    ],
    targets: [
        .target(
            name: "YuyinCore",
            path: "Sources/YuyinCore"
        ),
        .testTarget(
            name: "YuyinCoreTests",
            dependencies: ["YuyinCore"],
            path: "Tests/YuyinCoreTests"
        ),
    ]
)
