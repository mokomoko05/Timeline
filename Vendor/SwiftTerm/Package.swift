// swift-tools-version:6.0
import PackageDescription

// SwiftTerm v1.20.0 (5d14406844143538cd8f8851d2d8a67c1fe443e5) with the patches listed in PATCHES.md.
let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v11), .tvOS(.v13), .visionOS(.v1)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            resources: [.process("Apple/Metal/Shaders.metal")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
