import AppKit
import SwiftUI

/// 全局编排：接 Service 输入 → 校验 → 弹窗 → 跑 ReviewEngine → 更新状态；并管理设置窗口。
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    private let engine = ReviewEngine()
    private var reviewController: ReviewWindowController?
    private var settingsController: SettingsWindowController?
    private var currentTask: Task<Void, Never>?

    private init() {}

    // MARK: - 入口

    func checkClipboard() {
        let s = NSPasteboard.general.string(forType: .string)?.trimmed ?? ""
        guard !s.isEmpty else { info("剪贴板没有文本"); return }
        handleSelection(s)
    }

    func handleSelection(_ rawText: String) {
        let cfg = SettingsStore.shared.config()
        guard cfg.isComplete else {
            presentConfigNeeded(cfg.missingFields)
            return
        }
        let input = rawText.trimmed
        guard !input.isEmpty else { return }
        if input.count > cfg.maxChars {
            present(error: "文本过长（\(input.count) 字符，上限 \(cfg.maxChars)）")
            return
        }
        start(input: input, cfg: cfg)
    }

    private func start(input: String, cfg: AppConfig) {
        let state = ReviewState()
        state.input = input
        state.phase = .loading
        state.onCancel = { [weak self] in
            self?.currentTask?.cancel()
            self?.reviewController?.close()
        }
        state.onClose = { [weak self] in self?.reviewController?.close() }
        state.onRetry = { [weak self] in self?.start(input: input, cfg: SettingsStore.shared.config()) }
        state.onOpenSettings = { [weak self] in self?.openSettings() }
        present(state: state)

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.engine.review(text: input, config: cfg)
                if Task.isCancelled { return }
                state.phase = .result(result)
            } catch let e as ReviewError {
                if case .cancelled = e { return }
                state.phase = .error(e.errorDescription ?? "出错了")
            } catch {
                if Task.isCancelled { return }
                state.phase = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - 窗口

    private func present(state: ReviewState) {
        reviewController?.close()
        let c = ReviewWindowController(state: state)
        reviewController = c
        c.showCentered()
    }

    private func present(error: String) {
        let state = ReviewState()
        state.phase = .error(error)
        state.onClose = { [weak self] in self?.reviewController?.close() }
        state.onOpenSettings = { [weak self] in self?.openSettings() }
        present(state: state)
    }

    func openSettings() {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.show()
    }

    func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "LangFix",
            .applicationVersion: "0.1.0",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "划词写作纠错 · PopClip 触发 · 最小改动 + 中文解释",
        ])
    }

    private func presentConfigNeeded(_ missing: [String]) {
        let alert = NSAlert()
        alert.messageText = "请先完成配置"
        alert.informativeText = "缺少：\(missing.joined(separator: "、"))。在设置里填好 OpenAI 兼容端点、API key 与模型后再试。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    private func info(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - 浮窗控制器（NSPanel + SwiftUI）

@MainActor
final class ReviewWindowController {
    private let panel: NSPanel
    private var escMonitor: Any?

    init(state: ReviewState) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "LangFix"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ReviewView(state: state))
    }

    func showCentered() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Esc 关闭
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.close()
                return nil
            }
            return event
        }
    }

    func close() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        panel.orderOut(nil)
        panel.close()
    }
}

// MARK: - 设置窗口控制器

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LangFix 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
