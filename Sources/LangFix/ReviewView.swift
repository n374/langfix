import SwiftUI

/// 内容自然尺寸上报（design.md §2.1b）：测的是内容 VStack 的自然尺寸，**不是 ScrollView viewport**。
private struct NaturalSizeKey: PreferenceKey {
    // 计算属性而非存储属性：避免 Swift 6 严格并发下的可变全局状态告警。
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        value = CGSize(width: max(value.width, n.width), height: max(value.height, n.height))
    }
}

struct ReviewView: View {
    @ObservedObject var state: ReviewState
    /// 观察设置以实现主题「切换即时生效」（@Published → 自动重绘）。
    @ObservedObject private var settings = SettingsStore.shared
    /// 屏幕相对内容上限（controller 注入）：超上限维度由外层 ScrollView 内部滚动承载。
    var maxContentSize: CGSize = CGSize(width: ReviewWindowSizing.minWidth, height: 700)
    /// 来自独立测量宿主的 overflow 判定。false 时显示树不包 ScrollView，结构上无纵向滚动条。
    var isOverflowing: Bool = false

    private var theme: ReviewTheme { settings.reviewTheme }

    var body: some View {
        Group {
            if isOverflowing {
                // 超上限走整体滚动；追问对话已并入主内容流（不再有内层固定高度容器），
                // 由这里的 ScrollViewReader 承载「新问答自动滚到底」（proxy 下传给追问区）。
                ScrollViewReader { proxy in
                    ScrollView {
                        content(scrollProxy: proxy)
                    }
                    .frame(maxHeight: maxContentSize.height, alignment: .topLeading)
                }
            } else {
                content(scrollProxy: nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: maxContentSize.width, alignment: .topLeading)
        .background(theme.windowBackground)
        .animation(.easeOut(duration: theme.animationDuration), value: theme.id)
    }

    private func content(scrollProxy: ScrollViewProxy?) -> some View {
        ReviewContent(state: state, theme: theme, scrollProxy: scrollProxy)
            .frame(maxWidth: maxContentSize.width, alignment: .leading)
    }
}

/// 独立测量宿主：与显示树解耦，永远无 ScrollView，专门产出内容自然尺寸。
struct ReviewMeasurementView: View {
    @ObservedObject var state: ReviewState
    @ObservedObject private var settings = SettingsStore.shared
    var maxContentSize: CGSize = CGSize(width: ReviewWindowSizing.minWidth, height: 700)
    var onNaturalSizeChange: (CGSize) -> Void = { _ in }

    private var theme: ReviewTheme { settings.reviewTheme }

    var body: some View {
        ReviewContent(state: state, theme: theme)
            .frame(maxWidth: maxContentSize.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { p in
                    Color.clear.preference(key: NaturalSizeKey.self, value: p.size)
                }
            )
            .onPreferenceChange(NaturalSizeKey.self, perform: onNaturalSizeChange)
    }
}

private struct ReviewContent: View {
    @ObservedObject var state: ReviewState
    let theme: ReviewTheme
    /// 外层 ScrollView 的 proxy（仅 overflow 显示态有值）：供追问区自动滚到底。measurement 态为 nil。
    var scrollProxy: ScrollViewProxy? = nil

    @ViewBuilder var body: some View {
        switch state.phase {
        case .loading:
            LoadingView(theme: theme,
                        onHide: { state.onHide?() },
                        onStop: { state.onStop?() })
        case .streaming(let preview):
            StreamingPreviewView(preview: preview, theme: theme,
                                 onHide: { state.onHide?() },
                                 onStop: { state.onStop?() })
        case .stopped(let preview):
            StoppedView(preview: preview, theme: theme,
                        onHide: { state.onHide?() },
                        onClose: { state.onClose?() })
        case .error(let msg):
            ErrorView(message: msg, theme: theme,
                      onRetry: { state.onRetry?() },
                      onSettings: { state.onOpenSettings?() },
                      onHide: { state.onHide?() },
                      onClose: { state.onClose?() })
        case .result(let result):
            ResultView(state: state, result: result, theme: theme, scrollProxy: scrollProxy,
                       onHide: { state.onHide?() },
                       onClose: { state.onClose?() })
        }
    }
}

// MARK: - 操作栏与按钮（design round4：合并 停止/关闭 + 隐藏；有设计感、匹配主题、不喧宾夺主）

/// 主题化「胶囊芯片」按钮：圆角描边 + 毛玻璃卡片填充 + hover 微亮，替代原生按钮。
/// tint 由语义决定（停止=warning、关闭/隐藏=次要文本、重试=accent），克制不抢戏。
struct ActionChip: View {
    let title: String
    let systemImage: String
    let tint: Color
    let theme: ReviewTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .medium, design: .rounded))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.cardFill.opacity(hovering ? 0.9 : 0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(hovering ? 0.6 : 0.3), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 底部统一操作栏：左「隐藏」，右侧承载各态主操作（停止/关闭/重试等）。
private struct ReviewActionBar<Trailing: View>: View {
    let theme: ReviewTheme
    let onHide: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            ActionChip(title: "隐藏", systemImage: "chevron.down",
                       tint: theme.secondaryText, theme: theme, action: onHide)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

// MARK: - 主题化卡片容器（复用：修正块 / diff 块 / issue 卡）

private struct ThemedCard<Content: View>: View {
    let theme: ReviewTheme
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardFill)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.cardStroke, lineWidth: theme.borderWidth))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct LoadingView: View {
    let theme: ReviewTheme
    let onHide: () -> Void
    let onStop: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                ProgressView()
                Text("正在检查…").foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            Divider()
            // loading 尚无内容可保留，「停止」退化为直接关闭（onStop 内部判定）。
            ReviewActionBar(theme: theme, onHide: onHide) {
                ActionChip(title: "停止", systemImage: "stop.fill",
                           tint: theme.warning, theme: theme, action: onStop)
            }
        }
    }
}

/// 流式「校对预览中」态：增量展示 corrected 前缀 + 已闭合结构化字段。
/// 红线：无词级 diff（依赖完整 corrected）、复制禁用（预览非最终真相）、可取消（继承 loading 语义）。
private struct StreamingPreviewView: View {
    let preview: StreamingPreview
    let theme: ReviewTheme
    let onHide: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部「校对预览中」徽标（finalizing 时文案切「定稿中」）。
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Label(preview.stage == .finalizing ? "定稿中…" : "校对预览中…",
                      systemImage: "text.cursor")
                    .foregroundColor(theme.accent).font(.subheadline.bold())
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            PreviewBody(preview: preview, theme: theme)
                .padding(14)

            Divider()
            // 流式中：「停止」= 停止输出、保留已有内容（onStop 冻结为 .stopped）。
            ReviewActionBar(theme: theme, onHide: onHide) {
                ActionChip(title: "停止", systemImage: "stop.fill",
                           tint: theme.warning, theme: theme, action: onStop)
            }
        }
    }
}

/// 用户主动停止后的部分结果：与流式预览同布局，但改为「已停止」徽标，主操作为「关闭」。
private struct StoppedView: View {
    let preview: StreamingPreview
    let theme: ReviewTheme
    let onHide: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("已停止（部分结果）", systemImage: "stop.circle")
                    .foregroundColor(theme.warning).font(.subheadline.bold())
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            PreviewBody(preview: preview, theme: theme)
                .padding(14)

            Divider()
            ReviewActionBar(theme: theme, onHide: onHide) {
                ActionChip(title: "关闭", systemImage: "xmark",
                           tint: theme.secondaryText, theme: theme, action: onClose)
            }
        }
    }
}

/// 流式预览 / 停止态共用的正文：corrected 预览 + 中文直译 + 总评 + 已闭合 issue 卡。
/// 复制禁用：预览/部分结果非最终真相（承接流式红线）。
private struct PreviewBody: View {
    let preview: StreamingPreview
    let theme: ReviewTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("修正预览").font(.caption).foregroundColor(theme.secondaryText)
                    Spacer()
                    Button("复制") {}.controlSize(.small).disabled(true)   // 预览期禁用复制
                }
                ThemedCard(theme: theme) {
                    Text(preview.corrected.isEmpty ? " " : preview.corrected)
                        .textSelection(.enabled)
                        .foregroundColor(theme.primaryText)
                }
                if let t = preview.translationZh, !t.trimmed.isEmpty {
                    TranslationLine(text: t, theme: theme)
                }
                if let s = preview.summaryZh, !s.trimmed.isEmpty {
                    Text(s).font(.caption).foregroundColor(theme.secondaryText)
                }
            }
            if !preview.issues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("逐条说明").font(.caption).foregroundColor(theme.secondaryText)
                    ForEach(preview.issues) { issue in IssueCard(issue: issue, theme: theme) }
                }
            }
        }
    }
}

/// 小提示行：左侧小图标 + 右侧小字说明（可复用）。
private struct HintLine: View {
    let text: String
    let systemImage: String
    let tint: Color
    let theme: ReviewTheme
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 中文直译行：小字、带「书」图标，帮助中文母语用户核对修正后含义。
private struct TranslationLine: View {
    let text: String
    let theme: ReviewTheme
    var body: some View {
        HintLine(text: text, systemImage: "character.book.closed", tint: theme.accent, theme: theme)
    }
}

private struct ErrorView: View {
    let message: String
    let theme: ReviewTheme
    let onRetry: () -> Void
    let onSettings: () -> Void
    let onHide: () -> Void
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(theme.error)
                Text(message).multilineTextAlignment(.center).foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            Divider()
            ReviewActionBar(theme: theme, onHide: onHide) {
                ActionChip(title: "打开设置", systemImage: "gearshape",
                           tint: theme.secondaryText, theme: theme, action: onSettings)
                ActionChip(title: "重试", systemImage: "arrow.clockwise",
                           tint: theme.accent, theme: theme, action: onRetry)
                ActionChip(title: "关闭", systemImage: "xmark",
                           tint: theme.secondaryText, theme: theme, action: onClose)
            }
        }
    }
}

private struct ResultView: View {
    @ObservedObject var state: ReviewState
    let result: ReviewResult
    let theme: ReviewTheme
    var scrollProxy: ScrollViewProxy? = nil
    let onHide: () -> Void
    let onClose: () -> Void

    @State private var copied = false
    /// 追问输入草稿。
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    /// 被引用修正卡片的短暂高亮序号（design UI-3）。
    @State private var highlightedIndex: Int?

    private var input: String { state.input }
    private var segs: [DiffEngine.Seg] { DiffEngine.segments(input, result.corrected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                correctedBlock
                if !segs.allSatisfy({ if case .same = $0 { return true } else { return false } }) {
                    diffBlock
                }
                if !result.issues.isEmpty { issuesBlock }
                if let alt = result.alternative, !alt.trimmed.isEmpty {
                    alternativeBlock(alt, reason: result.alternativeReasonZh)
                }
                if let session = state.followUp {
                    followUpArea(session)
                }
            }
            .padding(14)
            Divider()
            footer
        }
    }

    // MARK: 子区块

    private var header: some View {
        HStack(spacing: 8) {
            if result.overEdited {
                Label("AI 改动较大，请逐条核对", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(theme.warning).font(.subheadline.bold())
            } else if result.hasIssues {
                Label("发现 \(result.issues.count) 处可改进", systemImage: "pencil.and.outline")
                    .foregroundColor(theme.accent).font(.subheadline.bold())
            } else {
                Label("无明显错误", systemImage: "checkmark.seal.fill")
                    .foregroundColor(theme.success).font(.subheadline.bold())
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var correctedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("修正结果").font(.caption).foregroundColor(theme.secondaryText)
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(result.corrected, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            ThemedCard(theme: theme) {
                Text(result.corrected)
                    .textSelection(.enabled)
                    .foregroundColor(theme.primaryText)
            }
            if !result.translationZh.trimmed.isEmpty {
                TranslationLine(text: result.translationZh, theme: theme)
            }
            if !result.summaryZh.trimmed.isEmpty {
                Text(result.summaryZh).font(.caption).foregroundColor(theme.secondaryText)
            }
        }
    }

    private var diffBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("改动对照").font(.caption).foregroundColor(theme.secondaryText)
            ThemedCard(theme: theme) { styledDiff(segs) }
        }
    }

    /// 词级 diff 着色（删除红删除线 / 新增绿高亮），可复用给「修正结果」与「更地道说法」两处对照。
    private func styledDiff(_ segments: [DiffEngine.Seg]) -> Text {
        segments.reduce(Text("")) { acc, seg in
            switch seg {
            case .same(let s): return acc + Text(s).foregroundColor(theme.primaryText)
            case .delete(let s): return acc + Text(s).foregroundColor(theme.error).strikethrough()
            case .insert(let s): return acc + Text(s).foregroundColor(theme.success).bold()
            }
        }
    }

    private var issuesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("逐条说明").font(.caption).foregroundColor(theme.secondaryText)
            // 序号来源 = ReviewResult.numberedIssues 单一解析（模型 index 有效则采用、否则位置重排；
            // 与追问上下文同源 design D1）；点击卡片注入「修正 N」引用。
            ForEach(result.numberedIssues, id: \.issue.id) { pair in
                IssueCard(issue: pair.issue, theme: theme, index: pair.index,
                          onReference: state.followUp != nil ? { injectReference($0) } : nil,
                          highlighted: highlightedIndex == pair.index)
            }
        }
    }

    // MARK: 追问区（ai-followup change · design §4 UI-1..UI-6）

    @ViewBuilder
    private func followUpArea(_ session: FollowUpSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(theme.cardStroke.opacity(0.55)).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.caption2)
                Text("AI 追问").font(.caption)
                Spacer()
            }
            .foregroundColor(theme.secondaryText).opacity(0.72)
            if !session.turns.isEmpty || session.streaming != nil {
                // 并入主结果同一滚动流（无内层固定高度容器）；自动滚底由外层 scrollProxy 承载（user review #2）。
                FollowUpConversation(session: session, theme: theme, scrollProxy: scrollProxy,
                                     onReferenceTap: { highlightPulse($0) })
            }
        }
    }

    /// 点击修正卡 → 把「修正 N」注入草稿并聚焦输入框（design UI-3，不覆盖已有草稿）。
    private func injectReference(_ n: Int) {
        let token = "修正 \(n)"
        if draft.trimmed.isEmpty {
            draft = token + " "
        } else if !draft.contains(token) {
            draft += (draft.hasSuffix(" ") ? "" : " ") + token + " "
        }
        composerFocused = true
        highlightPulse(n)
    }

    private func highlightPulse(_ n: Int) {
        highlightedIndex = n
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if highlightedIndex == n { highlightedIndex = nil }
        }
    }

    /// 「更地道的整体说法」：round6 需求1/2 —— 不再折叠（DisclosureGroup 会被 Tab 焦点框选中致样式问题），
    /// 改为默认展开的普通区块；并像「修正结果」一样给出**改动对照 diff**（相对原始输入，标出地道版改了哪）
    /// 与一句中文说明，让用户直观看出该怎么改得更地道。
    private func alternativeBlock(_ alt: String, reason: String) -> some View {
        // diff 基准取原始 input：与上方「改动对照」同一基线（都相对你写的原文），两级修改可直接对比。
        let altSegs = DiffEngine.segments(input, alt)
        let hasDiff = !altSegs.allSatisfy { if case .same = $0 { return true } else { return false } }
        return VStack(alignment: .leading, spacing: 6) {
            Text("更地道的整体说法（非最小改动）").font(.caption).foregroundColor(theme.secondaryText)
            ThemedCard(theme: theme) {
                Text(alt)
                    .textSelection(.enabled)
                    .foregroundColor(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasDiff {
                Text("地道版改动对照（相对原文）").font(.caption2).foregroundColor(theme.secondaryText)
                ThemedCard(theme: theme) { styledDiff(altSegs) }
            }
            if !reason.trimmed.isEmpty {
                HintLine(text: reason, systemImage: "sparkles", tint: theme.accent, theme: theme)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let session = state.followUp {
            VStack(spacing: 0) {
                // composer 上沿即时提示（引用越界 / 硬超预算），软提示不阻断（design UI-6）。
                if let notice = session.composerNotice {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle").font(.caption2)
                        Text(notice).font(.caption2)
                        Spacer()
                    }
                    .foregroundColor(theme.warning)
                    .padding(.horizontal, 14).padding(.top, 8)
                }
                HStack(spacing: 8) {
                    ActionChip(title: "隐藏", systemImage: "chevron.down",
                               tint: theme.secondaryText, theme: theme, action: onHide)
                    composer(session)
                    ActionChip(title: "关闭", systemImage: "xmark",
                               tint: theme.secondaryText, theme: theme, action: onClose)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
        } else {
            // 无追问会话（理论上 result 态恒有；防御性回退）：主操作合并为「关闭」。
            ReviewActionBar(theme: theme, onHide: onHide) {
                ActionChip(title: "关闭", systemImage: "xmark",
                           tint: theme.secondaryText, theme: theme, action: onClose)
            }
        }
    }

    /// 追问输入框（design UI-2）：footer「隐藏」与「关闭」之间；Enter 发送；右侧按钮随态切换。
    @ViewBuilder
    private func composer(_ session: FollowUpSession) -> some View {
        HStack(spacing: 6) {
            TextField("追问本次修正，或输入“修正 2 …”", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(theme.primaryText)
                .focused($composerFocused)
                .onSubmit { submit(session) }
                .onChange(of: draft) { _ in
                    session.clearNotice()
                }
                .onChange(of: composerFocused) { focused in
                    state.composerFocused = focused
                }
            trailingButton(session)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.cardFill.opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.accent.opacity(composerFocused ? 0.55 : 0.22), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func trailingButton(_ session: FollowUpSession) -> some View {
        switch session.streaming?.stage {
        case .receiving, .finalizing:
            // 在途 → 停止（丢弃半截、不写历史，design D3）。
            iconButton("stop.fill", tint: theme.warning) { session.stopCurrent() }
        case .failed:
            // 失败 → 重试（复用同一问题与结果绑定）。
            iconButton("arrow.clockwise", tint: theme.error) { session.retry() }
        case nil:
            iconButton("paperplane.fill", tint: draft.trimmed.isEmpty ? theme.secondaryText : theme.accent) {
                submit(session)
            }
            .disabled(draft.trimmed.isEmpty)
        }
    }

    private func iconButton(_ system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 13, weight: .semibold)).foregroundColor(tint)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }

    private func submit(_ session: FollowUpSession) {
        let q = draft
        guard !q.trimmed.isEmpty, !session.isBusy else { return }
        session.ask(q)
        // 越界/硬超限时 ask 会置 composerNotice 且不发请求；此时保留草稿供用户修正。
        if session.composerNotice == nil {
            draft = ""
        }
    }
}

// MARK: - 追问对话（气泡列表 + 流式 Markdown + 自动滚底，design UI-1/UI-4/D9）

private struct FollowUpConversation: View {
    @ObservedObject var session: FollowUpSession
    let theme: ReviewTheme
    /// 外层整体 ScrollView 的 proxy（user review #2：追问并入主流，不再有内层滚动容器）。可能为 nil（内容未溢出时无需滚动）。
    var scrollProxy: ScrollViewProxy? = nil
    let onReferenceTap: (Int) -> Void

    var body: some View {
        // 无内层 ScrollView / 固定高度：气泡随主结果整体流式增长，由窗口自适应或外层滚动承载。
        VStack(alignment: .leading, spacing: 8) {
            ForEach(session.turns) { turn in
                UserBubble(text: turn.question, refs: turn.referencedIndices,
                           theme: theme, onReferenceTap: onReferenceTap)
                AIBubble(text: turn.answer, streaming: false, theme: theme)
            }
            if let s = session.streaming {
                UserBubble(text: s.question, refs: s.referencedIndices,
                           theme: theme, onReferenceTap: onReferenceTap)
                switch s.stage {
                case .failed:
                    FailedBubble(message: s.errorText ?? "回答中断", theme: theme) { session.retry() }
                case .receiving, .finalizing:
                    AIBubble(text: s.answer.isEmpty ? "正在回答…" : s.answer,
                             streaming: true, theme: theme)
                }
            }
            Color.clear.frame(height: 1).id(Self.bottomID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // onAppear 兜底：内容从「不溢出」增长到「溢出」时，外层带 ScrollViewReader 的树是**新建**的，
        // 旧树里触发过的 onChange 不会在新树重放 → 新树首次出现时主动滚到底，避免停在顶部（评审中风险）。
        .onAppear { DispatchQueue.main.async { scrollToBottom() } }   // 延到新树布局后再滚，锚点已就位
        .onChange(of: session.turns.count) { _ in scrollToBottom() }
        .onChange(of: session.streaming?.answer) { _ in scrollToBottom() }
        .onChange(of: session.streaming?.stage) { _ in scrollToBottom() }
    }

    private static let bottomID = "followup-bottom"
    private func scrollToBottom() {
        guard let proxy = scrollProxy else { return }   // 未溢出（无外层 ScrollView）时窗口自适应显示，无需滚动
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }
}

/// 修正引用 chip 行（气泡顶部，点击回滚/高亮对应卡片）。
private struct ReferenceChips: View {
    let refs: [Int]
    let theme: ReviewTheme
    let onTap: (Int) -> Void
    var body: some View {
        if !refs.isEmpty {
            HStack(spacing: 4) {
                ForEach(refs, id: \.self) { n in
                    Button { onTap(n) } label: {
                        Text("修正 \(n)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(theme.accent.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.accent.opacity(0.3), lineWidth: 1))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct UserBubble: View {
    let text: String
    let refs: [Int]
    let theme: ReviewTheme
    let onReferenceTap: (Int) -> Void
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 3) {
                ReferenceChips(refs: refs, theme: theme, onTap: onReferenceTap)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(theme.accent.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

private struct AIBubble: View {
    let text: String
    let streaming: Bool
    let theme: ReviewTheme
    var body: some View {
        // 固定对齐宽度（user review #3）：AI 气泡统一左对齐、填满可用宽度，不随单次回答长短抖动。
        HStack(alignment: .bottom, spacing: 2) {
            MarkdownText(raw: text, theme: theme)
            if streaming { TypingCursor(theme: theme) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardFill.opacity(0.68))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardStroke, lineWidth: theme.borderWidth))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct FailedBubble: View {
    let message: String
    let theme: ReviewTheme
    let onRetry: () -> Void
    var body: some View {
        // 与 AI 气泡同宽（左对齐填满），保持视觉一致（user review #3）。
        VStack(alignment: .leading, spacing: 6) {
            Label("回答中断", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold()).foregroundColor(theme.error)
            Text(message).font(.caption).foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ActionChip(title: "重试", systemImage: "arrow.clockwise",
                       tint: theme.accent, theme: theme, action: onRetry)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.error.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.error.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 流式打字机光标：细竖条，0.8s 闪烁（design UI-4）。
private struct TypingCursor: View {
    let theme: ReviewTheme
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(theme.accent.opacity(on ? 0.9 : 0.1))
            .frame(width: 2, height: 14)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on.toggle() }
            }
    }
}

/// 尽力 Markdown 渲染（design D8）：inline 语法 + 保留换行；解析失败回退纯文本，不报错、不闪。
private struct MarkdownText: View {
    let raw: String
    let theme: ReviewTheme
    var body: some View {
        Text(attributed)
            .font(.system(size: 12.5))
            .foregroundColor(theme.primaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var attributed: AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: raw, options: opts)) ?? AttributedString(raw)
    }
}

private struct IssueCard: View {
    let issue: Issue
    let theme: ReviewTheme
    /// 1-based 稳定序号（design D1）。`nil` = 流式预览态，不渲染可引用序号（spec「预览期不开放序号」）。
    var index: Int? = nil
    /// 点击卡片把「修正 N」注入追问输入框（design UI-3）。仅 `.result` 态提供。
    var onReference: ((Int) -> Void)? = nil
    /// 被引用高亮（design UI-3）：命中时描边加亮 + glow。
    var highlighted: Bool = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let index {
                    Text("修正 \(index)")
                        .font(.caption2.bold())
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accent.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.accent.opacity(0.36), lineWidth: 1))
                        .cornerRadius(5)
                }
                Text(issue.category.badge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(theme.accent.opacity(0.15))
                    .cornerRadius(4)
                Text(issue.severity.badge)
                    .font(.caption2)
                    .foregroundColor(severityColor)
                Spacer()
                if index != nil, hovering {
                    Image(systemName: "quote.bubble")
                        .font(.caption2).foregroundColor(theme.accent.opacity(0.8))
                }
            }
            HStack(spacing: 4) {
                Text(issue.before).strikethrough().foregroundColor(theme.error)
                Image(systemName: "arrow.right").font(.caption2).foregroundColor(theme.secondaryText)
                Text(issue.after).foregroundColor(theme.success)
            }
            .font(.callout)
            Text(issue.reasonZh).font(.caption).foregroundColor(theme.secondaryText)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardFill.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.accent.opacity(highlighted ? 0.75 : 0), lineWidth: highlighted ? 1.4 : 0)
        )
        .shadow(color: theme.glow.opacity(highlighted ? theme.glowOpacity : 0), radius: highlighted ? 10 : 0)
        .cornerRadius(6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { if index != nil { hovering = $0 } }
        .onTapGesture { if let index, let onReference { onReference(index) } }
        .animation(.easeOut(duration: 0.2), value: highlighted)
    }

    private var severityColor: Color {
        switch issue.severity {
        case .error: return theme.error
        case .improvement: return theme.warning
        case .optional: return theme.secondaryText
        }
    }
}

// MARK: - 折叠胶囊入口（三态视觉，design.md §2.5）

struct CollapsedReviewEntry: View {
    @ObservedObject var state: ReviewState
    @ObservedObject private var settings = SettingsStore.shared
    let behavior: WindowBehaviorMode
    let onExpand: () -> Void

    private var theme: ReviewTheme { settings.reviewTheme }
    private var status: CollapsedStatus { CollapsedStatus(state.phase) }

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                Image(systemName: status.iconName)
                    .symbolEffectPulseIfWorking(status == .working)
                Text(status.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if behavior == .alwaysOnTop {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.72)
                }
            }
            .foregroundColor(theme.collapsedForeground)
            .padding(.horizontal, 14)
            .frame(width: 148, height: 44)
            .background(theme.material)
            .overlay(Capsule().stroke(status.color(theme), lineWidth: 1.2))
            .shadow(color: status.color(theme).opacity(theme.glowOpacity), radius: 12)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: theme.animationDuration), value: status)
    }
}

private extension View {
    /// 进行中态呼吸动效：macOS 14+ 用 symbolEffect(.pulse)，旧系统降级为无动效（不做旋转/长弹性）。
    @ViewBuilder func symbolEffectPulseIfWorking(_ working: Bool) -> some View {
        if #available(macOS 14.0, *), working {
            self.symbolEffect(.pulse, options: .repeating)
        } else {
            self
        }
    }
}
