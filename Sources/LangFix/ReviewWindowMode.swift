import SwiftUI

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
    case tapCapsule      // 点击折叠胶囊
    case closeRequested  // 关闭按钮 / 取消按钮 / 标题栏关闭
}

/// 一次迁移的结果：目标态 + 是否需要取消底层 Task。
///
/// **正确性核心**：`cancelTask` 仅在关闭路径为 `true`；失焦 / Esc / 点击胶囊一律 `false`
/// （回归现状「onClose 不 cancel」的 bug，见 design.md §2.4 / 决策 D4）。
struct ReviewWindowTransition: Equatable, Sendable {
    var mode: ReviewWindowMode
    var cancelTask: Bool
}

extension ReviewWindowMode {
    /// 纯状态机 reduce：给定当前态与事件，返回下一态与副作用标志。无副作用、可单测。
    func reduce(_ event: ReviewWindowEvent) -> ReviewWindowTransition {
        // closed 是终态，任何事件都幂等无副作用（不再取消、不再改 UI）。
        if self == .closed { return ReviewWindowTransition(mode: .closed, cancelTask: false) }

        switch (self, event) {
        case (.expanded, .resignKey), (.expanded, .esc):
            // 失焦 / Esc → 折叠，绝不取消（后台流式继续）。
            return ReviewWindowTransition(mode: .collapsed, cancelTask: false)
        case (.collapsed, .tapCapsule):
            // 点击胶囊 → 展开恢复。
            return ReviewWindowTransition(mode: .expanded, cancelTask: false)
        case (_, .closeRequested):
            // 关闭是唯一 cancel 路径：销毁 + 取消底层 Task。
            return ReviewWindowTransition(mode: .closed, cancelTask: true)
        default:
            // 其余组合（如 collapsed 下的 resignKey/esc、expanded 下的 tapCapsule）为无意义 no-op。
            return ReviewWindowTransition(mode: self, cancelTask: false)
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
        case .result:              self = .done
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

    /// 胶囊文案。
    var title: String {
        switch self {
        case .working: return "处理中"
        case .done:    return "已完成"
        case .failed:  return "出错"
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
