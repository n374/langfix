import SwiftUI

/// 浮窗状态机：loading / result / error。
@MainActor
final class ReviewState: ObservableObject {
    enum Phase {
        case loading
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
