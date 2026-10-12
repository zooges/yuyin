// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "YuyinCloud",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "YuyinCloud", targets: ["YuyinCloud"]),
    ],
    dependencies: [
        .package(path: "../YuyinCore"),
    ],
    targets: [
        .target(
            name: "YuyinCloud",
            dependencies: ["YuyinCore"],
            path: "Sources/YuyinCloud"
        ),
        .testTarget(
            name: "YuyinCloudTests",
            dependencies: ["YuyinCloud"],
            path: "Tests/YuyinCloudTests"
        ),
    ]
)
