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
        // https://github.com/k2-fsa/sherpa-onnx — streaming X-ASR, offline SenseVoice/Paraformer, speaker embedding
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
                // Qwen3-ASR 1.7B on the GPU; the xcframework has no iOS simulator slice.
                .target(name: "llama", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/YuyinLocal",
            resources: [
                // Silero VAD (MIT, https://github.com/snakers4/silero-vad), as released by sherpa-onnx.
                .copy("Resources/silero_vad.onnx"),
            ]
        ),
        // https://github.com/ggml-org/llama.cpp (MIT): llama + mtmd (audio input), Metal.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11571/llama-b11571-xcframework.zip",
            checksum: "c2b150bf5ab4785cf360b246aea621b10c3cb689f3edd7513bbb2c990b504079"
        ),
        .testTarget(
            name: "YuyinLocalTests",
            dependencies: ["YuyinLocal"],
            path: "Tests/YuyinLocalTests"
        ),
    ]
)
