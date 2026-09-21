// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VOLMVoice",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "VOLMVoiceCore", path: "Sources/VOLMVoiceCore"),
        .executableTarget(
            name: "VOLMVoice",
            dependencies: ["VOLMVoiceCore"],
            path: "Sources/VOLMVoice"
        ),
        .testTarget(
            name: "VOLMVoiceCoreTests",
            dependencies: ["VOLMVoiceCore"],
            path: "Tests/VOLMVoiceCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
