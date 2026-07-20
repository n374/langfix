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

    /// UI 语言 = 用户语言（切换选择器立即换语言，给用户直接反馈；language-config design D4/§8）。
    private var lang: AppLanguage { settings.userLanguage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                languageSection
                Divider()
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

    // MARK: 语言（置顶，language-config design D3/§8）

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(.settingsLanguageSection, lang)).font(.headline)

            // 未确认时的高亮横幅（design D3）：预填好选择器 + 显式「确认」；仅改选择器不算确认。
            if !settings.languageConfigured {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(L10n.t(.settingsLanguageConfirmBanner, lang))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L10n.t(.confirm, lang)) { settings.languageConfigured = true }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.5), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // 两个选择器互斥自动翻转（SettingsStore didSet 保证目标≠用户，不出现相同态）。
            field(L10n.t(.settingsUserLanguage, lang)) {
                Picker(L10n.t(.settingsUserLanguage, lang), selection: $settings.userLanguageRaw) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { l in
                        Text(l.nativeName).tag(l.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            field(L10n.t(.settingsTargetLanguage, lang)) {
                Picker(L10n.t(.settingsTargetLanguage, lang), selection: $settings.targetLanguageRaw) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { l in
                        Text(l.nativeName).tag(l.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(L10n.t(.settingsLanguageHint, lang))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 端点

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(.settingsEndpointSection, lang)).font(.headline)

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
                TextField(L10n.t(.settingsModelPlaceholder, lang), text: $settings.model)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(testing ? L10n.t(.settingsTesting, lang) : L10n.t(.settingsTestConnection, lang)) { runTest() }
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
        DisclosureGroup(L10n.t(.settingsAdvancedSection, lang), isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.t(.settingsStructuredOutput, lang), selection: $settings.structuredModeRaw) {
                    Text(L10n.t(.settingsStructuredAuto, lang)).tag(StructuredMode.auto.rawValue)
                    Text("json_schema").tag(StructuredMode.jsonSchema.rawValue)
                    Text("json_object").tag(StructuredMode.jsonObject.rawValue)
                    Text(L10n.t(.settingsStructuredText, lang)).tag(StructuredMode.text.rawValue)
                }
                slider("temperature", value: $settings.temperature, range: 0...1, fmt: "%.2f")
                slider(L10n.t(.settingsDiffThreshold, lang), value: $settings.diffThreshold, range: 0...1, fmt: "%.2f")
                stepperInt(L10n.t(.settingsMinWords, lang), value: $settings.minWordsForGuard, range: 1...50)
                stepperInt(L10n.t(.settingsMinAbsEdits, lang), value: $settings.minAbsEdits, range: 0...20)
                field(L10n.t(.settingsMaxChars, lang)) {
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
            field(L10n.t(.settingsTheme, lang)) {
                Picker(L10n.t(.settingsTheme, lang), selection: $settings.reviewThemeRaw) {
                    ForEach(ReviewThemeID.allCases) { id in
                        Text(ReviewThemeCatalog.theme(id).displayName).tag(id.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            // 字号档位：作用域仅结果浮窗文本区（设置页自身不缩放）；切换即时生效，同主题机制。
            field(L10n.t(.settingsFontSize, lang)) {
                Picker(L10n.t(.settingsFontSize, lang), selection: $settings.reviewFontTierRaw) {
                    ForEach(ReviewFontTier.allCases) { t in
                        Text(t.displayName(lang)).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            windowBehaviorSection
            Toggle(L10n.t(.settingsStreamingToggle, lang), isOn: $settings.streamingEnabled)
            Toggle(L10n.t(.settingsLaunchAtLogin, lang), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in setLaunchAtLogin(on) }
        }
    }

    private var windowBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t(.settingsWindowBehavior, lang)).font(.caption).foregroundColor(.secondary)
            VStack(spacing: 6) {
                ForEach(WindowBehaviorMode.allCases) { mode in
                    WindowBehaviorModeCard(
                        mode: mode,
                        language: lang,
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
            Label(L10n.t(.settingsPrivacyTitle, lang), systemImage: "lock.shield")
                .font(.caption.bold()).foregroundColor(.secondary)
            Text(L10n.t(.settingsPrivacyBody, lang))
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
            testResult = L10n.launchAtLoginFailed(error.localizedDescription, lang)
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
    let language: AppLanguage
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
                    Text(mode.title(language))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(mode.subtitle(language))
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
