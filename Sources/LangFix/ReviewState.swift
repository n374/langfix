import SwiftUI

/// 浮窗状态机：loading / streaming / result / error。
@MainActor
final class ReviewState: ObservableObject {
    enum Phase {
        case loading
        /// 流式「校对预览中」：增量展示 corrected 前缀 + 已闭合结构化字段，继承 loading 的可取消语义。
        case streaming(StreamingPreview)
        /// 用户主动「停止」流式后冻结的部分结果：停止底层请求、保留已生成内容、窗口不关闭。
        case stopped(StreamingPreview)
        case result(ReviewResult)
        case error(String)
    }

    @Published var phase: Phase = .loading
    var input: String = ""

    /// 追问会话（仅在 `.result` 态由 Coordinator 注入；随本 state 生命周期释放，ai-followup change · design D2）。
    @Published var followUp: FollowUpSession?

    /// escMonitor 桥接可查询态（评审#6 / design UI-7）：追问输入框是否聚焦。
    /// **刻意非 @Published**：由追问输入框焦点变化更新，若 @Published 会触发窗口 remeasure 抖动；
    /// escMonitor 在主线程同步读取，无需观察。IME 组合态改由 escMonitor 直接查 field editor 的
    /// `hasMarkedText`（真状态，不再靠 UI 回填一个易漏写的标志位）。
    var composerFocused = false

    /// loading 期间「取消」、error 期间「重试」、关闭窗口的回调，由 Coordinator 注入。
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// 流式「停止」：停止底层请求但保留已生成内容、窗口不关闭（Coordinator 注入）。
    var onStop: (() -> Void)?
    /// 「隐藏」：把窗口折叠为胶囊入口（由 ReviewWindowController 注入，转 .hideIcon 事件）。
    var onHide: (() -> Void)?
}
