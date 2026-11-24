# Claude Code Setup

Agent Signal Bar 安装的 26 个 Claude Code hook 事件映射：

| Claude Code event | Signal |
| --- | --- |
| `ConfigChange` | `attention` |
| `CwdChanged` | `attention` |
| `Elicitation` | `attention` |
| `ElicitationResult` | `working` |
| `FileChanged` | `attention` |
| `InstructionsLoaded` | `attention` |
| `SessionStart` | `session_start` |
| `TaskCreated` | `subagent_start` |
| `TaskCompleted` | `subagent_stop` |
| `TeammateIdle` | `idle` |
| `UserPromptExpansion` | `thinking` |
| `UserPromptSubmit` | `thinking` |
| `PreToolUse` | `working` |
| `PostToolBatch` | `tool_done` |
| `PostToolUse` | `tool_done` |
| `PostToolUseFailure` | `tool_done` |
| `PreCompact` | `working` |
| `PostCompact` | `tool_done` |
| `SubagentStart` | `subagent_start` |
| `SubagentStop` | `subagent_stop` |
| `PermissionRequest` | `permission_request` |
| `PermissionDenied` | `blocked` |
| `Notification` | `notification` |
| `Stop` | `done` |
| `StopFailure` | `blocked` |
| `SessionEnd` | `session_end` |

不注册 `WorktreeCreate` 和 `WorktreeRemove`。它们接管工作树创建与清理，并非普通通知；`WorktreeCreate` 必须实际创建工作树并向 stdout 输出目录路径。状态灯脚本只报告状态，注册到这些事件会导致隔离会话报错或工作树无法正常清理。保留 Claude Code 默认的 git 工作树管理，其他 26 个事件照常监控。参见 [Claude Code 官方 Hook 文档](https://code.claude.com/docs/en/hooks#worktreecreate)。

普通 `Stop` 表示成功完成，会进入短暂的绿色 completed。紧随其后的 `SessionEnd` 会保留 completed 和需要处理的提示，只清理普通 active session。若当前 session 已经是 `permission`、`blocked` 或 `attention`，这个完成事件只会写入最近事件，不会覆盖仍需处理的提示。单个工具步骤失败（`PostToolUseFailure`，或 `PreToolUse`/`PostToolUse`/`PostToolBatch` 的 payload 带 `error`、非零 `exit_status` 等失败字段）不会亮红灯：错误会交回给 Agent，它会继续工作，例如 `grep` 未匹配返回 1。这类事件映射为 `tool_done`，并以「工具失败」保留在最近事件中。整轮失败仍是 `blocked`：`StopFailure`、`PermissionDenied`，以及非工具事件的 payload 带 `error`、`failure`、`exception`、非零 `exit_status` 等结构化失败字段。

事件名会做容错归一化，`PostToolUseFailure`、`post_tool_use_failure`、`post-tool-use-failure` 和 `post tool use failure` 都会映射到同一个 signal。
常见 payload 字段名也会容错归一化，例如 `session_id` / `sessionId`、`hook_event_name` / `hookEventName`、`exit_status` / `exitStatus`、`stop_reason` / `stopReason`。

`Stop` 的 `stop_reason` 也会做容错归一化：`max_tokens`、`max-tokens`、`max tokens` 都会映射为 `max_tokens` 阻塞；包含 `error` / `failure` / `exception` 的原因会映射为红色错误。

Claude Code 会把事件 JSON 传给 hook stdin，因此通常不需要把事件名作为命令参数。

## Desktop App vs Claude Code

Agent Signal Bar 的 `thinking` / `working` / `done` 状态来自 Claude Code hook 事件，例如 `UserPromptSubmit`、`PreToolUse` 和 `Stop`。Claude Desktop 的普通聊天窗口只表示 Claude.app 正在运行，不会把这些 Claude Code hook 事件发给 `~/.claude/settings.json`。

如果设置窗口显示 hook 已配置，但 Claude 仍然只显示“桌面版运行中”，先运行：

```bash
./script/doctor.sh
```

重点看两项：

- `Claude Code CLI not found in PATH`：当前终端环境没有可运行的 `claude` 命令，无法用 CLI 会话触发 hook。
- `Claude Desktop log says Claude Code requires a Pro or Max subscription`：Claude Desktop 没能启动 Claude Code/local-agent runtime；在这个状态下，普通 Claude 聊天不会产生 `thinking` / `working` hook 事件。

## Recommended Install

先安装 release 版 CLI，避免 hook 第一次触发时临时编译：

```bash
./script/install_cli.sh
```

预览并合并到现有 `~/.claude/settings.json`：

```bash
./script/install_hooks.py --target claude --dry-run
./script/install_hooks.py --target claude --install
```

安装脚本会保留已有 JSON 字段，只追加缺失的 Agent Signal Bar hook block，并在写入已有文件前生成 `settings.json.bak-YYYYmmddHHMMSS` 备份。如果发现旧路径的 `claude-code-signal-hook`，会迁移到当前 checkout 或当前 app bundle 的 wrapper 路径，避免同一个事件重复触发多个 Agent Signal Bar hook。

安装或修复时还会移除旧版本误加在 `WorktreeCreate` / `WorktreeRemove` 上的 Agent Signal Bar 命令；其他工具在这两个事件上的合法 Hook 会保留。`doctor.sh` 使用安装脚本的事件列表，并会报告这类残留注册。

## Manual Shape

通常不需要手写 JSON。若要手动配置，command 中的 wrapper 路径必须 shell-safe；路径含空格时要用单引号包住：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "'/path/to/AgentSignalLight/scripts/claude-code-signal-hook'",
            "timeout": 5
          }
        ],
        "matcher": ""
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "'/path/to/AgentSignalLight/scripts/claude-code-signal-hook'",
            "timeout": 10
          }
        ],
        "matcher": ""
      }
    ]
  }
}
```

完整事件列表以 `./script/install_hooks.py --target claude --dry-run` 输出为准。

## 应用内原生安装

“连接 → Claude Code Hook”的预览、安装和卸载由内置 Swift 安装器执行，无需安装 Python 或开发工具。安装会保留其他配置和其他工具的 Hook，修复旧路径，移除旧版误注册的 Worktree Hook，并在替换已有配置前备份；多目标操作失败会尝试回滚，遇到外部并发修改则报告错误而不覆盖它。

连接页会区分 Hook 未配置、配置需修复、配置读取失败及已配置但尚未收到事件。安装后请新建 Claude Code 会话并发送任务，以“最近事件”时间确认实际接入。普通 Claude 聊天不产生这些 Claude Code Hook 事件。

命令行可用随包 `agent-signal install-hooks --target claude --install`；增加 `--remove` 可卸载本应用的 Hook。Python 脚本安装方式仍可用于源码维护。
