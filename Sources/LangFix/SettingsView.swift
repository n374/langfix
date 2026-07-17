import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var apiKey: String = KeychainStore.apiKey() ?? ""
    @State private var launchAtLogin: Bool = false
    @State private var testing = false
    @State private var testResult = ""
    @State private var testOK = false
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                endpointSection
                Divider()
                advancedSection
                Divider()
                generalSection
                Divider()
                privacyNote
            }
            .padding(18)
        }
        .frame(width: 460)
        .onAppear { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
    }

    // MARK: 端点

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 端点（OpenAI 兼容）").font(.headline)

            field("Base URL") {
                TextField("https://your-endpoint/v1", text: $settings.baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            field("API Key") {
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { newValue in
                        KeychainStore.setAPIKey(newValue)   // 红线：只进 Keychain
                    }
            }
            field("Model") {
                TextField("如 gpt-4o-mini / 某快模型", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(testing ? "测试中…" : "测试连接") { runTest() }
                    .disabled(testing)
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.caption)
                        .foregroundColor(testOK ? .green : .red)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: 高级

    private var advancedSection: some View {
        DisclosureGroup("高级（最小改动护栏 / 解码）", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("结构化输出", selection: $settings.structuredModeRaw) {
                    Text("auto（自动降级）").tag(StructuredMode.auto.rawValue)
                    Text("json_schema").tag(StructuredMode.jsonSchema.rawValue)
                    Text("json_object").tag(StructuredMode.jsonObject.rawValue)
                    Text("纯文本").tag(StructuredMode.text.rawValue)
                }
                slider("temperature", value: $settings.temperature, range: 0...1, fmt: "%.2f")
                slider("改动阈值 diffThreshold", value: $settings.diffThreshold, range: 0...1, fmt: "%.2f")
                stepperInt("护栏最小词数 minWordsForGuard", value: $settings.minWordsForGuard, range: 1...50)
                stepperInt("护栏最小编辑数 minAbsEdits", value: $settings.minAbsEdits, range: 0...20)
                field("输入上限 maxChars") {
                    TextField("", value: $settings.maxChars, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 弹窗主题：切换即时生效（@Published → 弹窗 SwiftUI 自动重绘），持久化到 UserDefaults。
            field("弹窗主题") {
                Picker("弹窗主题", selection: $settings.reviewThemeRaw) {
                    ForEach(ReviewThemeID.allCases) { id in
                        Text(ReviewThemeCatalog.theme(id).displayName).tag(id.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            // 字号档位：作用域仅结果浮窗文本区（设置页自身不缩放）；切换即时生效，同主题机制。
            field("字号（结果浮窗）") {
                Picker("字号", selection: $settings.reviewFontTierRaw) {
                    ForEach(ReviewFontTier.allCases) { t in
                        Text(t.displayName).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            windowBehaviorSection
            Toggle("流式渲染（逐字预览，端点不支持时自动回退）", isOn: $settings.streamingEnabled)
            Toggle("登录时启动（常驻，消除冷启动延迟）", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in setLaunchAtLogin(on) }
        }
    }

    private var windowBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("窗口行为").font(.caption).foregroundColor(.secondary)
            VStack(spacing: 6) {
                ForEach(WindowBehaviorMode.allCases) { mode in
                    WindowBehaviorModeCard(
                        mode: mode,
                        selected: settings.windowBehaviorMode == mode,
                        theme: settings.reviewTheme
                    ) {
                        settings.windowBehaviorModeRaw = mode.rawValue
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("隐私", systemImage: "lock.shield").font(.caption.bold()).foregroundColor(.secondary)
            Text("API key 仅存于 macOS Keychain；不记录原文与修正文。注意：选中文本与你的追问内容都会通过 HTTPS 发送到你配置的端点处理（非本地处理），敏感内容请自行选择可信端点。追问会话仅存于当前结果窗口的内存，关窗即清、不落盘。")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 动作

    private func runTest() {
        testing = true
        testResult = ""
        let cfg = SettingsStore.shared.config()
        Task {
            let (ok, msg) = await AIClient().probe(config: cfg)
            testing = false
            testOK = ok
            testResult = msg
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            testResult = "登录项设置失败：\(error.localizedDescription)"
            testOK = false
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: 小组件

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundColor(.secondary)
            content()
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: String) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 180, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue)).font(.caption.monospaced()).frame(width: 44)
        }
    }

    private func stepperInt(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(value.wrappedValue)").font(.caption.monospaced())
            }
        }
    }
}

private struct WindowBehaviorModeCard: View {
    let mode: WindowBehaviorMode
    let selected: Bool
    let theme: ReviewTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.iconName)
                    .frame(width: 22)
                    .foregroundColor(selected ? theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? theme.accent : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(theme.cardFill.opacity(selected ? 0.72 : 0.36))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? theme.accent : theme.cardStroke,
                            lineWidth: selected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
