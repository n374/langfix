// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LangFix",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LangFix",
            path: "Sources/LangFix"
            // 默认 Swift 6 语言模式（strict concurrency）。
        ),
        .testTarget(
            name: "LangFixTests",
            dependencies: ["LangFix"],
            path: "Tests/LangFixTests",
            // 测试 target 暂留 Swift 5：mock server 用 NWListener @Sendable 闭包捕获 self，
            // 迁移成本高且与产品代码正交；产品代码已是 Swift 6。
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
