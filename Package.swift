// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Timeline",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TimelineApp", targets: ["Timeline"]),
        // 命令行：在任何终端里查看笔记、日志，并通过运行中的应用写入。
        .executable(name: "timeline", targets: ["TimelineCLI"]),
    ],
    dependencies: [
        // 内置终端与 Markdown 语法解析；正文使用 AppKit 原生排版。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.9.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        .target(name: "TimelineCore"),
        .executableTarget(name: "Timeline", dependencies: ["TimelineCore", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Markdown", package: "swift-markdown")]),
        .target(name: "TimelineKit", dependencies: ["TimelineCore"]),
        .executableTarget(name: "TimelineCLI", dependencies: ["TimelineKit"]),
        .testTarget(name: "TimelineCoreTests", dependencies: ["TimelineCore"]),
        .testTarget(name: "TimelineKitTests", dependencies: ["TimelineKit", "TimelineCore"]),
        .testTarget(name: "TimelineUITests", dependencies: ["Timeline", "TimelineKit", .product(name: "SwiftTerm", package: "SwiftTerm")])
    ]
)
