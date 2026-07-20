import SwiftUI

/// 结果浮窗字号档位（design font-size-setting D2）：4 档预设，锚定旧正文基准 13pt。
/// 非敏感 UI 偏好，只存 rawValue 于 UserDefaults（同 `reviewTheme` / `windowBehaviorMode` 模式）。
enum ReviewFontTier: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case xLarge = "xlarge"

    var id: String { rawValue }

    /// 默认「大」：满足需求「默认比现状大一档」。经 `register(defaults:)` 注册后，
    /// 全新安装与未显式设置过的老用户升级后都得到新默认；显式改过档位的用户不受影响。
    static let defaultTier: ReviewFontTier = .large

    /// 非法 rawValue fallback 默认（与 `WindowBehaviorMode.rawValueOrDefault` 模式一致）。
    init(rawValueOrDefault raw: String?) {
        self = ReviewFontTier(rawValue: raw ?? "") ?? .defaultTier
    }

    /// 档位展示名随用户语言（language-config design D4）。
    func displayName(_ lang: AppLanguage) -> String {
        switch self {
        case .small: return L10n.t(.fontTierSmall, lang)
        case .standard: return L10n.t(.fontTierStandard, lang)
        case .large: return L10n.t(.fontTierLarge, lang)
        case .xLarge: return L10n.t(.fontTierXLarge, lang)
        }
    }

    /// 各档正文 pt（design D2 档位表）。standard = 旧正文基准 13pt（macOS `.body` 默认）。
    var bodyPoint: CGFloat {
        switch self {
        case .small: return 12
        case .standard: return 13
        case .large: return 14.5
        case .xLarge: return 16
        }
    }

    /// 缩放系数 = 本档正文 / 旧基准 13。其余角色字号由 standard 档 pt × scale 派生。
    var scale: CGFloat { bodyPoint / ReviewTypography.legacyBodyBaseline }
}

/// 结果浮窗统一字体来源（design font-size-setting D3）：档位 → 语义角色字号映射表，
/// 取代 `ReviewView.swift` 内散落的 `.caption` / `.callout` / `.system(size:)` 硬编码。
/// 纯逻辑、无 UI 依赖，可单测；Font 便捷访问器统一走 `.system(size:weight:design:)`。
struct ReviewTypography: Equatable {
    /// 本 change 前正文无显式字体 → macOS `.body` 默认 13pt。spec「默认大于旧正文基准」
    /// 的断言即 `Typography(默认档).body > legacyBodyBaseline`，不依赖散落硬值。
    static let legacyBodyBaseline: CGFloat = 13

    /// standard 档（scale 1.0）各角色固化 pt 表：按 macOS 默认内容尺寸下系统 text style
    /// 当前取值固化（.body 13 / .callout 12 / .subheadline 11 / .caption 10），视觉还原现状观感。
    private enum Base {
        static let body: CGFloat = 13          // 正文卡片（修正结果 / 地道版 / 流式预览 / loading / error 文案 / diff）
        static let bubble: CGFloat = 12.5      // 追问气泡 / Markdown 回答 / composer 输入框
        static let issueLine: CGFloat = 12     // issue 卡 before→after 行（原 .callout）
        static let header: CGFloat = 11        // 顶部状态 Label（原 .subheadline，semibold）
        static let sectionLabel: CGFloat = 10  // 区块小标题 / 总评 / 直译 / reason / hint（原 .caption）
        static let badge: CGFloat = 10         // 类别徽标 / 严重度 / 「修正 N」chip（原 .caption2 / system 10）
        static let chipTitle: CGFloat = 12.5   // ActionChip 标题（medium rounded）
        static let chipIcon: CGFloat = 11      // ActionChip 图标（semibold）
        static let iconAction: CGFloat = 13    // composer 尾部按钮图标（semibold）
    }

    let tier: ReviewFontTier

    init(tier: ReviewFontTier) { self.tier = tier }

    /// 派生字号做半点取整（round(pt × scale × 2) / 2），避免怪异小数导致的渲染模糊。
    private func scaled(_ base: CGFloat) -> CGFloat {
        (base * tier.scale * 2).rounded() / 2
    }

    // MARK: 角色字号（pt）

    var body: CGFloat { scaled(Base.body) }
    var bubble: CGFloat { scaled(Base.bubble) }
    var issueLine: CGFloat { scaled(Base.issueLine) }
    var header: CGFloat { scaled(Base.header) }
    var sectionLabel: CGFloat { scaled(Base.sectionLabel) }
    var badge: CGFloat { scaled(Base.badge) }
    var chipTitle: CGFloat { scaled(Base.chipTitle) }
    var chipIcon: CGFloat { scaled(Base.chipIcon) }
    var iconAction: CGFloat { scaled(Base.iconAction) }

    /// 全角色字号（测试用：档位单调性逐角色断言）。
    var allRolePoints: [CGFloat] {
        [body, bubble, issueLine, header, sectionLabel, badge, chipTitle, chipIcon, iconAction]
    }

    // MARK: Font 便捷访问器（权重/design 与替换前各点一致）

    var bodyFont: Font { .system(size: body) }
    var bubbleFont: Font { .system(size: bubble) }
    var issueLineFont: Font { .system(size: issueLine) }
    var headerFont: Font { .system(size: header, weight: .semibold) }
    var sectionLabelFont: Font { .system(size: sectionLabel) }
    var sectionLabelBoldFont: Font { .system(size: sectionLabel, weight: .bold) }
    var badgeFont: Font { .system(size: badge) }
    var badgeBoldFont: Font { .system(size: badge, weight: .bold) }
    var badgeSemiboldFont: Font { .system(size: badge, weight: .semibold) }
    var chipTitleFont: Font { .system(size: chipTitle, weight: .medium, design: .rounded) }
    var chipIconFont: Font { .system(size: chipIcon, weight: .semibold) }
    var iconActionFont: Font { .system(size: iconAction, weight: .semibold) }
}
