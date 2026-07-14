import AppKit

/// 两个面板的 styleMask 工厂（抽出便于单测「不含 .resizable」，见 spec review-window「取消手动 resize」）。
enum ReviewWindowStyle {
    /// 展开面板：去掉 `.resizable`——尺寸完全由内容/流式自动驱动，用户不可手动拉伸（design.md §2.8）。
    static let expanded: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]

    /// 折叠胶囊面板：无边框、非激活（点击胶囊不抢主 App 焦点）。
    static let capsule: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
}
