import SwiftUI

/// 弹窗视觉主题标识。持久化只存 `rawValue`（`Material` 不可 Codable，见 design.md §2.6）。
enum ReviewThemeID: String, CaseIterable, Identifiable, Sendable {
    case auroraGlass
    case neonNoir
    case solarInk
    case arcticCircuit

    var id: String { rawValue }

    /// 默认主题（用户拍板：Aurora Glass，design.md 决策 D5）。
    static let defaultID: ReviewThemeID = .auroraGlass

    /// 非法 / 缺失 rawValue 一律 fallback 默认，杜绝脏值导致空主题。
    init(rawValueOrDefault raw: String?) {
        self = ReviewThemeID(rawValue: raw ?? "") ?? .defaultID
    }
}

/// 一套主题的全部视觉 token。`Material` 不可 Codable，故仅 `id` 参与持久化。
struct ReviewTheme {
    let id: ReviewThemeID
    let displayName: String
    let material: Material
    /// 窗口背景渐变的上下两端（已烘焙透明度，叠在 material 之上）。
    let backgroundTop: Color
    let backgroundBottom: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let success: Color
    let warning: Color
    let error: Color
    let cardFill: Color
    let cardStroke: Color
    let glow: Color
    let glowOpacity: Double
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    let animationDuration: Double

    /// 折叠胶囊前景色（与主文本一致）。
    var collapsedForeground: Color { primaryText }

    /// 展开窗口背景：material 打底 + 主题渐变叠加。
    @ViewBuilder var windowBackground: some View {
        ZStack {
            Rectangle().fill(material)
            LinearGradient(colors: [backgroundTop, backgroundBottom],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// 四套主题静态目录（Codex 视觉定稿，design.md §2.7）。落地 hex 允许微调。
enum ReviewThemeCatalog {
    static func theme(_ id: ReviewThemeID) -> ReviewTheme {
        switch id {
        case .auroraGlass:   return auroraGlass
        case .neonNoir:      return neonNoir
        case .solarInk:      return solarInk
        case .arcticCircuit: return arcticCircuit
        }
    }

    /// A. Aurora Glass（默认）：冷静透明、macOS 原生感最强。
    static let auroraGlass = ReviewTheme(
        id: .auroraGlass, displayName: "Aurora Glass",
        material: .ultraThinMaterial,
        backgroundTop: Color(hex: 0x07111F, opacity: 0.42),
        backgroundBottom: Color(hex: 0x07111F, opacity: 0.72),
        primaryText: Color(hex: 0xEAF6FF), secondaryText: Color(hex: 0x9FB4C7),
        accent: Color(hex: 0x7DD3FC), success: Color(hex: 0x34D399),
        warning: Color(hex: 0xFBBF24), error: Color(hex: 0xFB7185),
        cardFill: Color(hex: 0x0B1220, opacity: 0.58), cardStroke: Color(hex: 0x7DD3FC, opacity: 0.22),
        glow: Color(hex: 0x7DD3FC), glowOpacity: 0.22,
        cornerRadius: 18, borderWidth: 1, animationDuration: 0.16)

    /// B. Neon Noir：暗色霓虹、最赛博。
    static let neonNoir = ReviewTheme(
        id: .neonNoir, displayName: "Neon Noir",
        material: .thinMaterial,
        backgroundTop: Color(hex: 0x050508, opacity: 0.60),
        backgroundBottom: Color(hex: 0x0B0A12, opacity: 0.88),
        primaryText: Color(hex: 0xF5F3FF), secondaryText: Color(hex: 0xA1A1AA),
        accent: Color(hex: 0xA78BFA), success: Color(hex: 0x10B981),
        warning: Color(hex: 0xF59E0B), error: Color(hex: 0xF43F5E),
        cardFill: Color(hex: 0x111018, opacity: 0.72), cardStroke: Color(hex: 0xA78BFA, opacity: 0.35),
        glow: Color(hex: 0xA78BFA), glowOpacity: 0.30,
        cornerRadius: 16, borderWidth: 1, animationDuration: 0.16)

    /// C. Solar Ink：深色纸面金墨、艺术感。
    static let solarInk = ReviewTheme(
        id: .solarInk, displayName: "Solar Ink",
        material: .regularMaterial,
        backgroundTop: Color(hex: 0x11100C, opacity: 0.55),
        backgroundBottom: Color(hex: 0x191510, opacity: 0.86),
        primaryText: Color(hex: 0xFFF7E6), secondaryText: Color(hex: 0xC8BFAE),
        accent: Color(hex: 0xF6C453), success: Color(hex: 0x84CC16),
        warning: Color(hex: 0xF97316), error: Color(hex: 0xEF4444),
        cardFill: Color(hex: 0x1A1712, opacity: 0.68), cardStroke: Color(hex: 0xF6C453, opacity: 0.28),
        glow: Color(hex: 0xF6C453), glowOpacity: 0.18,
        cornerRadius: 14, borderWidth: 1, animationDuration: 0.12)

    /// D. Arctic Circuit：明暗兼容最好，白玻璃 + 极地蓝。文本用系统自适应色以兼顾 light/dark。
    static let arcticCircuit = ReviewTheme(
        id: .arcticCircuit, displayName: "Arctic Circuit",
        material: .ultraThinMaterial,
        backgroundTop: Color(hex: 0x38BDF8, opacity: 0.06),
        backgroundBottom: Color(hex: 0x0EA5E9, opacity: 0.12),
        primaryText: .primary, secondaryText: .secondary,
        accent: Color(hex: 0x0EA5E9), success: Color(hex: 0x22C55E),
        warning: Color(hex: 0xEAB308), error: Color(hex: 0xDC2626),
        cardFill: Color(nsColor: .textBackgroundColor).opacity(0.62),
        cardStroke: Color(hex: 0x38BDF8, opacity: 0.24),
        glow: Color(hex: 0x38BDF8), glowOpacity: 0.12,
        cornerRadius: 18, borderWidth: 1, animationDuration: 0.14)
}

extension Color {
    /// 从 0xRRGGBB 整数构造 Color（内部主题目录用）。
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
