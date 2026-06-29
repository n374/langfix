import SwiftUI
import AppKit

@main
struct LangFixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("LangFix", systemImage: "checkmark.seal") {
            Button("检查剪贴板文本") { AppCoordinator.shared.checkClipboard() }
            Divider()
            Button("设置…") { AppCoordinator.shared.openSettings() }
            Button("关于 LangFix") { AppCoordinator.shared.openAbout() }
            Divider()
            Button("退出 LangFix") { NSApp.terminate(nil) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻、无 Dock 图标。
        NSApp.setActivationPolicy(.accessory)
        // 注册 macOS Service provider，供 PopClip Service action 按名调用。
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }
}
