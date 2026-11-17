# Claude 支持

入口：设置 → 用量 → Claude。

### 与 Codex 一致的用量页面

账号、会话配额、本机 Token 使用和项目／会话明细采用 Codex 页面的卡片层级、字体尺寸、圆角和折叠交互。登录、切换、重新读取和接入选项集中在账号卡片；较长的安装说明和状态灯设置放在“详情”。Claude 仅显示服务实际返回的配额窗口和额外用量，不构造 Codex 专属的重置额度。

今日费用、30 天费用及对应 Token 汇总与菜单使用同一个日历日投影，趋势图固定显示最近 30 个本地日历日，缺少记录的日期保留位置。未知费用与零费用区分，部分定价使用“≥”标记。可以展开每日／模型明细，以及按项目筛选、搜索的会话明细；Claude 的缓存读取与缓存写入分别计数，不能套用 Codex 的输入包含缓存规则。

本地历史扫描与网络配额请求并行推进；网络等待或账号变化不阻塞本机历史。账号相关请求仍在发布结果前后核对凭据身份，失败时只有能核实同一凭据所有者才保留旧配额。

默认历史源新增 Claude Desktop 两种代码会话目录中的 `.claude/projects`，以及 claude-swap 的本地会话目录；自定义 `CLAUDE_CONFIG_DIR` 作为单一路径处理，不按逗号拆分，也不跨配置回退。目录发现有深度与数量上限，不进入符号链接子目录。项目明细直接复用扫描器的请求去重与定价规则；项目路径仅从有匹配会话身份的有界日志头读取，不能从编码目录名猜测。Desktop 的普通聊天与非兼容 JSONL 格式不在此统计范围内。

连接检查现在识别 PATH、`~/.local/bin`、npm、bun 和 Homebrew 常见安装位置，也尊重用量页选择的 CLI。已发现 CLI 和桌面应用运行属于信息，不再导致正常 Hook 被显示为异常；真正的安装或授权问题保留为诊断。

此次参考了 [CodexBar ClaudeConfigPaths.swift](https://github.com/guan-ops/CodexBar/blob/main/Sources/CodexBarCore/Providers/Claude/ClaudeConfigPaths.swift)（读取内容的 Git blob：`ef8e05bc2405d09b26b083bf197c2dee1316bc8a`）和 [ClaudeDesktopProjectsLocator.swift](https://github.com/guan-ops/CodexBar/blob/main/Sources/CodexBarCore/Providers/Claude/ClaudeDesktopProjectsLocator.swift)（blob：`4b280acaaaa740eb71ced69589b9688dad10dde3`），并核对了 OAuth usage/profile 的请求与账号身份处理；沿用项目中的 MIT 声明。界面和本地明细使用本项目已有组件。2026-11-13 按用户新要求增加可选网页接入，见下文。

## 账号与登录

默认采用 Claude Code OAuth，也可选择 CLI、网页或自动回退。网页接入默认关闭；需要主动导入浏览器会话或填写 sessionKey，保存在本机钥匙串。旧版网页偏好不会自动重新启用。真实服务可返回的配额取决于账号与套餐。

### Claude Code

点击“登录 Claude Code”会通过伪终端运行本机 CLI 的 `auth login --claudeai`，自动响应打开浏览器的回车提示，并等待 CLI 成功退出。完成授权后自动读取凭据、刷新账号与配额；无需再手动读取。登录等待上限 5 分钟，可取消，超时或失败不触发新的凭据读取。CLI 输出仅在有限内存中处理，不写日志。缺少 CLI 时不再代为下载或运行安装器（2026-11-14 移除一键安装），只提示用户自行安装（`npm i -g @anthropic-ai/claude-code`）或选择已安装的可执行文件。自定义安装路径仍可在“接入设置”选择。“重新读取现有登录”保留为手动恢复入口。

应用只读 Claude Code 当前 OAuth 凭据，刷新令牌继续由 Claude Code 管理。默认从 macOS 钥匙串的 `Claude Code-credentials` 读取，条目不存在时读取 `~/.claude/.credentials.json`。配置 `CLAUDE_CONFIG_DIR` 时仅读取该目录的凭据，不跨配置回退到其他账号。后台读取不主动弹出钥匙串授权；登录成功后的首次读取或“重新读取现有登录”允许系统授权提示。“停止读取登录信息”会关闭后续凭据读取并清除本应用内存中的配额快照。

## 订阅配额

使用当前凭据请求 Claude OAuth usage/profile，展示可用的 5 小时、7 天、模型专项配额及重置时间；启用额外用量的账号会显示其金额与返回币种。刷新前后检查凭据身份，外部切换账号后旧请求不能覆盖新账号结果。缺失字段不显示为零；刷新失败明确标注旧快照。429 按凭据隔离退避，手动刷新不能跳过等待。

Claude Code 使用 OAuth。尚未移植交互式 `/usage` 回退。OAuth 到期时需由 Claude Code 完成重新认证。

## 多账号

可选启用已安装的 `claude-swap`（`cswap`），读取其 schemaVersion 1 JSON 账号列表。保存、添加和移除账号在 cswap 中完成；应用中点击“切换”才执行指定账号切换，并在完成后重新读取凭据和配额。切换期间禁用相关操作，等待 cswap 自然退出，避免超时中断外部凭据事务。未安装 cswap 不影响当前账号登录、配额和本地历史。

## Token 与费用

复用本地 Claude Code JSONL 扫描器，显示近 30 天 Token、估算费用、趋势以及可展开的逐日、模型、项目和会话明细。包含缓存 Token 的现有计数/计价规则继续生效；未识别模型的未知费用不冒充零。这里是本机会话汇总，不能可靠归属于当前所选订阅账号，也不等于订阅账单。历史和配额使用独立来源，Claude 缓存与 Codex 缓存分离。扫描期间显示横向循环进度条，并保留上次结果；完成或失败后收起。当前扫描器不提供总工作量，因此不展示百分比。扫描失败保留上次结果并显示错误。

## 状态灯

复用已有 Claude Code Hook 和 Claude Desktop 监控。Claude 页可切换 Claude Code 状态灯范围和 Desktop 监控，并跳转“连接设置”管理 Hook。Hook 提供工作、等待授权、完成和阻塞状态；桌面进程监控只表示应用活动，不能推断会话是否完成。

## 实现来源与验证

2026-10-30 用量页对齐验证：55 项受影响 Swift 测试通过（含在 WindowServer 环境中补测的原生菜单动态尺寸测试），13 项 Hook 安装脚本测试通过，脚本语法与 diff 静态检查通过。使用隔离账号、HTTP 返回和临时会话目录，覆盖本地历史不等待配额网络请求、日历日/DST 边界、未知费用、Desktop/claude-swap 目录发现、自定义配置隔离、项目/会话请求去重、缓存 Token 分项、取消以及连接信息解析；原生窗口完成深浅色渲染检查。本地 ZIP 包已构建，解压到临时目录后通过 ad-hoc 签名校验。当前环境会向工程目录中的 app 重新写入 FinderInfo，影响该位置的严格签名校验，因此保留 ZIP 包作为可复核构建。本轮未重启当前应用，未验证新进程中的真实 OAuth、真实账号切换或每种 Claude 宿主的完整事件链，不属于发布或公证验证。

以下为历史验证记录；旧版网页实现曾移除，2026-11-13 的可选网页实现需以本轮验证为准。

参考仓库：[guan-ops/CodexBar](https://github.com/guan-ops/CodexBar/tree/1696c7a71c94747b99406d1458755e58b2d6bcc4)，固定提交 `1696c7a71c94747b99406d1458755e58b2d6bcc4`。ClaudeSwap 列表/切换解析器保留来源声明，MIT 许可位于 `Sources/AgentSignalLight/Resources/ClaudeSupport-LICENSE.txt`。界面与模型按 Agent Signal Bar 现有结构接入。

验证使用隔离临时目录、虚构账号、注入的 HTTP/凭据和本地日志 fixture，覆盖认证过期、配额解析、额外用量单位及币种、429 隔离、切换结果、账号变化后的旧响应丢弃、命令参数/超时、本地历史与读取失败。独立原生预览验证账号、配额、历史空状态和状态灯界面。网页登录新增隔离测试覆盖 Cookie 域/路径/过期、组织选择、账号信息、请求目的地、限流、失效/验证提示、凭据清除和取消后的响应丢弃。真实浏览器配额、真实 OAuth 返回及真实 cswap 切换仍须实测；本次不包含新版本发布。

网页数据源参考 `guan-ops/CodexBar` 提交 `4f760cfc9b5e1b9540ba35fbe976e15d24c3b5ae` 的 `ClaudeWebAPIFetcher.swift`，沿用上述 MIT 来源声明。

2026-09-08：ClaudeSupportTests 与 ClaudeWebSupportTests 共 24 项测试通过；重新编译启动，并在实际设置窗口确认网页登录、浏览器选择、读取入口和未登录空状态布局。用户已在 Chrome 登录；首次实际读取被 macOS 拒绝。系统设置“隐私与安全 → 文件与文件夹 → AgentSignalLight”中的 Google Chrome 开关为关闭，需用户授权后继续验证真实 Web 配额。

CLI 登录流程参考同一 CodexBar 提交的 `ClaudeLoginRunner.swift` 和 `Providers/Claude/ClaudeLoginFlow.swift`，保留 MIT 来源声明。浏览器 Cookie 权限不是此 CLI 登录流程的前置条件。

2026-09-08 CLI 自动登录增量验证：ClaudeLoginFlowTests、ClaudeSupportTests、ClaudeWebSupportTests 共 28 项通过，覆盖 TTY/带 ANSI 的回车提示、登录后自动读取配额、失败、超时和取消。重新编译启动成功；实际界面检查等待 macOS 文稿授权，真实 CLI 授权尚待安装 CLI 后验证。

2026-09-08 一键安装增量验证：31 项 Claude 相关测试通过，含临时目录中的实际安装脚本执行、stable 参数、可执行文件校验、HTML 错误页拒绝，以及安装结果到登录/配额的衔接。重新编译启动后，在实际设置页面点击“一键安装并登录”，成功通过官方安装器安装 Claude Code 2.1.236，并自动打开官方浏览器授权页。该页面明确提示连接 Claude Code 需要 Max 或 Pro，当前 Free 账号无法完成订阅 OAuth 授权；已用应用中的“取消登录”结束等待，界面恢复可登录状态。真实 OAuth 成功后的账号/配额仍未验证；网页版读取的 macOS 浏览器权限边界不变。CodexBar 此次参考的是其 ClaudeLoginRunner 登录流程，并未将其安装自身 codexbar CLI 的功能当作 Claude Code 安装器。

2026-09-08 接入简化验证：已删除 Claude 网页登录 UI、Cookie/Web API 服务及专属测试；保留 Codex 所需浏览器依赖。23 项 Claude Code 测试通过，包括旧 web 偏好清除后正常登录并读取配额的回归验证。重新编译启动后，实际设置窗口确认仅显示 Claude Code 登录与 Pro/Max 提示，Desktop 监控保留。真实付费账号 OAuth 配额尚未实测。

## 2026-11-11 Claude 悬浮显示与账号操作对齐

菜单、设置页与悬浮灯共用同一 ClaudeSupportModel。灯的来源选为 Claude 时，额度角标显示选中窗口的剩余百分比，Token 角标使用 Claude 本机今日／近 30 天历史；切换到 Codex 时使用其独立数据，不跨平台回退。悬浮灯开启时，即使未打开用量页，也会按刷新间隔更新 Claude 历史；读取登录信息仍遵循原有用户授权设置。

额度详情列出服务实际返回的窗口，选择保存在独立的 Claude 偏好中。缺失窗口、未登录、切换中、读取失败、超过显示新鲜度或已过重置时间时，角标显示“—”；保留的历史额度仅在详情中明确标为上次结果。Token 未扫描与真实零值区分，未知费用仍使用原有“≥”规则。账号切换不清除设备级 Token 历史。

账号卡片将已保存账号列表移至主要操作区域，菜单和设置共用账号标签、激活规则。同邮箱账号可通过组织／slot 区分；过期或缺少凭据的账号显示恢复说明；API-key 或暂不可读取额度的账号仍可在来源允许时切换。账号源声明不支持切换时禁用操作。账号保存和移除仍由 claude-swap 管理，应用不新增凭据副本。

本轮参考 guan-ops/CodexBar 的 ClaudeScopedWeeklyLimitMapper、ClaudeSwapAccountProjection、ClaudeSwapAccountSwitch、ClaudeSwapAccountSource 和 OAuth limits 条目解析逻辑；版本定位与具体采用范围见 `audits/2026-11-11-claude-parity/evidence/codexbar-reference.json`。沿用 Resources/ClaudeSupport-LICENSE.txt 的 MIT 归属声明。未引入浏览器 Cookie 登录、TCR 或独立刷新 Claude OAuth 凭据的功能。

悬浮额度详情包含 5 小时、7 天、Sonnet／Opus／OAuth Apps 及服务返回的模型专项窗口，逐项可选且记住选择；较多窗口可滚动。账号套餐、来源、更新时间与额外用量也在详情中展示。额外用量保留服务返回币种；本机 Token 的估算费用共用 Codex 的显示币种与汇率设置，不混淆两者。Token 详情共用同一个视图，支持今日／近 30 天切换、刷新、估算费用与加载／失败提示。信息、额度、Token 角标继续共用点击、拖动换角、防重叠及缩放布局。

打包隔离验证发现并修正了 JSONL 格式兼容问题：旧扫描器会漏掉 `"type": "assistant"` 这种带空格的合法日志。现在在 JSON 解码后判断类型；Claude／Vertex 的缓存版本升至 v5，使旧版本漏算的记录重新参与统计，旧缓存文件不删除。验证结论和候选包定位见 [本轮核验报告](audits/2026-11-11-claude-parity/README.md)。


## 2026-11-13 CodexBar 功能对齐与可选网页来源

- 来源：OAuth 配额先显示，账号资料随后补充；CLI 通过独立工作目录被动读取 `/usage`，禁用工具、用户 Hook 与环境 MCP，默认仅手动刷新，后台探测需单独开启。自动顺序为 OAuth → 已启用 CLI → 已授权网页；HTTP 429 遵守等待时间。CLI 无法验证账号身份时不保存额度历史。
- 网页：在账号卡片的“详情”选择来源并启用网页接入，支持选择浏览器、主动导入和手动 Cookie。多组织账号需明确选择组织。读取真实返回的预充值余额、额外用量月预算、续费／到期日期；凭据不写入偏好或报告。网络验证、过期登录、关闭来源分别提示。关闭来源停止读取；“清除网页登录”删除该会话。
- 额度与角标：保留 5 小时、7 天及模型专项窗口，增加服务返回的 Routines/Cowork、限额重置次数与到期日、Cloud 赠送额度与到期日。无订阅窗口但有月预算时仍能显示；角标可选择自动窗口、月预算比例或预充值余额。月预算、预充值、Cloud credits 分开显示；未提供的值为未知。月初预算重置为推算并在界面注明，不作为服务确认。
- 提醒与历史：默认不发送通知。可开启低额度（设定阈值及 10%）、确认恢复／重置、预计重置前用尽提醒。通知授权只在主动开启时请求。额度历史按账号和来源隔离，验证后的账号 UUID 用于令牌轮换后续接；不按邮箱归并。历史保留最近 56 天并限制总量；不保存令牌、邮箱、grant ID 或对话。预测至少需要 3 次、跨 5 分钟的同周期递增样本，仅为估计。停止保存历史后提醒使用内存状态。
- 多账号：主账号和其他已保存账号可比较 5h、7d 与专项额度，展开查看重置；可用账号标星，只有明确点击切换才改动登录。隐藏个人信息同时作用于账户标签、邮件和组织名。
- Cowork：在有界 Desktop 会话目录发现 `audit.jsonl`，兼容 `request_id`/`session_id`，按请求 ID 或缺失请求 ID 时的会话＋消息 ID 去重。明确不同请求仍分别计数。显式 `stop_reason: null` 且仅有输入的代理记录保留为“不完整”，不当作完整 Token／费用；后续完整记录可替代。全不完整显示未知，混合记录显示已确认小计。缓存升级为 v6，不删除旧缓存。

本轮参考版本、实际测试和候选包见 [2026-11-13 核验报告](audits/2026-11-13-claude-codexbar-parity/README.md)。用户要求暂不登录，因此真实 OAuth、真实 CLI TUI、浏览器授权与网页线上字段尚未端到端验证。CLI 无法解析的自然语言重置日期保留原文，不编造时间；不会自动领取重置权益。普通 Desktop 聊天没有兼容用量日志时不计入 Token 统计。


## 2026-11-13 共用 Codex 用量界面

Claude 与 Codex 现在复用同一账号卡片、身份行、操作按钮、右侧详情折叠、配额块、Token 汇总和柱状图组件。页面统一按账户、会话、余额／权益、本机 Token、会话明细排列。Claude 多账号设置及比较进入账号详情和更多菜单；额度历史与提醒在会话区折叠展示，功能保留。详情展开状态由共同页面管理。见 [界面核验](audits/2026-11-13-shared-usage-ui/README.md)。


## 2026-11-13 菜单栏与悬浮界面统一

原生／详细菜单继续共用账号和 Token 区域，Claude 额度与更新时间现采用 Codex 的文案格式和排版。两边的悬浮额度、Token 面板复用背景、标题、刷新按钮和选择行；余额摘要也使用共用组件。Claude 专项窗口与各类余额保留，菜单中的多账号配置移至现有账号入口。长标题保留末尾百分比。见 [菜单与悬浮界面核验](audits/2026-11-13-shared-menu-floating-ui/README.md)。


## 2026-11-13 钥匙串静默读取

普通刷新及登录完成后不再主动请求读取 Claude Code 钥匙串授权。受保护凭据不可静默读取时暂停重试；手动“重新读取”也保持静默，只有账号详情中的“授权读取钥匙串…”允许弹出系统授权框。传统钥匙串交互限制与 LAContext 同时生效，完成后恢复当前进程原有设置。

不希望本应用读取该钥匙串条目时，可选“改用 CLI，不读取钥匙串”。此操作仅手动读取一次 CLI `/usage`；定期刷新需开启后台 CLI 选项。CLI 自身可能仍需登录／系统授权，且不能保证返回 Web 的全部字段。状态灯与本机 Token 统计不依赖该权限。见 [修复与验证](audits/2026-11-13-claude-silent-keychain/README.md)。

## 2026-11-14 请求标识与 CodexBar 对齐

参考 [steipete/CodexBar](https://github.com/steipete/CodexBar)（提交 `7447bc7`）的 `ClaudeOAuthUsageFetcher` 与 `ProviderVersionDetector`：OAuth usage 请求改为上报本机已安装的 Claude Code 版本（`claude-cli/<版本> (external, cli)`），不再固定为 2.1.0；可选清单参数被拒绝（400/404/422，或不含 `user:profile` 的 403）时以 `claude-code/<版本>` 重试一次。版本按可执行文件指纹缓存 30 分钟；仅在手动刷新或已开启后台 CLI 时才运行 `claude --version`，否则使用缓存或回退到 2.1.0。OAuth usage/profile 属于非公开接口，可能随时变更。

CodexBar 不内置 Claude Code 安装器（未找到 CLI 时仅提示用户自行安装），本项目据此移除了一键安装：删除 `ClaudeCLIInstaller` 及其测试，登录入口和详情页改为显示安装提示。下文 2026-09-08 的一键安装验证记录仅作历史保留。CodexBar 的子进程等待同样采用线程内轮询，本项目的轮询方式未改动。未用真实账号验证新的请求标识，也未在实际窗口中查看新的提示文案。
