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
            LoadingView(theme: theme, onCancel: { state.onCancel?() })
        case .streaming(let preview):
            StreamingPreviewView(preview: preview, theme: theme, onCancel: { state.onCancel?() })
        case .error(let msg):
            ErrorView(message: msg, theme: theme,
                      onRetry: { state.onRetry?() },
                      onSettings: { state.onOpenSettings?() },
                      onClose: { state.onClose?() })
        case .result(let result):
            ResultView(input: state.input, result: result, theme: theme,
                       onClose: { state.onClose?() })
        }
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
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("正在检查…").foregroundColor(theme.secondaryText)
            Button("取消", action: onCancel)   // .cancelAction 已移除：Esc 归 controller 折叠（design.md §2.3）
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// 流式「校对预览中」态：增量展示 corrected 前缀 + 已闭合结构化字段。
/// 红线：无词级 diff（依赖完整 corrected）、复制禁用（预览非最终真相）、可取消（继承 loading 语义）。
private struct StreamingPreviewView: View {
    let preview: StreamingPreview
    let theme: ReviewTheme
    let onCancel: () -> Void

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

            VStack(alignment: .leading, spacing: 14) {
                // corrected 逐字预览（打字机），复制禁用、无 diff 高亮。
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
                    if let s = preview.summaryZh, !s.trimmed.isEmpty {
                        Text(s).font(.caption).foregroundColor(theme.secondaryText)
                    }
                }
                // 已闭合的 issue 卡片按分区增量填充。
                if !preview.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("逐条说明").font(.caption).foregroundColor(theme.secondaryText)
                        ForEach(preview.issues) { issue in IssueCard(issue: issue, theme: theme) }
                    }
                }
            }
            .padding(14)

            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel)   // .cancelAction 已移除（同上）
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

private struct ErrorView: View {
    let message: String
    let theme: ReviewTheme
    let onRetry: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(theme.error)
            Text(message).multilineTextAlignment(.center).foregroundColor(theme.secondaryText)
            HStack {
                Button("重试", action: onRetry)
                Button("打开设置", action: onSettings)
                Button("关闭", action: onClose)   // 关闭 → 销毁 + cancel（唯一 cancel 路径）
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

private struct ResultView: View {
    let input: String
    let result: ReviewResult
    let theme: ReviewTheme
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
        HStack {
            Spacer()
            Button("关闭", action: onClose)   // .cancelAction 已移除：关闭只能点按钮/标题栏，Esc 归折叠
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
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
