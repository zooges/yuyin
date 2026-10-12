// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "YuyinLocal",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "YuyinLocal", targets: ["YuyinLocal"]),
    ],
    dependencies: [
        .package(path: "../YuyinCore"),
        // https://github.com/k2-fsa/sherpa-onnx — streaming Zipformer, offline SenseVoice/Paraformer/FireRed, speaker models
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git", from: "1.13.8"),
        // https://github.com/FluidInference/FluidAudio — CoreML SenseVoice on the Neural Engine
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.0"),
    ],
    targets: [
        .target(
            name: "YuyinBZip2",
            path: "Sources/YuyinBZip2",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("bz2"),
            ]
        ),
        .target(
            name: "YuyinLocal",
            dependencies: [
                "YuyinCore",
                "YuyinBZip2",
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/YuyinLocal"
        ),
        .testTarget(
            name: "YuyinLocalTests",
            dependencies: ["YuyinLocal"],
            path: "Tests/YuyinLocalTests"
        ),
    ]
)
