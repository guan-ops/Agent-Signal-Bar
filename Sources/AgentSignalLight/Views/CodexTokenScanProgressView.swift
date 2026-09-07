import SwiftUI

struct CodexTokenScanProgressView: View {
    @ObservedObject var model: MenuBarStatusModel

    var body: some View {
        if model.isTokenActivityLoading {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(stageText)
                    Spacer(minLength: 4)
                    if let progress = model.tokenActivityScanProgress, let fraction = progress.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                }.font(.caption).foregroundStyle(.secondary)
                ProgressView(value: model.tokenActivityScanProgress?.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(model.text("本地 Token 扫描进度", "Local token scan progress"))
            }
        } else if model.tokenActivityScanProgress?.phase == .complete,
                  let date = model.tokenActivityCompletedAt, model.tokenActivityIssue == nil {
            Label(model.text("扫描完成 100% · ", "Scan complete 100% · ") + date.formatted(date: .omitted, time: .shortened),
                  systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stageText: String {
        guard let progress = model.tokenActivityScanProgress else { return model.text("准备扫描…", "Preparing scan…") }
        switch progress.phase {
        case .discovering: return model.text("正在发现会话文件…", "Discovering session files…")
        case .scanning:
            return model.text("已检查 \(progress.completedFiles)/\(progress.totalFiles) 个文件", "Checked \(progress.completedFiles)/\(progress.totalFiles) files")
        case .validating: return model.text("正在核对并保存结果…", "Validating and saving results…")
        case .complete: return model.text("扫描完成", "Scan complete")
        }
    }
}
