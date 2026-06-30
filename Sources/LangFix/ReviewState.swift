import SwiftUI

/// 浮窗状态机：loading / streaming / result / error。
@MainActor
final class ReviewState: ObservableObject {
    enum Phase {
        case loading
        /// 流式「校对预览中」：增量展示 corrected 前缀 + 已闭合结构化字段，继承 loading 的可取消语义。
        case streaming(StreamingPreview)
        case result(ReviewResult)
        case error(String)
    }

    @Published var phase: Phase = .loading
    var input: String = ""

    /// loading 期间「取消」、error 期间「重试」、关闭窗口的回调，由 Coordinator 注入。
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?
}
