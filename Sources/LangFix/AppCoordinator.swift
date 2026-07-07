import AppKit
import Combine
import SwiftUI

/// 全局编排：接 Service 输入 → 校验 → 弹窗 → 跑 ReviewEngine → 更新状态；并管理设置窗口。
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    private let engine = ReviewEngine()
    private var reviewController: ReviewWindowController?
    private var settingsController: SettingsWindowController?
    private var currentTask: Task<Void, Never>?
    /// 每次 start() 自增的代次：preview 回调只在「当前代且未取消」时应用，杜绝旧任务污染/取消后更新已关窗。
    private var generation = 0

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
        // 新触发先汇聚关闭上一代弹窗 + 取消上一代 Task，避免旧请求泄漏（design.md §2.4）。
        closeReviewAndCancel()

        let state = ReviewState()
        state.input = input
        state.phase = .loading
        // 关闭语义统一：onCancel / onClose 都汇聚到唯一幂等 cancel 路径（修复现状 onClose 不 cancel 的正确性 bug）。
        Self.wireCloseSemantics(state: state) { [weak self] in self?.closeReviewAndCancel() }
        // 「停止」语义：停止底层请求但保留已生成内容、窗口不关闭（冻结为 .stopped）。
        // 与 onCancel/onClose 的差别是不销毁窗口——用户明确要求「只显示已有内容」。
        state.onStop = { [weak self, weak state] in
            guard let self, let state else { return }
            switch Self.stopOutcome(for: state.phase) {
            case .close:
                // 尚无内容可保留（如 loading）→ 退化为直接关闭。
                self.closeReviewAndCancel()
            case .freeze(let preview):
                self.currentTask?.cancel()
                self.currentTask = nil
                self.generation += 1             // 让在途 preview 回调（带旧 generation）失效，不再覆盖 stopped
                state.phase = .stopped(preview)
            }
        }
        state.onRetry = { [weak self] in self?.start(input: input, cfg: SettingsStore.shared.config()) }
        state.onOpenSettings = { [weak self] in self?.openSettings() }
        present(state: state)

        generation += 1
        let myGen = generation
        currentTask = Task { [weak self, weak state] in
            guard let self, let state else { return }

            // preview 回调：@MainActor 顺序 await，带代次/取消屏障 + 单调前缀守卫（design §2.7）。
            let onPreview: @MainActor @Sendable (StreamingPreview) async -> Void = { [weak self, weak state] preview in
                guard let self, let state else { return }
                guard self.generation == myGen, !Task.isCancelled else { return }   // 仅当前代且未取消才应用
                self.applyPreview(preview, to: state)
            }

            do {
                let result: ReviewResult
                if cfg.streamingEnabled {
                    result = try await self.engine.reviewStreaming(text: input, config: cfg, onPreview: onPreview)
                } else {
                    result = try await self.engine.review(text: input, config: cfg)
                }
                if Task.isCancelled || self.generation != myGen { return }
                state.phase = .result(result)
            } catch let e as ReviewError {
                if case .cancelled = e { return }
                if self.generation != myGen { return }
                state.phase = .error(e.errorDescription ?? "出错了")
            } catch {
                if Task.isCancelled || self.generation != myGen { return }
                state.phase = .error(error.localizedDescription)
            }
        }
    }

    /// 应用一帧 preview，含单调前缀守卫：streaming 接收态下若新 corrected 比已显示更短则不回退覆盖。
    private func applyPreview(_ preview: StreamingPreview, to state: ReviewState) {
        if case .streaming(let cur) = state.phase,
           preview.stage == .receiving,
           preview.corrected.count < cur.corrected.count {
            return
        }
        state.phase = .streaming(preview)
    }

    // MARK: - 关闭语义（唯一幂等 cancel 路径，design.md §2.4 / 决策 D4）

    /// 关闭弹窗并取消底层 Task。幂等：重复调用安全（cancel 已取消的 Task 无副作用）。
    /// **正确性核心**：这是关闭的唯一出口——销毁两 panel + cancel Task + 让在途 preview 回调失效。
    private func closeReviewAndCancel() {
        currentTask?.cancel()
        currentTask = nil
        generation += 1                 // 让在途 preview 回调（带旧 generation）失效
        reviewController?.close()        // 两 panel orderOut+close、清 delegate、移除 esc monitor
        reviewController = nil
        syncActivationPolicy()           // 弹窗关闭后若无其它窗口则回 .accessory（收起主菜单栏与 Dock 图标）
    }

    /// 「停止」决策（纯函数，可单测）：流式态冻结已生成内容为部分结果；其余态直接关闭。
    enum StopOutcome { case freeze(StreamingPreview); case close }
    static func stopOutcome(for phase: ReviewState.Phase) -> StopOutcome {
        if case .streaming(let preview) = phase { return .freeze(preview) }
        return .close
    }

    /// 把 ReviewState 的关闭/取消回调统一汇聚到单一 cancel 闭包。
    /// 抽成静态方法便于单测「onClose 与 onCancel 都触发 cancel」这一正确性回归（design.md §5 最高优先级）。
    static func wireCloseSemantics(state: ReviewState, closeAndCancel: @escaping () -> Void) {
        state.onCancel = closeAndCancel
        state.onClose = closeAndCancel
    }

    // MARK: - 窗口

    private func present(state: ReviewState) {
        // behavior 在开窗时捕获；设置变更对已打开窗口下次生效，避免运行期改 level 抖动。
        let c = ReviewWindowController(state: state, behavior: SettingsStore.shared.windowBehaviorMode)
        // 关闭按钮 / 标题栏关闭 → 汇聚到同一 cancel 路径。
        c.onRequestClose = { [weak self] in self?.closeReviewAndCancel() }
        // 展开/折叠切换 → 同步 activation policy（展开时显示顶部主菜单栏，折叠回胶囊则收起）。
        c.onPresentationChange = { [weak self] in self?.syncActivationPolicy() }
        reviewController = c
        c.showCentered()
        syncActivationPolicy()
    }

    /// 让 macOS **顶部主菜单栏可见**（round6 需求3）：LSUIElement(`.accessory`) 应用**不显示**主菜单栏，
    /// 故在有可交互窗口（展开的弹窗 / 设置窗）时切 `.regular`（显示 Apple/App/文件/视图/帮助 菜单栏，
    /// 代价是此时临时出现 Dock 图标），窗口都关闭/折叠后回 `.accessory`（菜单栏应用"无 Dock 图标"常态）。
    func syncActivationPolicy() {
        let wantRegular = Self.wantsRegularPolicy(
            reviewExpanded: reviewController?.isExpandedVisible ?? false,
            settingsVisible: settingsController?.isVisible ?? false)
        let target: NSApplication.ActivationPolicy = wantRegular ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// 是否应切到 `.regular`（显示顶部主菜单栏 + 临时 Dock 图标）：任一可交互窗口可见即是。纯函数、可单测。
    static func wantsRegularPolicy(reviewExpanded: Bool, settingsVisible: Bool) -> Bool {
        reviewExpanded || settingsVisible
    }

    private func present(error: String) {
        closeReviewAndCancel()
        let state = ReviewState()
        state.phase = .error(error)
        Self.wireCloseSemantics(state: state) { [weak self] in self?.closeReviewAndCancel() }
        state.onOpenSettings = { [weak self] in self?.openSettings() }
        present(state: state)
    }

    func openSettings() {
        if settingsController == nil { settingsController = SettingsWindowController() }
        // 设置窗关闭 → 重新评估 activation policy（可能收起主菜单栏/Dock 图标）。
        settingsController?.onClose = { [weak self] in self?.syncActivationPolicy() }
        settingsController?.show()
        syncActivationPolicy()
    }

    func openAbout() {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "1"
        let sha = (info?["LangFixBuildSHA"] as? String) ?? "dev"
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "LangFix",
            .applicationVersion: "\(version) (\(build), \(sha))",
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

// MARK: - 浮窗控制器（双 NSPanel + SwiftUI，三态窗体）

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 弹窗外壳控制器：展开 panel + 折叠胶囊 panel 共享同一 `ReviewState`（design.md §2.2 决策 D1）。
/// - 窗口态由纯状态机 `ReviewWindowMode.reduce` 驱动（失焦/Esc→折叠、点击胶囊→展开、关闭→销毁+cancel）。
/// - 尺寸由 `ReviewView` 上报的内容自然尺寸经 `ReviewWindowSizing` clamp + runloop 合并驱动。
@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {
    /// 跟随鼠标定位：窗口与鼠标之间的呼吸间距（水平）。
    private static let followMouseGap: CGFloat = 24
    /// 竖直定位：以「窗口最大化时上下居中、再稍偏上」为目标锚定顶边——
    /// 顶边距屏顶 = 屏高 × 该比例。取 0.12 使满高窗（≈屏高 70%）上间距 12%、下间距 18%，
    /// 相对居中（各 15%）略偏上，符合用户「上下居中再稍微往上一些」的诉求。
    private static let verticalTopMarginRatio: CGFloat = 0.12

    private let state: ReviewState
    private let behavior: WindowBehaviorMode
    private let expandedPanel: NSPanel
    private let capsulePanel: NSPanel
    private var expandedHosting: NSHostingView<ReviewView>!
    private let expandedVisualEffect = NSVisualEffectView()
    private var measurementHosting: PassthroughHostingView<ReviewMeasurementView>!
    private let expandedContainer = NSView()
    private let capsuleContainer = NSView()
    private var escMonitor: Any?
    private var stateChangeCancellable: AnyCancellable?
    private var preferredScreen: NSScreen?

    private let sizing = ReviewWindowSizing()
    private var machineState: ReviewWindowMachineState
    /// 上次应用的窗口 contentSize（0.5pt 阈值比较基准）。
    private var lastSize: CGSize = CGSize(width: ReviewWindowSizing.minWidth, height: 200)
    private var latestNaturalSize: CGSize = CGSize(width: ReviewWindowSizing.minWidth, height: 200)
    private var latestIsOverflowing = false
    private var measurementConstraints: [NSLayoutConstraint] = []

    /// Coordinator 注入：关闭按钮/标题栏关闭 → 汇聚到唯一 cancel 路径（会回调本控制器 close()）。
    var onRequestClose: (() -> Void)?
    /// Coordinator 注入：展开/折叠切换时回调，用于同步 activation policy（主菜单栏显隐）。
    var onPresentationChange: (() -> Void)?

    /// 展开的弹窗当前是否可见（用于决定是否显示顶部主菜单栏）。折叠为胶囊 / 已关闭时为 false。
    var isExpandedVisible: Bool { machineState.presentation == .expanded && expandedPanel.isVisible }

    init(state: ReviewState, behavior: WindowBehaviorMode = .normal) {
        self.state = state
        self.behavior = behavior
        self.machineState = ReviewWindowMachineState(behavior: behavior, presentation: .expanded)
        expandedPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: ReviewWindowSizing.minWidth, height: 200),
            styleMask: ReviewWindowStyle.expanded,   // 已去 .resizable：尺寸全自动
            backing: .buffered, defer: false
        )
        capsulePanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 44),
            styleMask: ReviewWindowStyle.capsule,
            backing: .buffered, defer: false
        )
        super.init()
        stateChangeCancellable = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMeasurement() }
        }
        // 「隐藏」按钮（现位于弹窗底部操作栏）→ 折叠为胶囊，与旧标题栏隐藏图标同一 .hideIcon 事件。
        state.onHide = { [weak self] in self?.handle(.hideIcon) }
        configurePanels()
    }

    private func configurePanels() {
        // 展开 panel。
        expandedPanel.title = "LangFix"
        expandedPanel.titlebarAppearsTransparent = true
        expandedPanel.backgroundColor = .clear
        expandedPanel.isOpaque = false
        expandedPanel.hasShadow = true
        expandedPanel.contentMinSize = CGSize(width: ReviewWindowSizing.minWidth, height: sizing.minHeight)
        let hosting = NSHostingView(rootView: makeReviewView(maxContentSize: defaultMaxContentSize))
        expandedHosting = hosting
        configureExpandedContainer()
        // 隐藏功能已下沉到弹窗底部操作栏的「隐藏」按钮（design round4），不再用标题栏 minus.circle 图标。

        // 折叠胶囊 panel：透明、承载 SwiftUI 胶囊。
        let capsuleHosting = NSHostingView(rootView: CollapsedReviewEntry(state: state, behavior: behavior) { [weak self] in
            self?.handle(.tapCapsule)
        })
        capsuleHosting.layer?.backgroundColor = .clear
        configureCapsuleContainer(capsuleHosting)
        capsulePanel.backgroundColor = .clear
        capsulePanel.isOpaque = false
        capsulePanel.hasShadow = false

        measurementHosting = PassthroughHostingView(rootView: makeMeasurementView(maxContentSize: defaultMaxContentSize) { _ in })
        measurementHosting.alphaValue = 0
        measurementHosting.translatesAutoresizingMaskIntoConstraints = false
        attachMeasurementHost(to: expandedContainer, maxContentSize: defaultMaxContentSize)

        // 两 panel level / collectionBehavior / 释放策略保持一致（防跳层 / 丢 Space，design.md §2.2）。
        for p in [expandedPanel, capsulePanel] {
            applyLevel(to: p)
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.delegate = self
        }
    }

    /// 构造注入了主题上限与自然尺寸回调的 ReviewView。
    private func makeReviewView(maxContentSize: CGSize) -> ReviewView {
        ReviewView(state: state, maxContentSize: maxContentSize, isOverflowing: latestIsOverflowing)
    }

    private func makeMeasurementView(maxContentSize: CGSize,
                                     onNaturalSizeChange: @escaping (CGSize) -> Void) -> ReviewMeasurementView {
        ReviewMeasurementView(state: state, maxContentSize: maxContentSize,
                              onNaturalSizeChange: onNaturalSizeChange)
    }

    private func configureExpandedContainer() {
        expandedVisualEffect.translatesAutoresizingMaskIntoConstraints = false
        expandedVisualEffect.blendingMode = .behindWindow
        expandedVisualEffect.material = .hudWindow
        expandedVisualEffect.state = .active
        expandedContainer.addSubview(expandedVisualEffect)
        expandedHosting.translatesAutoresizingMaskIntoConstraints = false
        expandedHosting.layer?.backgroundColor = .clear
        expandedContainer.addSubview(expandedHosting)
        expandedPanel.contentView = expandedContainer
        NSLayoutConstraint.activate([
            expandedVisualEffect.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            expandedVisualEffect.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            expandedVisualEffect.topAnchor.constraint(equalTo: expandedContainer.topAnchor),
            expandedVisualEffect.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor),
            expandedHosting.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            expandedHosting.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            expandedHosting.topAnchor.constraint(equalTo: expandedContainer.topAnchor),
            expandedHosting.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor),
        ])
    }

    private func configureCapsuleContainer(_ capsuleHosting: NSHostingView<CollapsedReviewEntry>) {
        capsuleHosting.translatesAutoresizingMaskIntoConstraints = false
        capsuleContainer.addSubview(capsuleHosting)
        capsulePanel.contentView = capsuleContainer
        NSLayoutConstraint.activate([
            capsuleHosting.leadingAnchor.constraint(equalTo: capsuleContainer.leadingAnchor),
            capsuleHosting.trailingAnchor.constraint(equalTo: capsuleContainer.trailingAnchor),
            capsuleHosting.topAnchor.constraint(equalTo: capsuleContainer.topAnchor),
            capsuleHosting.bottomAnchor.constraint(equalTo: capsuleContainer.bottomAnchor),
        ])
    }

    private func attachMeasurementHost(to container: NSView, maxContentSize: CGSize) {
        measurementConstraints.forEach { $0.isActive = false }
        measurementConstraints = []
        measurementHosting.removeFromSuperview()
        measurementHosting.rootView = makeMeasurementView(maxContentSize: maxContentSize) { [weak self] _ in
            self?.refreshMeasurement()
        }
        measurementHosting.alphaValue = 0
        container.addSubview(measurementHosting)
        measurementConstraints = [
            measurementHosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            measurementHosting.topAnchor.constraint(equalTo: container.topAnchor),
            measurementHosting.widthAnchor.constraint(equalToConstant: maxContentSize.width),
        ]
        NSLayoutConstraint.activate(measurementConstraints)
        refreshMeasurement()
    }

    private func refreshMeasurement() {
        let maxSize = currentMaxContentSize()
        let measuringController = NSHostingController(rootView: makeMeasurementView(maxContentSize: maxSize) { _ in })
        measuringController.view.frame = NSRect(x: 0, y: 0, width: maxSize.width, height: 1)
        measuringController.view.layoutSubtreeIfNeeded()
        let fitted = measuringController.sizeThatFits(in: CGSize(width: maxSize.width,
                                                                 height: .greatestFiniteMagnitude))
        if fitted.width > 0, fitted.height > 0 {
            updateNaturalSize(fitted)
        }
    }

    private func applyLevel(to panel: NSPanel) {
        let p = WindowLevelPolicy.policy(for: behavior)
        panel.isFloatingPanel = p.isFloatingPanel
        panel.level = p.level
    }

    /// 上屏前的兜底上限（真实上限在上屏后按 panel.screen 重算）。
    private var defaultMaxContentSize: CGSize {
        let vf = (preferredScreen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return sizing.limits(visibleFrame: vf)
    }

    func showCentered() {
        preferredScreen = Self.screenContainingMouse() ?? NSScreen.main
        positionExpandedPanelForInitialDisplay()
        NSApp.activate(ignoringOtherApps: true)
        expandedPanel.makeKeyAndOrderFront(nil)
        // 上屏后按真实所在屏刷新内容上限。
        refreshDisplayedView()
        attachMeasurementHost(to: expandedContainer, maxContentSize: currentMaxContentSize())
        // Esc：经 .cancelAction 移除后由此 monitor 归一为「折叠」（design.md §2.3）。
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {   // Esc
                self.handle(.esc)
                return nil
            }
            return event
        }
    }

    private func currentMaxContentSize() -> CGSize {
        let vf = (expandedPanel.screen ?? preferredScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        return sizing.limits(visibleFrame: vf)
    }

    private func refreshDisplayedView() {
        expandedHosting.rootView = makeReviewView(maxContentSize: currentMaxContentSize())
    }

    // MARK: - 尺寸自适应（独立测量宿主 + runloop 合并 + clamp + 顶边锚定）

    private func updateNaturalSize(_ natural: CGSize) {
        guard natural.width > 0, natural.height > 0 else { return }
        latestNaturalSize = natural
        let vf = (expandedPanel.screen ?? preferredScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let overflowing = sizing.isOverflowing(natural: natural, visibleFrame: vf)
        if overflowing != latestIsOverflowing {
            latestIsOverflowing = overflowing
            refreshDisplayedView()
        }
        applyResize(latestNaturalSize, force: false)
    }

    private func applyResize(_ natural: CGSize, force: Bool) {
        guard machineState.presentation == .expanded else { return }
        let vf = (expandedPanel.screen ?? preferredScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let target = sizing.target(natural: natural, visibleFrame: vf)
        let currentSize = expandedPanel.contentView?.bounds.size ?? expandedPanel.contentRect(forFrameRect: expandedPanel.frame).size
        guard force || abs(target.width - currentSize.width) > 0.5 || abs(target.height - currentSize.height) > 0.5 else {
            lastSize = target
            return
        }
        lastSize = target
        var frame = expandedPanel.frame
        let top = frame.maxY
        frame.size = expandedPanel.frameRect(forContentRect: NSRect(origin: .zero, size: target)).size
        frame.origin.y = top - frame.height   // 顶边锚定，向下增高
        keepFrameInVisibleScreen(&frame, visibleFrame: vf)
        expandedPanel.setFrame(frame, display: true)
    }

    /// 一块屏的 frame + visibleFrame 快照（AppKit 解耦，便于把「选屏」逻辑单测到真实路径）。
    struct ScreenFrame: Equatable, Sendable { var frame: NSRect; var visibleFrame: NSRect }

    /// **round5 修复多屏定位**：初始定位必须以**鼠标所在屏**为权威屏。
    ///
    /// 旧 bug（第 3 次复发的真根因）：这里曾用 `expandedPanel.screen ?? preferredScreen ?? …`——
    /// 窗口首次上屏前 panel 的 frame 仍在主屏，`expandedPanel.screen` 非 nil 即主屏，直接盖掉了
    /// `preferredScreen`（鼠标屏），于是拿主屏 vf 去 clamp，把窗口永远拉回主屏。
    /// 而此前单测只测「注入 vf 的 `placeInitialFrame`」，从不覆盖「运行时到底选了哪块屏」，故测试绿却没修好。
    ///
    /// 现在：直接把 `NSScreen.screens` 快照喂给纯函数 `initialFrame`，由它按鼠标选屏 → 定位 → clamp，
    /// **完全不看 `expandedPanel.screen`**；上屏后的 resize 路径仍可用 `expandedPanel.screen`（那时已在正确屏）。
    private func positionExpandedPanelForInitialDisplay() {
        let screens = NSScreen.screens.map { ScreenFrame(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let fallback = (preferredScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let frame = Self.initialFrame(windowSize: expandedPanel.frame.size,
                                      mouseLocation: NSEvent.mouseLocation,
                                      screens: screens,
                                      fallbackVisibleFrame: fallback,
                                      gap: Self.followMouseGap,
                                      topMarginRatio: Self.verticalTopMarginRatio)
        expandedPanel.setFrame(frame, display: false)
    }

    /// 按鼠标位置选屏 → 返回该屏 visibleFrame（命中不了任何屏时用 fallback）。
    /// 生产选屏与测试选屏共用此实现，杜绝「测一份、生产走另一份」。
    static func selectVisibleFrame(mouseLocation: NSPoint,
                                   screens: [ScreenFrame],
                                   fallback: NSRect) -> NSRect {
        screens.first(where: { $0.frame.contains(mouseLocation) })?.visibleFrame ?? fallback
    }

    /// **组合**：按鼠标选屏 → 在该屏 visibleFrame 内跟随鼠标定位 → clamp。生产与测试走同一条路径。
    /// 这是 `positionExpandedPanelForInitialDisplay` 的完整可测替身：唯一非注入的只剩
    /// `NSScreen.screens` / `NSEvent.mouseLocation` 两个薄适配，选屏+定位的真实逻辑全在此函数。
    static func initialFrame(windowSize: CGSize,
                             mouseLocation: NSPoint,
                             screens: [ScreenFrame],
                             fallbackVisibleFrame: NSRect,
                             gap: CGFloat,
                             topMarginRatio: CGFloat) -> NSRect {
        let vf = selectVisibleFrame(mouseLocation: mouseLocation, screens: screens, fallback: fallbackVisibleFrame)
        return placeInitialFrame(windowSize: windowSize, mouseLocation: mouseLocation,
                                 visibleFrame: vf, gap: gap, topMarginRatio: topMarginRatio)
    }

    /// 跟随鼠标定位的纯函数（与 AppKit 解耦、可单测）：
    /// - 水平：优先把窗口放在鼠标右侧并留 `gap` 呼吸间距；右侧放不下则翻到鼠标左侧同样留 `gap`。
    /// - 竖直：以「最大化时上下居中略偏上」为目标，锚定顶边到 `屏顶 - 屏高×topMarginRatio`。
    /// - 最后统一 clamp 回 visibleFrame，保证任何屏幕/鼠标位置都不越界。
    static func placeInitialFrame(windowSize: CGSize,
                                  mouseLocation: NSPoint,
                                  visibleFrame vf: NSRect,
                                  gap: CGFloat,
                                  topMarginRatio: CGFloat) -> NSRect {
        var frame = NSRect(origin: .zero, size: windowSize)
        guard vf != .zero else { return frame }
        // 水平：鼠标右侧留 gap；越过右边界则翻到左侧。
        let rightX = mouseLocation.x + gap
        if rightX + windowSize.width <= vf.maxX {
            frame.origin.x = rightX
        } else {
            frame.origin.x = mouseLocation.x - gap - windowSize.width
        }
        // 竖直：锚定顶边（bottom-left 坐标系里 origin.y = 顶边 - 高）。
        let topEdgeY = vf.maxY - vf.height * topMarginRatio
        frame.origin.y = topEdgeY - windowSize.height
        clampToVisibleFrame(&frame, visibleFrame: vf)
        return frame
    }

    /// 把越界 frame 平移回 visibleFrame 内（不缩放，仅平移）。
    private func keepFrameInVisibleScreen(_ frame: inout NSRect, visibleFrame vf: NSRect) {
        Self.clampToVisibleFrame(&frame, visibleFrame: vf)
    }

    /// clamp 的纯静态实现（实例路径与初始定位共用同一份逻辑，杜绝两份漂移）。
    static func clampToVisibleFrame(_ frame: inout NSRect, visibleFrame vf: NSRect) {
        guard vf != .zero else { return }
        if frame.maxX > vf.maxX { frame.origin.x = vf.maxX - frame.width }
        if frame.minX < vf.minX { frame.origin.x = vf.minX }
        if frame.maxY > vf.maxY { frame.origin.y = vf.maxY - frame.height }
        if frame.minY < vf.minY { frame.origin.y = vf.minY }
    }

    // MARK: - 三态迁移（纯状态机驱动）

    func handleForTesting(_ event: ReviewWindowEvent) {
        handle(event)
    }

    func expandedPanelAppearanceForTesting() -> (isOpaque: Bool, backgroundColor: NSColor?) {
        (expandedPanel.isOpaque, expandedPanel.backgroundColor)
    }

    func expandedVisualEffectForTesting() -> (material: NSVisualEffectView.Material,
                                              blendingMode: NSVisualEffectView.BlendingMode,
                                              state: NSVisualEffectView.State) {
        (expandedVisualEffect.material, expandedVisualEffect.blendingMode, expandedVisualEffect.state)
    }

    /// 旧兼容签名（frames-only）：委托到统一的 `selectVisibleFrame`（frame 视作 visibleFrame），
    /// 不再是独立实现——保证选屏逻辑只有一份。
    static func visibleFrameForInitialDisplayForTesting(mouseLocation: NSPoint,
                                                        screens: [NSRect],
                                                        fallback: NSRect) -> NSRect {
        selectVisibleFrame(mouseLocation: mouseLocation,
                           screens: screens.map { ScreenFrame(frame: $0, visibleFrame: $0) },
                           fallback: fallback)
    }

    static func initialFrameForTesting(windowFrame: NSRect,
                                       mouseLocation: NSPoint,
                                       visibleFrame: NSRect) -> NSRect {
        placeInitialFrame(windowSize: windowFrame.size,
                          mouseLocation: mouseLocation,
                          visibleFrame: visibleFrame,
                          gap: followMouseGap,
                          topMarginRatio: verticalTopMarginRatio)
    }

    private static func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }

    struct MeasurementSnapshot: Equatable {
        var natural: CGSize
        var appliedContent: CGSize
        var maxContent: CGSize
        var isOverflowing: Bool
    }

    @discardableResult
    func measureAndApplyForTesting(force: Bool = true) -> MeasurementSnapshot {
        refreshMeasurement()
        applyResize(latestNaturalSize, force: force)
        return measurementSnapshotForTesting()
    }

    func measurementSnapshotForTesting() -> MeasurementSnapshot {
        let contentSize = expandedPanel.contentView?.bounds.size ?? expandedPanel.contentRect(forFrameRect: expandedPanel.frame).size
        return MeasurementSnapshot(
            natural: latestNaturalSize,
            appliedContent: contentSize,
            maxContent: currentMaxContentSize(),
            isOverflowing: latestIsOverflowing
        )
    }

    private func handle(_ event: ReviewWindowEvent) {
        let outcome = machineState.reduceOutcome(event)
        if outcome.actions.contains(.cancelTask) {                 // 关闭路径：委托 Coordinator 唯一 cancel 出口
            machineState.presentation = .closed
            onRequestClose?()
            return
        }
        let from = machineState.presentation
        machineState.presentation = outcome.presentation
        for action in outcome.actions {
            switch action {
            case .applyLevel:
                applyLevel(to: expandedPanel)
                applyLevel(to: capsulePanel)
            case .recomputeSize:
                refreshMeasurement()
                applyResize(latestNaturalSize, force: true)
            case .orderCapsule:
                applyCollapse(from: from)
            case .orderExpanded:
                applyExpand(from: from)
            case .cancelTask:
                break
            }
        }
    }

    private func applyCollapse(from: ReviewWindowMode) {
        attachMeasurementHost(to: capsuleContainer, maxContentSize: currentMaxContentSize())
        applyLevel(to: capsulePanel)
        // 胶囊定位：与展开 panel 顶边对齐、水平居中，再 clamp 到 visibleFrame。
        let ef = expandedPanel.frame
        var cf = capsulePanel.frame
        cf.origin.x = ef.midX - cf.width / 2
        cf.origin.y = ef.maxY - cf.height
        let vf = (expandedPanel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        keepFrameInVisibleScreen(&cf, visibleFrame: vf)
        capsulePanel.setFrame(cf, display: true)
        expandedPanel.orderOut(nil)
        capsulePanel.orderFront(nil)
        onPresentationChange?()          // 折叠 → 收起主菜单栏（回 .accessory）
    }

    private func applyExpand(from: ReviewWindowMode) {
        capsulePanel.orderOut(nil)
        attachMeasurementHost(to: expandedContainer, maxContentSize: currentMaxContentSize())
        refreshDisplayedView()
        applyLevel(to: expandedPanel)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        expandedPanel.makeKeyAndOrderFront(nil)
        onPresentationChange?()          // 展开 → 显示主菜单栏（切 .regular）
    }

    // MARK: - NSWindowDelegate

    /// 失焦 → 折叠（延迟 120ms 过滤焦点抖动，design.md §2.3）。
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === expandedPanel else { return }
        guard behavior == .focusCollapse, machineState.presentation == .expanded else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self, self.machineState.presentation == .expanded, !self.expandedPanel.isKeyWindow else { return }
            self.handle(.resignKey)
        }
    }

    /// 标题栏关闭按钮：汇聚到唯一 cancel 路径，返回 false 阻止 AppKit 自行 close（我们已在 handle 里销毁）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        handle(.closeRequested)
        return false
    }

    // MARK: - 销毁

    /// 真正的销毁：移除 monitor、两 panel orderOut+close、清 delegate。幂等。
    func close() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        stateChangeCancellable = nil
        machineState.presentation = .closed
        for p in [expandedPanel, capsulePanel] {
            p.delegate = nil
            p.orderOut(nil)
            p.close()
        }
    }
}

// MARK: - 设置窗口控制器

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    /// 设置窗关闭回调（Coordinator 注入，用于重新评估 activation policy）。
    var onClose: (() -> Void)?

    /// 设置窗当前是否可见（用于决定是否显示顶部主菜单栏）。
    var isVisible: Bool { window.isVisible }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LangFix 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init()
        window.delegate = self
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭后窗口 isVisible 变 false，通知 Coordinator 重算 activation policy。
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}
