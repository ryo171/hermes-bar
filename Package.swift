// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesBar",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.3.0")
    ],
    targets: [
        .executableTarget(
            name: "HermesBar",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/HermesBar"
        )
    ]
)
