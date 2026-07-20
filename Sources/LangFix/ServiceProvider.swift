import AppKit

/// macOS Service provider：被 PopClip Service action「Proofread with LangFix」按名调用。
/// selector 必须与 Info.plist 的 NSMessage（proofread）对应：proofread:userData:error:
final class ServiceProvider: NSObject {

    @objc(proofread:userData:error:)
    func proofread(_ pboard: NSPasteboard,
                   userData: String?,
                   error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        // 兼容读取：优先 .string，回退 legacy 类型。
        let text = pboard.string(forType: .string)
            ?? pboard.string(forType: NSPasteboard.PasteboardType(rawValue: "NSStringPboardType"))
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            // Services 回调在主线程派发；用户语言取自设置（极端非主线程兜底英文，不 crash）。
            let lang: AppLanguage = Thread.isMainThread
                ? MainActor.assumeIsolated { SettingsStore.shared.userLanguage } : .english
            error?.pointee = L10n.t(.serviceEmptySelection, lang) as NSString
            return
        }
        Task { @MainActor in
            AppCoordinator.shared.handleSelection(t)
        }
    }
}
