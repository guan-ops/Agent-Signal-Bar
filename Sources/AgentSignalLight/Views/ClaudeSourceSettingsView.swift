import SwiftUI
import AppKit

/// The two ways out of a silent Keychain read: switch to the CLI, or explicitly allow the read.
/// Shown in exactly one place at a time (see `credentialReadBlocked`).
struct ClaudeCredentialChoiceButtons: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var support: ClaudeSupportModel
    var body: some View {
        HStack {
            Button(model.text("改用 CLI，不读取钥匙串", "Use CLI without reading credentials")) { support.useCLIWithoutCredentialRead() }
            Button(model.text("授权读取钥匙串…", "Authorize Keychain access…")) { support.authorizeCredentialRead() }
        }
        .disabled(support.accountActionInProgress)
    }
}

struct ClaudeSourceSettingsView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var support: ClaudeSupportModel
    @State private var cookieDraft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(model.text("用量来源", "Usage source"), selection: $support.usageSource) {
                ForEach(ClaudeUsageSource.allCases, id: \.self) { source in
                    Text(model.localizedClaudeText(source.title)).tag(source)
                }
            }.onChange(of: support.usageSource) { _, _ in support.refresh(force: true) }
            if support.usageSource == .oauth || support.usageSource == .automatic {
                Text(model.text("刷新只尝试静默读取；需要授权时会停止，不会自动弹出密码框。", "Refresh only reads silently. Protected credentials stop the read instead of opening a password dialog."))
                    .font(.caption).foregroundStyle(.secondary)
                // While a read is blocked, the account card's message area offers these choices.
                if !support.credentialReadBlocked {
                    ClaudeCredentialChoiceButtons(model: model, support: support)
                }
            }
            if support.usageSource == .automatic {
                Toggle(model.text("OAuth 不可用时尝试 CLI", "Try CLI when OAuth is unavailable"), isOn: $support.cliFallbackEnabled)
                Text(model.text("顺序：Claude Code → 已启用的 CLI → 已授权的网页来源。各来源的数据独立显示。",
                                "Order: Claude Code → enabled CLI → authorized Web. Each source keeps its own data."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if support.usageSource == .cli || support.cliFallbackEnabled {
                Toggle(model.text("允许后台读取 CLI 用量", "Allow background CLI usage probes"), isOn: $support.cliBackgroundEnabled)
                Text(model.text("默认只在点击刷新时运行。CLI 自身仍可能要求登录或系统授权；状态灯和本机 Token 统计不依赖钥匙串。",
                                "By default, CLI runs only on Refresh. The CLI itself may require sign-in or system access. Lights and local token history do not need Keychain access."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(model.text("启用可选网页接入", "Enable optional Web access"), isOn: $support.webEnabled)
            if support.webEnabled {
                HStack {
                    Button(model.text("打开 Claude 网页登录", "Open Claude sign-in")) { NSWorkspace.shared.open(URL(string: "https://claude.ai/")!) }
                    Button(model.text("读取浏览器登录", "Read browser session")) { support.importWebSession() }
                        .disabled(support.accountActionInProgress)
                    if support.isImportingWeb { ProgressView().controlSize(.mini) }
                }
                Picker(model.text("浏览器", "Browser"), selection: $support.webBrowser) {
                    Text(model.text("自动查找", "Automatic")).tag("automatic")
                    Text("Chrome").tag("chrome"); Text("Safari").tag("safari")
                    Text("Edge").tag("edge"); Text("Firefox").tag("firefox")
                }
                Text(model.text("由你主动读取，系统可能请求浏览器数据或钥匙串权限。会话仅保存到本机钥匙串。",
                                "Reading is user initiated and may request browser or Keychain access. The session stays in this Mac's Keychain."))
                    .font(.caption).foregroundStyle(.secondary)
                if support.webOrganizations.count > 1 {
                    Picker(model.text("网页组织", "Web organization"), selection: $support.webOrganizationID) {
                        Text(model.text("请选择", "Choose an organization")).tag("")
                        ForEach(Array(support.webOrganizations.enumerated()), id: \.element.id) { index, organization in
                            Text(support.hidePersonalInfo ? model.text("组织 \(index + 1)", "Organization \(index + 1)") : organization.name).tag(organization.id)
                        }
                    }.onChange(of: support.webOrganizationID) { _, _ in support.refresh(force: true) }
                }
                DisclosureGroup(model.text("高级：手动会话", "Advanced: manual session")) {
                    SecureField("Cookie: sessionKey=…", text: $cookieDraft)
                    Button(model.text("保存并读取", "Save and read")) {
                        support.saveWebCookie(cookieDraft)
                        if support.webMessage == nil { cookieDraft = "" }
                    }.disabled(cookieDraft.isEmpty || support.accountActionInProgress)
                }
                Button(model.text("清除已保存的网页登录", "Forget saved Web session")) { support.forgetWebCookie(); cookieDraft = "" }
                if let message = support.webMessage {
                    Text(model.localizedClaudeText(message)).font(.caption).foregroundStyle(.orange)
                }
            }
        }.font(.caption).controlSize(.small)
    }
}
