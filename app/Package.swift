// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cue9",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cue9", targets: ["Cue9App"]),
    ],
    targets: [
        .target(
            name: "Cue9Preview",
            path: "Sources/Cue9Preview",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Cue9App",
            dependencies: ["Cue9Preview"],
            path: "Sources/Cue9App",
            resources: [.process("Resources")]
        ),
    ]
)
