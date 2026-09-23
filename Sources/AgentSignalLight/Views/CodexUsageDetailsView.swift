import SwiftUI

struct CodexUsageDetailsView: View {
    let details: CodexUsageDetails?
    let isLoading: Bool
    let text: (String, String) -> String
    let tokens: (Int) -> String
    @State private var query = ""
    @State private var selectedProject: String?
    @State private var projectsExpanded = false
    @State private var sessionsExpanded = false
    @State private var projectLimit = 3
    @State private var sessionLimit = 5

    private var projects: [CodexUsageDetails.Project] {
        (details?.projects ?? []).filter { query.isEmpty || ($0.path ?? text("未识别项目", "Unknown project")).localizedStandardContains(query) }
    }

    private var sessions: [CodexUsageDetails.Session] {
        (details?.sessions ?? []).filter { session in
            (selectedProject == nil || (session.projectPath ?? "") == selectedProject)
                && (query.isEmpty || ([session.id, session.projectPath ?? ""] + session.models)
                    .contains { $0.localizedStandardContains(query) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("项目与会话 · 近 30 天", "Projects & sessions · Last 30 days")).font(.headline)
                Spacer()
                if let date = details?.updatedAt {
                    Text(date, style: .time).foregroundStyle(.secondary)
                }
            }
            Text(text("本机 Codex 会话日志，按项目路径汇总；不归属于当前所选账号。仅包含已完成扫描的用量。",
                      "Local Codex session logs grouped by project path, across accounts. Only confirmed scanned usage is included."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if details == nil {
                Text(isLoading ? text("正在整理项目与会话…", "Loading projects and sessions…")
                     : text("完成一次本地扫描后显示明细。", "Details appear after a local scan completes."))
                    .foregroundStyle(.secondary)
            } else if details?.sessions.isEmpty == true {
                Text(text("近 30 天没有可统计的 Codex 会话。", "No Codex session usage in the last 30 days."))
                    .foregroundStyle(.secondary)
            } else {
                TextField(text("搜索项目、路径、会话 ID 或模型", "Search project, path, session ID or model"), text: $query)
                    .textFieldStyle(.roundedBorder)
                DisclosureGroup(isExpanded: $projectsExpanded) {
                    projectSection.padding(.top, 6)
                } label: {
                    sectionLabel(text("项目", "Projects"), count: projects.count)
                }
                Divider()
                DisclosureGroup(isExpanded: $sessionsExpanded) {
                    sessionSection.padding(.top, 6)
                } label: {
                    sectionLabel(text("会话", "Sessions"), count: sessions.count)
                }
                Text(text("缓存 Token 已包含在输入中，不重复计入总量。费用按模型价格估算，并非订阅账单；≥ 表示仍有未定价用量。",
                          "Cached tokens are included in input, not added again. Costs are model-price estimates, not subscription charges; ≥ marks partially priced usage."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .disclosureGroupStyle(UsageDetailsDisclosureStyle(
            expandedText: text("已展开", "Expanded"), collapsedText: text("已收起", "Collapsed")))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: query) { _, value in
            projectLimit = 3
            sessionLimit = 5
            if !value.isEmpty { projectsExpanded = true; sessionsExpanded = true }
        }
        .onChange(of: selectedProject) { _, value in
            sessionLimit = 5
            if value != nil { sessionsExpanded = true }
        }
        .onChange(of: projectsExpanded) { _, expanded in
            if !expanded { projectLimit = 3 }
        }
        .onChange(of: sessionsExpanded) { _, expanded in
            if !expanded { sessionLimit = 5 }
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedProject != nil {
                Button(text("全部项目", "All projects")) { selectedProject = nil }
            }
            ForEach(projects.prefix(projectLimit)) { project in
                Button { selectedProject = selectedProject == project.id ? nil : project.id } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(project.path.map { URL(fileURLWithPath: $0).lastPathComponent }
                                 ?? text("未识别项目", "Unknown project"))
                                .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("\(tokens(project.totalTokens)) Token · \(cost(project.costUSD, partial: project.hasUnpricedUsage))")
                                .monospacedDigit()
                        }
                        Text(project.path ?? text("日志中未提供项目路径", "Project path unavailable in log"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Text(text("\(project.sessionCount) 个会话", "\(project.sessionCount) sessions"))
                            .foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedProject == project.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(project.path ?? text("未识别项目", "Unknown project"))
            }
            if projects.count > projectLimit {
                Button(text("显示更多项目", "Show more projects")) { projectLimit += 3 }
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedProject {
                Text(selectedProject.isEmpty ? text("未识别项目", "Unknown project") : selectedProject)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if sessions.isEmpty {
                Text(text("没有匹配的会话。", "No matching sessions.")).foregroundStyle(.secondary)
            }
            ForEach(sessions.prefix(sessionLimit)) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(text("会话 ", "Session ") + shortID(session.id)).fontWeight(.medium)
                            .help(session.id)
                        Spacer()
                        Text(cost(session.costUSD, partial: session.hasUnpricedUsage)).monospacedDigit()
                    }
                    Text(session.models.map { CodexModelPresentation.forModel($0).displayName }
                        .joined(separator: " · ")).lineLimit(2).foregroundStyle(.secondary)
                    Text(text("输入 \(tokens(session.inputTokens)) · 缓存 \(tokens(session.cachedTokens)) · 输出 \(tokens(session.outputTokens))",
                              "Input \(tokens(session.inputTokens)) · Cached \(tokens(session.cachedTokens)) · Output \(tokens(session.outputTokens))"))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let date = session.lastActivity {
                            Text(date, format: .dateTime.month().day().hour().minute())
                        } else {
                            Text(text("活动时间未记录", "Activity time unavailable"))
                        }
                        Spacer()
                        Text("\(tokens(session.totalTokens)) Token").monospacedDigit()
                    }.foregroundStyle(.secondary)
                }.textSelection(.enabled).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            if sessions.count > sessionLimit {
                Button(text("显示更多会话（剩余 \(sessions.count - sessionLimit)）",
                            "Show more sessions (\(sessions.count - sessionLimit) remaining)")) { sessionLimit += 5 }
            }
        }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }

    private func shortID(_ id: String) -> String {
        id.count > 24 ? "\(id.prefix(8))…\(id.suffix(8))" : id
    }

    private func cost(_ value: Double?, partial: Bool) -> String {
        guard let value else { return "—" }
        return (partial ? "≥ " : "") + value.formatted(.currency(code: "USD"))
    }
}

/// One button owns the entire header, so the arrow and label toggle exactly once.
struct UsageDetailsDisclosureStyle: DisclosureGroupStyle {
    let expandedText: String
    let collapsedText: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? expandedText : collapsedText)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
