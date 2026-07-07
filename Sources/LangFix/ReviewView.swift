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
                ScrollView {
                    content
                }
                .frame(maxHeight: maxContentSize.height, alignment: .topLeading)
            } else {
                content
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: maxContentSize.width, alignment: .topLeading)
        .background(theme.windowBackground)
        .animation(.easeOut(duration: theme.animationDuration), value: theme.id)
    }

    private var content: some View {
        ReviewContent(state: state, theme: theme)
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
            ResultView(input: state.input, result: result, theme: theme,
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

/// 中文直译行：小字、带「译」前缀，帮助中文母语用户核对修正后含义。
private struct TranslationLine: View {
    let text: String
    let theme: ReviewTheme
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.accent)
            Text(text)
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    let input: String
    let result: ReviewResult
    let theme: ReviewTheme
    let onHide: () -> Void
    let onClose: () -> Void

    @State private var copied = false

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
                if let alt = result.alternative, !alt.trimmed.isEmpty { alternativeBlock(alt) }
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
            ThemedCard(theme: theme) { diffText }
        }
    }

    private var diffText: Text {
        segs.reduce(Text("")) { acc, seg in
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
            ForEach(result.issues) { issue in
                IssueCard(issue: issue, theme: theme)
            }
        }
    }

    private func alternativeBlock(_ alt: String) -> some View {
        DisclosureGroup("更地道的整体说法（非最小改动）") {
            Text(alt)
                .textSelection(.enabled)
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .font(.caption)
        .foregroundColor(theme.secondaryText)
    }

    private var footer: some View {
        // 完成态：主操作合并为「关闭」（与流式态「停止」同一按钮位，随态切换文案/图标）。
        ReviewActionBar(theme: theme, onHide: onHide) {
            ActionChip(title: "关闭", systemImage: "xmark",
                       tint: theme.secondaryText, theme: theme, action: onClose)
        }
    }
}

private struct IssueCard: View {
    let issue: Issue
    let theme: ReviewTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(issue.category.badge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(theme.accent.opacity(0.15))
                    .cornerRadius(4)
                Text(issue.severity.badge)
                    .font(.caption2)
                    .foregroundColor(severityColor)
                Spacer()
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
        .cornerRadius(6)
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
