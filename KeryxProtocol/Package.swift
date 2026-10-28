// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeryxProtocol",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "KeryxProtocol", targets: ["KeryxProtocol"])
    ],
    targets: [
        .target(name: "KeryxProtocol"),
        .testTarget(
            name: "KeryxProtocolTests",
            dependencies: ["KeryxProtocol"]
        )
    ]
)
