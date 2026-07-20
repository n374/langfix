import SwiftUI
import AppKit

/// 用户可选窗口行为模式。该偏好为非敏感 UI 偏好，持久化到 UserDefaults（默认 C）。
enum WindowBehaviorMode: String, CaseIterable, Identifiable, Sendable {
    case focusCollapse
    case alwaysOnTop
    case normal

    var id: String { rawValue }

    static let defaultMode: WindowBehaviorMode = .normal

    init(rawValueOrDefault raw: String?) {
        self = WindowBehaviorMode(rawValue: raw ?? "") ?? .defaultMode
    }

    /// 模式标题随用户语言（language-config design D4）。
    func title(_ lang: AppLanguage) -> String {
        switch self {
        case .focusCollapse: return L10n.t(.windowModeFocusCollapseTitle, lang)
        case .alwaysOnTop: return L10n.t(.windowModeAlwaysOnTopTitle, lang)
        case .normal: return L10n.t(.windowModeNormalTitle, lang)
        }
    }

    func subtitle(_ lang: AppLanguage) -> String {
        switch self {
        case .focusCollapse: return L10n.t(.windowModeFocusCollapseSubtitle, lang)
        case .alwaysOnTop: return L10n.t(.windowModeAlwaysOnTopSubtitle, lang)
        case .normal: return L10n.t(.windowModeNormalSubtitle, lang)
        }
    }

    var iconName: String {
        switch self {
        case .focusCollapse: return "eye.slash"
        case .alwaysOnTop: return "pin.fill"
        case .normal: return "macwindow"
        }
    }
}

/// 弹窗容器三态，与 AI 业务态 `ReviewState.Phase` 完全解耦（design.md §2.2 决策 D3）。
/// - expanded：展开面板可见、可交互
/// - collapsed：折叠为胶囊入口，展开面板 orderOut（不销毁），底层 Task 后台继续
/// - closed：销毁两面板并取消底层 Task（幂等终态）
enum ReviewWindowMode: Equatable, Sendable {
    case expanded
    case collapsed
    case closed
}

/// 驱动窗口态迁移的事件。UI 侧（失焦/Esc/点击胶囊/关闭按钮）统一归一为这几个事件。
enum ReviewWindowEvent: Equatable, Sendable {
    case resignKey       // 失焦（点到别处）
    case esc             // 按下 Esc（经 .cancelAction 修正后只折叠，不再关闭）
    case hideIcon        // 标题栏隐藏图标
    case tapCapsule      // 点击折叠胶囊
    case closeRequested  // 关闭按钮 / 取消按钮 / 标题栏关闭
}

enum ReviewWindowAction: Equatable, Sendable {
    case applyLevel
    case recomputeSize
    case cancelTask
    case orderCapsule
    case orderExpanded
}

struct ReviewWindowOutcome: Equatable, Sendable {
    var presentation: ReviewWindowMode
    var actions: [ReviewWindowAction]
}

/// 单一状态机：开窗时捕获 behavior，运行期只迁移 presentation。
struct ReviewWindowMachineState: Equatable, Sendable {
    var behavior: WindowBehaviorMode
    var presentation: ReviewWindowMode

    func reduce(_ event: ReviewWindowEvent) -> ReviewWindowTransition {
        let outcome = reduceOutcome(event)
        return ReviewWindowTransition(mode: outcome.presentation, cancelTask: outcome.actions.contains(.cancelTask))
    }

    func reduceOutcome(_ event: ReviewWindowEvent) -> ReviewWindowOutcome {
        if presentation == .closed { return ReviewWindowOutcome(presentation: .closed, actions: []) }

        switch (presentation, event) {
        case (.expanded, .resignKey):
            return behavior == .focusCollapse
                ? ReviewWindowOutcome(presentation: .collapsed, actions: [.orderCapsule, .applyLevel])
                : ReviewWindowOutcome(presentation: .expanded, actions: [])
        case (.expanded, .esc), (.expanded, .hideIcon):
            return ReviewWindowOutcome(presentation: .collapsed, actions: [.orderCapsule, .applyLevel])
        case (.collapsed, .tapCapsule):
            return ReviewWindowOutcome(presentation: .expanded, actions: [.recomputeSize, .applyLevel, .orderExpanded])
        case (_, .closeRequested):
            return ReviewWindowOutcome(presentation: .closed, actions: [.cancelTask])
        default:
            return ReviewWindowOutcome(presentation: presentation, actions: [])
        }
    }
}

/// 旧测试/关闭语义测试仍可用的轻量兼容结构。
struct ReviewWindowTransition: Equatable, Sendable {
    var mode: ReviewWindowMode
    var cancelTask: Bool
}

extension ReviewWindowMode {
    /// Round1 兼容入口：按 A（失焦折叠）解释旧状态机语义。
    func reduce(_ event: ReviewWindowEvent) -> ReviewWindowTransition {
        ReviewWindowMachineState(behavior: .focusCollapse, presentation: self).reduce(event)
    }
}

struct WindowLevelPolicy: Equatable, Sendable {
    var level: NSWindow.Level
    var isFloatingPanel: Bool

    static func policy(for behavior: WindowBehaviorMode) -> WindowLevelPolicy {
        switch behavior {
        case .alwaysOnTop:
            return WindowLevelPolicy(level: .floating, isFloatingPanel: true)
        case .focusCollapse, .normal:
            return WindowLevelPolicy(level: .normal, isFloatingPanel: false)
        }
    }
}

/// 折叠胶囊的三态视觉标识，由 AI 业务态 `Phase` 派生（design.md §2.2）。
enum CollapsedStatus: Equatable, Sendable {
    case working   // loading / streaming
    case done      // result
    case failed    // error

    init(_ phase: ReviewState.Phase) {
        switch phase {
        case .loading, .streaming: self = .working
        case .stopped, .result:    self = .done
        case .error:               self = .failed
        }
    }

    /// SF Symbol 图标（语义固定，三态互不相同）。
    var iconName: String {
        switch self {
        case .working: return "sparkles"
        case .done:    return "checkmark.seal.fill"
        case .failed:  return "exclamationmark.triangle.fill"
        }
    }

    /// 胶囊文案随用户语言（language-config design D4）。
    func title(_ lang: AppLanguage) -> String {
        switch self {
        case .working: return L10n.t(.capsuleWorking, lang)
        case .done:    return L10n.t(.capsuleDone, lang)
        case .failed:  return L10n.t(.capsuleFailed, lang)
        }
    }

    /// 取当前主题的语义色 token（颜色随主题变，语义映射固定）。
    func color(_ theme: ReviewTheme) -> Color {
        switch self {
        case .working: return theme.accent
        case .done:    return theme.success
        case .failed:  return theme.error
        }
    }
}
