// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictationSpike",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalDictationSpike", targets: ["LocalDictationSpike"])],
    targets: [
        .binaryTarget(name: "whisper", path: "Vendor/build-apple/whisper.xcframework"),
        .executableTarget(name: "LocalDictationSpike", dependencies: ["whisper"]),
    ]
)
