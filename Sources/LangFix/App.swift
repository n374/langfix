import SwiftUI
import AppKit
import Combine

@main
struct LangFixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("LangFix", systemImage: "checkmark.seal") {
            MenuBarContent()
        }
    }
}

/// 菜单栏下拉内容：观察 SettingsStore 使文案随用户语言即时切换（language-config design D4）。
private struct MenuBarContent: View {
    @ObservedObject private var settings = SettingsStore.shared
    private var lang: AppLanguage { settings.userLanguage }

    var body: some View {
        Button(L10n.t(.menuCheckClipboard, lang)) { AppCoordinator.shared.checkClipboard() }
        Divider()
        Button(L10n.t(.menuSettings, lang)) { AppCoordinator.shared.openSettings() }
        Button(L10n.t(.menuAbout, lang)) { AppCoordinator.shared.openAbout() }
        Divider()
        Button(L10n.t(.menuQuit, lang)) { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()
    private var languageCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻、无 Dock 图标。
        NSApp.setActivationPolicy(.accessory)
        // 注册 macOS Service provider，供 PopClip Service action 按名调用。
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        // 顶层菜单栏（round4 需求4/5）：LSUIElement 应用默认无主菜单，这里显式装一套，
        // 使 App 处于前台且有 key window 时可见菜单，并让 Cmd+, / Cmd+C 等标准快捷键在
        // responder 链中生效（Cmd+, 是 macOS 打开设置的通用约定）。
        NSApp.mainMenu = AppMenu.build(target: self, language: SettingsStore.shared.userLanguage)
        // 主菜单是一次性构建的 NSMenu，不随 SwiftUI 重绘 → 语言切换时显式重建（language-config design D4）。
        languageCancellable = SettingsStore.shared.$userLanguageRaw
            .removeDuplicates()
            .sink { [weak self] raw in
                guard let self, let lang = AppLanguage(rawValue: raw) else { return }
                DispatchQueue.main.async { NSApp.mainMenu = AppMenu.build(target: self, language: lang) }
            }
    }

    // 菜单自定义项动作（标准 Edit / 窗口项走 responder 链，无需在此实现）。
    @objc func openSettingsFromMenu(_ sender: Any?) { AppCoordinator.shared.openSettings() }
    @objc func openAboutFromMenu(_ sender: Any?) { AppCoordinator.shared.openAbout() }
    @objc func checkClipboardFromMenu(_ sender: Any?) { AppCoordinator.shared.checkClipboard() }
}

/// 顶层主菜单构造（纯构造、可单测）：App / Edit / Window 三个子菜单，文案随用户语言。
/// - App 菜单含「设置…」(Cmd+,)、「关于」、「检查剪贴板」、「退出」(Cmd+Q)。
/// - Edit 菜单提供撤销/剪切/复制/粘贴/全选标准项，走 first responder，使弹窗与设置里的
///   文本框支持通用编辑快捷键。
/// - Window 菜单提供最小化/关闭。
enum AppMenu {
    @MainActor
    static func build(target: AnyObject, language lang: AppLanguage) -> NSMenu {
        let main = NSMenu()

        // MARK: App 菜单
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(withTitle: L10n.t(.menuAbout, lang),
                        action: #selector(AppDelegate.openAboutFromMenu(_:)), keyEquivalent: "")
            .target = target
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: L10n.t(.menuSettings, lang),
                                       action: #selector(AppDelegate.openSettingsFromMenu(_:)),
                                       keyEquivalent: ",")   // Cmd+, —— macOS 设置通用快捷键
        settings.keyEquivalentModifierMask = [.command]
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t(.menuCheckClipboard, lang),
                        action: #selector(AppDelegate.checkClipboardFromMenu(_:)), keyEquivalent: "")
            .target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t(.menuHideApp, lang),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quit = appMenu.addItem(withTitle: L10n.t(.menuQuit, lang),
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]

        // MARK: Edit 菜单（标准编辑项，走 first responder）
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: L10n.t(.menuEdit, lang))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.t(.menuUndo, lang), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.t(.menuRedo, lang), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.t(.menuCut, lang), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t(.menuCopy, lang), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t(.menuPaste, lang), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t(.menuSelectAll, lang), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // MARK: Window 菜单
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: L10n.t(.menuWindow, lang))
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.t(.menuMinimize, lang),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.t(.menuClose, lang),
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        return main
    }
}
