# LangFix 安装与使用

> macOS 13+，需先装好 [PopClip](https://www.popclip.app/)。

## 1. 构建与安装

```bash
# 仅构建到 build/LangFix.app
./build.sh

# 构建 + 安装到 /Applications + 注册 macOS Service（推荐）
./build.sh install
```

`install` 会把 `LangFix.app` 拷到 `/Applications`，并执行 `lsregister` + `pbs -update`，让 macOS Service 能被 PopClip 调用。

## 2. 首次启动与配置

1. 启动 `/Applications/LangFix.app`（菜单栏出现 ✓ 图标，无 Dock 图标）。
2. 菜单栏图标 → **设置…**：
   - **Base URL**：你的 OpenAI 兼容端点根，如 `https://your-relay/v1`
   - **API Key**：只写入 macOS Keychain
   - **Model**：按你的端点填（建议「快、小」一档模型）
   - 点 **测试连接** 确认端点 + 模型可用
3. 打开 **登录时启动**，让 App 常驻、消除冷启动延迟。

## 3. 安装 PopClip 扩展（Service action）

打开 `popclip/LangFix.popclip.yaml`，**全选其内容**（以 `#popclip` 开头），PopClip 会弹出「安装扩展」。安装后选中任意文本即可看到 **LangFix** 按钮。

> 该扩展通过 `service name: Proofread with LangFix` 按名调用 App 注册的 macOS Service，无需 shell、不弹未签名警告。

## 4. 使用

任意 App 里选中你写的外语文本 → PopClip 弹条 → 点 **LangFix** → 浮窗给出最小改动修正、词级 diff、逐条中文解释，一键复制修正结果。

> 不依赖 PopClip 也能用：菜单栏 → **检查剪贴板文本**（先复制要检查的文本）。

## 5. 故障排查

- **PopClip 点了没反应 / Service 没注册**：
  - 确认 App 在 `/Applications` 且**至少启动过一次**；
  - 跑 `/System/Library/CoreServices/pbs -update`，或**注销重新登录**一次；
  - 用菜单「检查剪贴板文本」验证 App 本身是否正常。
- **提示「请先完成配置」**：去设置补齐 Base URL / API Key / Model。
- **鉴权失败 / 模型不可用**：用设置里的「测试连接」定位是 key 还是 model 的问题。

## 6. 隐私

- API key 仅存 macOS Keychain；不记录原文与修正文。
- 注意：选中文本会通过 HTTPS 发送到**你配置的端点**处理（非本地处理），敏感内容请自行选择可信端点。
