import CoreGraphics

/// 弹窗尺寸策略（纯逻辑，与 AppKit 解耦，便于单测）。
///
/// 规则（design.md §2.1a / spec review-window「弹窗尺寸随内容自适应」）：
/// - 宽 clamp 到 `[minWidth, maxW]`，`maxW = 所在屏 visibleFrame 宽 × widthRatio`；
/// - 高 clamp 到 `[minHeight, maxH]`，`maxH = 所在屏 visibleFrame 高 × heightRatio`；
/// - 上限一律屏幕相对（禁固定 px），保证不同分辨率下上限比例一致；
/// - 超上限的维度由内容区内部 `ScrollView` 承载。
///
/// 窄屏兜底（design.md §8 Q1 决策 D2）：`visibleW < 1200pt` 时 `visibleW×0.4 < 480`，
/// 区间 `[480, maxW]` 数学非法。故 `maxW = max(minWidth, visibleW×widthRatio)`——
/// 常规屏遵守 40% 相对上限，极窄屏以 480pt 最小可用宽兜底。高同理用 `max(minHeight, …)`。
struct ReviewWindowSizing: Equatable {
    static let minWidth: CGFloat = 480
    static let widthRatio: CGFloat = 0.4
    static let heightRatio: CGFloat = 0.7

    /// 容纳透明标题栏 + 首行状态 + footer 的自然最小高（内容驱动，天然分辨率无关）。
    var minHeight: CGFloat = 132

    /// 屏幕相对上限。窄屏兜底见类型注释（D2）。
    func limits(visibleFrame vf: CGRect) -> CGSize {
        CGSize(width:  max(Self.minWidth, vf.width  * Self.widthRatio),
               height: max(minHeight,     vf.height * Self.heightRatio))
    }

    /// 由内容自然尺寸 + 屏幕 visibleFrame 计算目标窗口 contentSize（各维度 clamp）。
    func target(natural: CGSize, visibleFrame vf: CGRect) -> CGSize {
        let m = limits(visibleFrame: vf)
        return CGSize(width:  min(max(natural.width,  Self.minWidth), m.width),
                      height: min(max(natural.height, minHeight),     m.height))
    }

    /// 带单调增高守卫的目标尺寸：loading/streaming 阶段高度只增不减（配合单调前缀守卫，防抖不闪缩）。
    /// 非流式阶段（result/error 收敛）不强制单调，但调用方通常也不主动缩小以避免闪跳。
    func monotonicTarget(natural: CGSize, visibleFrame vf: CGRect,
                         lastHeight: CGFloat, isStreaming: Bool) -> CGSize {
        var t = target(natural: natural, visibleFrame: vf)
        if isStreaming { t.height = max(lastHeight, t.height) }
        return t
    }
}
