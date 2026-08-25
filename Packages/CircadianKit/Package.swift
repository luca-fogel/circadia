// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CircadianKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CircadianKit", targets: ["CircadianKit"])
    ],
    targets: [
        .target(
            name: "CircadianKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CircadianKitTests",
            dependencies: ["CircadianKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
