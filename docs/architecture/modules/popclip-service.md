<!-- doc-init template version: v1.0 -->
# Module: PopClipBridge / macOS Service

> **Owner**: n374
> 职责：把「PopClip 选中文本」可靠送进 LangFix。采用 PopClip **Service action** → macOS Service 路径（[ADR-0002](../../decisions/0002-popclip-service-action.md)）。

## 1. 机制总览

```
选中文本 → PopClip 弹条点击 LangFix 按钮
        → PopClip Service action（service name: "Proofread with LangFix"）
        → macOS Services 系统按名分发
        → LangFix.app 的 NSServices provider 收到纯文本
        → PopClipBridge.handle(text) → ReviewEngine.review(text)
```

要点（来自 PopClip 官方机制）：
- PopClip 的 **Service action** 由「存在 `service name` 字段」定义，会按名调用一个 macOS Service，并把**选中纯文本**作为输入发给该 Service。
- Service action **不接收任何返回值**——对我们无影响：LangFix 自己弹窗展示，不需要回传给 PopClip。
- **Service / URL / Key Press** 类扩展可作为纯文本 `#popclip` snippet 分享，且**不触发未签名警告**（Shell/AppleScript 扩展才会弹警告）。

来源：PopClip Dev Reference / Service actions / Script variables（见 [ADR-0002](../../decisions/0002-popclip-service-action.md) 引用）。

## 2. App 侧：注册 macOS Service

在 `Info.plist` 声明 `NSServices`：

```xml
<key>NSServices</key>
<array>
  <dict>
    <key>NSMenuItem</key>
    <dict>
      <key>default</key>
      <string>Proofread with LangFix</string>   <!-- PopClip service name 须与此一致 -->
    </dict>
    <key>NSMessage</key>
    <string>proofread</string>                    <!-- provider 方法名 -->
    <key>NSPortName</key>
    <string>LangFix</string>
    <key>NSSendTypes</key>
    <array>
      <string>NSStringPboardType</string>            <!-- 接收纯文本 -->
    </array>
    <key>NSRequiredContext</key>
    <dict/>                                           <!-- 不限制上下文 -->
  </dict>
</array>
```

Service provider（AppKit）。注意 `NSMessage` 值（`proofread`）决定 Objective-C selector 必须是 `proofread:userData:error:`，需用显式 `@objc(...)` 标注，`error` 为可空桥接指针：

```swift
final class ServiceProvider: NSObject {
    // selector 必须与 Info.plist 的 NSMessage 对应：proofread:userData:error:
    @objc(proofread:userData:error:)
    func proofread(_ pboard: NSPasteboard,
                      userData: String?,
                      error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        // 兼容读取：优先 .string，回退 legacy 类型
        let text = pboard.string(forType: .string)
            ?? pboard.string(forType: NSPasteboard.PasteboardType(rawValue: "NSStringPboardType"))
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            error?.pointee = "LangFix: 选区为空" as NSString
            return
        }
        DispatchQueue.main.async { PopClipBridge.shared.handle(t) }  // 主线程弹窗 + ReviewEngine
    }
}

// App 启动时注册（AppDelegate / App init）：
// NSApp.servicesProvider = ServiceProvider()
// NSUpdateDynamicServices()   // 提示系统刷新已注册服务
```

> `NSSendTypes` 用 `NSStringPboardType`（现代等价 `public.utf8-plain-text`）；上面对两种类型都做了读取兼容。

## 3. PopClip 扩展（snippet）

用户把下面这段存为纯文本，选中后由 PopClip 识别 `#popclip` 安装（无需 shell、无未签名警告）：

```yaml
# popclip
name: LangFix
icon: symbol:checkmark.seal           # 占位图标，可换
service name: Proofread with LangFix
requirements: [text]                  # 仅在有选中文本时出现
# 可选：限定只在特定 App 出现
# required apps: [com.tencent.xinWeChat, ru.keepcoder.Telegram, com.hnc.Discord]
```

> `service name` 必须与 App `Info.plist` 里 `NSMenuItem.default` **完全一致**。

## 4. 注册与可见性（已知摩擦点）

macOS Service 的注册由 Launch Services 扫描 App 的 `NSServices` 完成：

1. App 必须放在 Launch Services 可索引位置（如 `/Applications`）并**至少启动一次**。
2. 新注册的 Service 可能不会立刻出现，必要时：
   - `/System/Library/CoreServices/pbs -update`（刷新 Services 缓存；`pbs` 仅作**调试/排障工具**，正常安装流程不依赖它），或
   - 注销/重新登录一次。
   - 代码侧启动时调 `NSUpdateDynamicServices()` 主动提示刷新。
3. 即便没出现在「系统 Services 菜单」，只要已注册，PopClip 按名调用仍可成功。
4. 首次安装文档里需写明这一步，避免用户以为「按钮没反应」。

## 4.5 App 生命周期与冷拉起

产品入口是 PopClip，用户**经常会在 LangFix 未运行时**触发，必须定义此路径：

1. **冷拉起**：macOS Service 机制会在目标 App 未运行时**自动拉起**它再投递文本。LangFix 收到 Service 调用即完成「启动 → 注册 provider → 弹窗」。
2. **Launch at Login（推荐默认开）**：用 `SMAppService.mainApp`（macOS 13+）注册登录项，让 App 常驻、消除冷拉起延迟。设置页提供开关。
3. **延迟豁免**：spec NFR-1 的「<300ms 出窗」仅在**已常驻**时成立；**冷拉起首次**会有 App 启动开销（数百 ms～1s），此时不计入 300ms 指标，但应尽快出 loading 窗。
4. **失败提示**：若 App 因故无法拉起或 provider 未注册，Service 调用静默失败（PopClip Service action 无返回值，不会报错）。缓解：安装文档要求先启动一次 App + 开 Launch at Login；并在 App 内提供「自检/重新注册服务」按钮。

## 5. 备选/回退（不作为 V1 主路径）

若未来遇到 Service 注册环境问题，回退方案（记录备查，不实现）：
- PopClip **Shell Script action** 读 `POPCLIP_TEXT` → base64 写临时 inbox 文件 → `open "langfix://review?id=<uuid>"`，App 按 id 读取。代价：未签名 shell 警告 + 临时文件清理 + URL scheme。
- 详见 [ADR-0002](../../decisions/0002-popclip-service-action.md) 备选方案表。

## 6. 覆盖测试（待落地）

- Service provider 收到非空文本 → 触发 review：`TBD(unit: ServiceProvider.proofread 以模拟 pasteboard 调用，断言 PopClipBridge.handle 被调用)`
- 空选区 → 写回 error 且不触发：`TBD(unit: 空 pasteboard → error 非空、review 未触发)`

## 7. 关联

- 决策：[ADR-0002](../../decisions/0002-popclip-service-action.md)
- 需求：[spec R1/R8](../../specs/grammar-review/spec.md)
