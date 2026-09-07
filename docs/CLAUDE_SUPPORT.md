# Claude 支持

入口：设置 → 用量 → Claude。

## 账号与登录

仅保留 Claude Code 接入，已移除浏览器 Cookie 登录、来源切换及对应 Web API。旧版网页登录偏好会在初始化时清除，不影响 Claude Code 凭据授权。个人订阅授权需要 Pro 或 Max；Free 账号在官方授权页无法继续。

### Claude Code

点击“登录 Claude Code”会通过伪终端运行本机 CLI 的 `auth login --claudeai`，自动响应打开浏览器的回车提示，并等待 CLI 成功退出。完成授权后自动读取凭据、刷新账号与配额；无需再手动读取。登录等待上限 5 分钟，可取消，超时或失败不触发新的凭据读取。CLI 输出仅在有限内存中处理，不写日志。缺少 CLI 时显示“一键安装并登录”：从 Anthropic 官方地址下载安装器（只允许 HTTPS 和 claude.ai / downloads.claude.ai 跳转），运行 stable 安装，确认 ~/.local/bin/claude 可执行且 --version 成功后自动启动登录。安装在当前用户目录进行，不使用 sudo；下载安装失败不会启动登录，期间防止重复操作。自定义安装路径仍可在“接入设置”选择。“重新读取现有登录”保留为手动恢复入口。

应用只读 Claude Code 当前 OAuth 凭据，刷新令牌继续由 Claude Code 管理。默认从 macOS 钥匙串的 `Claude Code-credentials` 读取，条目不存在时读取 `~/.claude/.credentials.json`。配置 `CLAUDE_CONFIG_DIR` 时仅读取该目录的凭据，不跨配置回退到其他账号。后台读取不主动弹出钥匙串授权；登录成功后的首次读取或“重新读取现有登录”允许系统授权提示。“停止读取登录信息”会关闭后续凭据读取并清除本应用内存中的配额快照。

## 订阅配额

使用当前凭据请求 Claude OAuth usage/profile，展示可用的 5 小时、7 天、模型专项配额及重置时间；启用额外用量的账号会显示其金额与返回币种。刷新前后检查凭据身份，外部切换账号后旧请求不能覆盖新账号结果。缺失字段不显示为零；刷新失败明确标注旧快照。429 按凭据隔离退避，手动刷新不能跳过等待。

Claude Code 使用 OAuth。尚未移植交互式 `/usage` 回退。OAuth 到期时需由 Claude Code 完成重新认证。

## 多账号

可选启用已安装的 `claude-swap`（`cswap`），读取其 schemaVersion 1 JSON 账号列表。保存、添加和移除账号在 cswap 中完成；应用中点击“切换”才执行指定账号切换，并在完成后重新读取凭据和配额。切换期间禁用相关操作，等待 cswap 自然退出，避免超时中断外部凭据事务。未安装 cswap 不影响当前账号登录、配额和本地历史。

## Token 与费用

复用本地 Claude Code JSONL 扫描器，显示近 30 天 Token、估算费用、趋势及最近 7 天明细。包含缓存 Token 的现有计数/计价规则继续生效；未识别模型的未知费用不冒充零。这里是本机会话汇总，不能可靠归属于当前所选订阅账号，也不等于订阅账单。历史和配额使用独立来源，Claude 缓存与 Codex 缓存分离。扫描期间显示横向循环进度条，并保留上次结果；完成或失败后收起。当前扫描器不提供总工作量，因此不展示百分比。扫描失败保留上次结果并显示错误。

## 状态灯

复用已有 Claude Code Hook 和 Claude Desktop 监控。Claude 页可切换 Claude Code 状态灯范围和 Desktop 监控，并跳转“连接设置”管理 Hook。Hook 提供工作、等待授权、完成和阻塞状态；桌面进程监控只表示应用活动，不能推断会话是否完成。

## 实现来源与验证

以下记录包含已移除的网页登录功能的历史验证；当前版本仅保留 Claude Code。

参考仓库：[guan-ops/CodexBar](https://github.com/guan-ops/CodexBar/tree/1696c7a71c94747b99406d1458755e58b2d6bcc4)，固定提交 `1696c7a71c94747b99406d1458755e58b2d6bcc4`。ClaudeSwap 列表/切换解析器保留来源声明，MIT 许可位于 `Sources/AgentSignalLight/Resources/ClaudeSupport-LICENSE.txt`。界面与模型按 Agent Signal Bar 现有结构接入。

验证使用隔离临时目录、虚构账号、注入的 HTTP/凭据和本地日志 fixture，覆盖认证过期、配额解析、额外用量单位及币种、429 隔离、切换结果、账号变化后的旧响应丢弃、命令参数/超时、本地历史与读取失败。独立原生预览验证账号、配额、历史空状态和状态灯界面。网页登录新增隔离测试覆盖 Cookie 域/路径/过期、组织选择、账号信息、请求目的地、限流、失效/验证提示、凭据清除和取消后的响应丢弃。真实浏览器配额、真实 OAuth 返回及真实 cswap 切换仍须实测；本次不包含新版本发布。

网页数据源参考 `guan-ops/CodexBar` 提交 `4f760cfc9b5e1b9540ba35fbe976e15d24c3b5ae` 的 `ClaudeWebAPIFetcher.swift`，沿用上述 MIT 来源声明。

2026-09-08：ClaudeSupportTests 与 ClaudeWebSupportTests 共 24 项测试通过；重新编译启动，并在实际设置窗口确认网页登录、浏览器选择、读取入口和未登录空状态布局。用户已在 Chrome 登录；首次实际读取被 macOS 拒绝。系统设置“隐私与安全 → 文件与文件夹 → AgentSignalLight”中的 Google Chrome 开关为关闭，需用户授权后继续验证真实 Web 配额。

CLI 登录流程参考同一 CodexBar 提交的 `ClaudeLoginRunner.swift` 和 `Providers/Claude/ClaudeLoginFlow.swift`，保留 MIT 来源声明。浏览器 Cookie 权限不是此 CLI 登录流程的前置条件。

2026-09-08 CLI 自动登录增量验证：ClaudeLoginFlowTests、ClaudeSupportTests、ClaudeWebSupportTests 共 28 项通过，覆盖 TTY/带 ANSI 的回车提示、登录后自动读取配额、失败、超时和取消。重新编译启动成功；实际界面检查等待 macOS 文稿授权，真实 CLI 授权尚待安装 CLI 后验证。

2026-09-08 一键安装增量验证：31 项 Claude 相关测试通过，含临时目录中的实际安装脚本执行、stable 参数、可执行文件校验、HTML 错误页拒绝，以及安装结果到登录/配额的衔接。重新编译启动后，在实际设置页面点击“一键安装并登录”，成功通过官方安装器安装 Claude Code 2.1.236，并自动打开官方浏览器授权页。该页面明确提示连接 Claude Code 需要 Max 或 Pro，当前 Free 账号无法完成订阅 OAuth 授权；已用应用中的“取消登录”结束等待，界面恢复可登录状态。真实 OAuth 成功后的账号/配额仍未验证；网页版读取的 macOS 浏览器权限边界不变。CodexBar 此次参考的是其 ClaudeLoginRunner 登录流程，并未将其安装自身 codexbar CLI 的功能当作 Claude Code 安装器。

2026-09-08 接入简化验证：已删除 Claude 网页登录 UI、Cookie/Web API 服务及专属测试；保留 Codex 所需浏览器依赖。23 项 Claude Code 测试通过，包括旧 web 偏好清除后正常登录并读取配额的回归验证。重新编译启动后，实际设置窗口确认仅显示 Claude Code 登录与 Pro/Max 提示，Desktop 监控保留。真实付费账号 OAuth 配额尚未实测。
