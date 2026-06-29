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
            Toggle("登录时启动（常驻，消除冷启动延迟）", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in setLaunchAtLogin(on) }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("隐私", systemImage: "lock.shield").font(.caption.bold()).foregroundColor(.secondary)
            Text("API key 仅存于 macOS Keychain；不记录原文与修正文。注意：选中文本会通过 HTTPS 发送到你配置的端点处理（非本地处理），敏感内容请自行选择可信端点。")
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
