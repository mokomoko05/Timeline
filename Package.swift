// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Timeline",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .executable(name: "TimelineApp", targets: ["Timeline"]),
        // iOS 应用（iOS/TimelineMobile.xcodeproj）只用数据层。
        .library(name: "TimelineCore", targets: ["TimelineCore"]),
    ],
    dependencies: [
        // 内置终端与 Markdown 语法解析；正文使用 AppKit 原生排版。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.9.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        .target(name: "TimelineCore"),
        .executableTarget(name: "Timeline", dependencies: ["TimelineCore", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Markdown", package: "swift-markdown")], resources: [.copy("EditorAssets")]),
        .testTarget(name: "TimelineCoreTests", dependencies: ["TimelineCore"]),
        .testTarget(name: "TimelineUITests", dependencies: ["Timeline", .product(name: "SwiftTerm", package: "SwiftTerm")])
    ]
)
