import SwiftUI

struct ReviewView: View {
    @ObservedObject var state: ReviewState

    var body: some View {
        Group {
            switch state.phase {
            case .loading:
                LoadingView(onCancel: { state.onCancel?() })
            case .error(let msg):
                ErrorView(message: msg,
                          onRetry: { state.onRetry?() },
                          onSettings: { state.onOpenSettings?() },
                          onClose: { state.onClose?() })
            case .result(let result):
                ResultView(input: state.input, result: result, onClose: { state.onClose?() })
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }
}

private struct LoadingView: View {
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("正在检查…").foregroundColor(.secondary)
            Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
            Text(message).multilineTextAlignment(.center).foregroundColor(.secondary)
            HStack {
                Button("重试", action: onRetry)
                Button("打开设置", action: onSettings)
                Button("关闭", action: onClose)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ResultView: View {
    let input: String
    let result: ReviewResult
    let onClose: () -> Void

    @State private var copied = false

    private var segs: [DiffEngine.Seg] { DiffEngine.segments(input, result.corrected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    correctedBlock
                    if !segs.allSatisfy({ if case .same = $0 { return true } else { return false } }) {
                        diffBlock
                    }
                    if !result.issues.isEmpty { issuesBlock }
                    if let alt = result.alternative, !alt.trimmed.isEmpty { alternativeBlock(alt) }
                }
                .padding(14)
            }
            Divider()
            footer
        }
    }

    // MARK: 子区块

    private var header: some View {
        HStack(spacing: 8) {
            if result.overEdited {
                Label("AI 改动较大，请逐条核对", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.subheadline.bold())
            } else if result.hasIssues {
                Label("发现 \(result.issues.count) 处可改进", systemImage: "pencil.and.outline")
                    .foregroundColor(.accentColor).font(.subheadline.bold())
            } else {
                Label("无明显错误", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green).font(.subheadline.bold())
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var correctedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("修正结果").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(result.corrected, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            Text(result.corrected)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            if !result.summaryZh.trimmed.isEmpty {
                Text(result.summaryZh).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var diffBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("改动对照").font(.caption).foregroundColor(.secondary)
            diffText
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
        }
    }

    private var diffText: Text {
        segs.reduce(Text("")) { acc, seg in
            switch seg {
            case .same(let s): return acc + Text(s)
            case .delete(let s): return acc + Text(s).foregroundColor(.red).strikethrough()
            case .insert(let s): return acc + Text(s).foregroundColor(.green).bold()
            }
        }
    }

    private var issuesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("逐条说明").font(.caption).foregroundColor(.secondary)
            ForEach(result.issues) { issue in
                IssueCard(issue: issue)
            }
        }
    }

    private func alternativeBlock(_ alt: String) -> some View {
        DisclosureGroup("更地道的整体说法（非最小改动）") {
            Text(alt)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

private struct IssueCard: View {
    let issue: Issue
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(issue.category.badge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(4)
                Text(issue.severity.badge)
                    .font(.caption2)
                    .foregroundColor(severityColor)
                Spacer()
            }
            HStack(spacing: 4) {
                Text(issue.before).strikethrough().foregroundColor(.red)
                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                Text(issue.after).foregroundColor(.green)
            }
            .font(.callout)
            Text(issue.reasonZh).font(.caption).foregroundColor(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(6)
    }

    private var severityColor: Color {
        switch issue.severity {
        case .error: return .red
        case .improvement: return .orange
        case .optional: return .secondary
        }
    }
}
