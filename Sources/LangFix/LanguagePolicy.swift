import Foundation

/// 语言默认与不变式的纯函数（language-config change · design D1/D2，可直接单测）。
enum LanguagePolicy {

    /// locale → 语言默认 truth table（proposal §5，确定性无歧义）：
    /// - `zh*` → (用户=中, 目标=英)
    /// - `en*` → (用户=英, 目标=中)
    /// - 其他（ja/de/…）→ (用户=英, 目标=中)
    static func defaults(forLocaleIdentifier id: String) -> (user: AppLanguage, target: AppLanguage) {
        if id.lowercased().hasPrefix("zh") { return (.chinese, .english) }
        return (.english, .chinese)
    }

    /// 不变式「目标语言 ≠ 用户语言」的确定性修复（design D1 第②③层）：
    /// 相等（手改 defaults / 脏数据）→ 目标语言强制翻转为另一语言，不 crash。
    static func normalized(user: AppLanguage, target: AppLanguage) -> (user: AppLanguage, target: AppLanguage) {
        target == user ? (user, user.other) : (user, target)
    }

    /// 持久化 rawValue → 合法语言对：非法 rawValue 按 locale 默认兜底，再走 normalized 修复相等态。
    static func sanitize(userRaw: String?, targetRaw: String?, localeIdentifier: String)
        -> (user: AppLanguage, target: AppLanguage) {
        let fallback = defaults(forLocaleIdentifier: localeIdentifier)
        let user = userRaw.flatMap(AppLanguage.init(rawValue:)) ?? fallback.user
        let target = targetRaw.flatMap(AppLanguage.init(rawValue:)) ?? user.other
        return normalized(user: user, target: target)
    }
}
