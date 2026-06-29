// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LangFix",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LangFix",
            path: "Sources/LangFix",
            // 首版用 Swift 5 语言模式，先把功能跑通，避免与严格并发检查纠缠；
            // 后续可逐文件迁移到 Swift 6 strict concurrency。
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
