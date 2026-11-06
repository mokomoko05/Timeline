// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Timeline",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .executable(name: "TimelineApp", targets: ["Timeline"]),
        // iOS 应用（iOS/TimelineMobile.xcodeproj）只用数据层。
        .library(name: "TimelineCore", targets: ["TimelineCore"]),
        // 公式排版（SwiftMath 的副本，见 Sources/TimelineMath/MathResources.swift），iOS 应用也用。
        .library(name: "TimelineMath", targets: ["TimelineMath"]),
        // 命令行管理内置终端（打包进 Timeline.app/Contents/MacOS/tl）。
        .executable(name: "tl", targets: ["tl"]),
    ],
    dependencies: [
        // 内置终端与 Markdown 语法解析；正文使用 AppKit 原生排版。
        // 内置副本，修了终端变窄重排时的堆越界（见 Vendor/SwiftTerm/PATCHES.md）。
        .package(path: "Vendor/SwiftTerm"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TimelineCore", dependencies: ["CSQLite"]),
        // 公式（$…$、$$…$$）用 CoreText 原生排版，不起 WebView。
        .target(name: "TimelineMath", exclude: ["LICENSE-SwiftMath.txt"], resources: [.copy("mathFonts.bundle")]),
        // 终端控制协议：应用和 tl 共用。
        .target(name: "TimelineControl"),
        .executableTarget(name: "tl", dependencies: ["TimelineControl"]),
        .executableTarget(name: "Timeline", dependencies: ["TimelineCore", "TimelineControl", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Markdown", package: "swift-markdown"), "TimelineMath"], resources: [.copy("EditorAssets")]),
        .testTarget(name: "TimelineCoreTests", dependencies: ["TimelineCore"]),
        .testTarget(name: "TimelineUITests", dependencies: ["Timeline", "TimelineControl", .product(name: "SwiftTerm", package: "SwiftTerm")])
    ]
)
