// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictationSpike",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalDictationSpike", targets: ["LocalDictationSpike"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .binaryTarget(name: "whisper", path: "Vendor/build-apple/whisper.xcframework"),
        .executableTarget(name: "LocalDictationSpike", dependencies: [
            "whisper", .product(name: "Sparkle", package: "Sparkle"),
        ]),
    ]
)
