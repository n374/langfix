<!-- doc-init template version: v1.0 -->
# ADR-0002: PopClip 用 Service action 触发

- **状态**: Accepted
- **日期**: 2026-06-29
- **Owner（决策者）**: n374
- **Reviewers**: n374
- **关联 change**: —
- **影响 capability**: grammar-review

## 1. 上下文

PopClip 把选中文本交给 LangFix 有多条路径，各有取舍：
- **URL action**：`langfix://check?text=***`，PopClip 自动 URL 编码选区。最简、可作 `#popclip` snippet 分享、无未签名警告；但长文本/特殊字符/URL 长度有边界风险。
- **Service action**：按名调用一个 macOS Service，PopClip 把纯文本作为输入发给它。无长度/编码坑、无临时文件、同样可 snippet 分享、无未签名警告；但 macOS Service 注册/可见性有摩擦（需 App 入 Launch Services、可能要 `pbs -update` 或重登）。
- **Shell Script action**：读 `POPCLIP_TEXT` 自由处理；但**未签名 shell 扩展会弹警告**，且要管临时文件。

> 事实依据（PopClip 官方）：Service action 由 `service name` 字段定义、发送选中纯文本、**不返回输出**；Service/URL/KeyPress 扩展可纯文本 snippet 分享且不触发未签名警告；Shell/AppleScript 未签名才弹警告。来源见 §备注。

两条路径的核心取舍：URL action 优先简单（短文本场景已够用），Service action 优先鲁棒（无编码坑、任意长度）。本项目把鲁棒性放在首位。

## 2. 决策

V1 采用 **PopClip Service action → macOS Service `Proofread with LangFix` → App**。

## 3. 理由

- 无 URL 长度/编码/换行的隐患，对任意长度文本稳健。
- 仍可作为纯文本 snippet 分享，且**不弹未签名警告**（优于 shell 方案）。
- Service「不返回输出」对我们无影响——LangFix 自行弹窗。
- 注册摩擦是一次性的，写进安装文档即可吸收。

## 4. 后果

- **正面**: 传输稳健、安装体验干净（无 shell 警告）。
- **负面**: 首次需处理 Service 注册可见性（`pbs -update`/重登）；调试比 URL scheme 稍繁。
- **中立**: `service name` 与 App `Info.plist` 的 `NSMenuItem.default` 必须严格一致。

## 5. 备选方案

| 方案 | 优点 | 缺点 | 为什么不选 |
|---|---|---|---|
| URL action | 最简、易调试、可分享 | 长文本/特殊字符/URL 长度风险 | 选鲁棒性更高的 Service；保留为回退 |
| Shell + 临时文件 + URL scheme | 完全可控、任意文本 | 未签名 shell 警告 + 临时文件清理 | 体验最差，仅作二次回退 |

> URL action 作为**首选回退**保留：若某环境 Service 注册始终不生效，可快速切到 `langfix://` scheme。

## 6. 实施

- App：`Info.plist` 声明 `NSServices`，注册 `servicesProvider`（见 [popclip-service.md](../architecture/modules/popclip-service.md)）。
- 扩展：提供 `#popclip` YAML snippet（`service name: Proofread with LangFix`）。
- 验收：spec R1（触发即出窗）、R8（空选区处理）。

## 7. 修订历史

| 日期 | 状态变更 | 摘要 |
|---|---|---|
| 2026-06-29 | → Accepted | 选 Service action；URL action 降为回退 |

## 备注：事实来源

- PopClip Dev Reference: https://www.popclip.app/dev/
- Service actions: https://www.popclip.app/dev/service-actions
- Script variables（`POPCLIP_TEXT` 等）: https://www.popclip.app/dev/script-variables
- Shell Script actions: https://www.popclip.app/dev/shell-script-actions
