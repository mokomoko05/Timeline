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
    ],
    dependencies: [
        // 内置终端与 Markdown 语法解析；正文使用 AppKit 原生排版。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.9.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TimelineCore", dependencies: ["CSQLite"]),
        // 公式（$…$、$$…$$）用 CoreText 原生排版，不起 WebView。
        .target(name: "TimelineMath", exclude: ["LICENSE-SwiftMath.txt"], resources: [.copy("mathFonts.bundle")]),
        .executableTarget(name: "Timeline", dependencies: ["TimelineCore", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Markdown", package: "swift-markdown"), "TimelineMath"], resources: [.copy("EditorAssets")]),
        .testTarget(name: "TimelineCoreTests", dependencies: ["TimelineCore"]),
        .testTarget(name: "TimelineUITests", dependencies: ["Timeline", .product(name: "SwiftTerm", package: "SwiftTerm")])
    ]
)
