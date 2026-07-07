// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "HermesBar",
            path: "Sources/HermesBar"
        )
    ]
)
