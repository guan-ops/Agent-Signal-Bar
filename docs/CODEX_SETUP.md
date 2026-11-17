# Codex Setup

Codex hook 事件建议映射：

| Codex event | Signal |
| --- | --- |
| `SessionStart` | `session_start` |
| `UserPromptSubmit` | `thinking` |
| `PreToolUse` | `working` |
| `PostToolUse` | `tool_done` |
| `PermissionRequest` | `permission_request` |
| `Stop` | `done` |

普通 `Stop` 表示成功完成，会进入短暂的绿色 completed。Codex 当前公开 hook 事件不包含 `SessionEnd`，所以 Codex 侧完成态主要依赖 `Stop`；内部 CLI 和 Claude Code adapter 仍支持 `session_end`。若当前 session 已经是 `permission`、`blocked` 或 `attention`，这个完成事件只会写入最近事件，不会覆盖仍需处理的提示。如果 hook payload 中包含 `error`、`failure`、`exception`、非零 `exit_status` 等结构化失败字段，会映射为 `blocked`。

事件名会做容错归一化，`PreToolUse`、`pre_tool_use`、`pre-tool-use` 和 `pre tool use` 都会映射到同一个 signal。
常见 payload 字段名也会容错归一化，例如 `session_id` / `sessionId`、`hook_event_name` / `hookEventName`、`exit_status` / `exitStatus`。

## Codex Desktop

Codex Desktop 不需要手动安装 hook 也可以被 Agent Signal Bar 监控。Codex Desktop 当前线程可能不会执行 `.codex/hooks.json`，所以 Agent Signal Bar 内置了一个本地 Codex Desktop 监控器。它会读取 `~/.codex/sessions/**/*.jsonl` 中的本机事件：

| Codex Desktop session event | Signal |
| --- | --- |
| `reasoning` | `thinking` |
| `function_call` / `custom_tool_call` | `working` |
| `function_call_output` | `tool_done` |
| `task_complete` / `final_answer` | `done` |

这个监控只读本地 Codex session 文件，不上传数据。可以在 App 设置的 `通用` > `Agent 来源` 里用「监控 Codex Desktop」开关打开或关闭。普通浏览器使用不会触发 Agent Signal Bar；只有 Codex 任务本身在思考、调用工具或写入本地 session 日志时才会触发。

## Recommended Install

先安装 release 版 CLI，避免 hook 第一次触发时临时编译：

```bash
./script/install_cli.sh
```

Codex CLI/TUI 仍推荐项目级 hook，也就是当前仓库里的 `.codex/hooks.json`。先预览，再写入：

```bash
./script/install_hooks.py --target codex --codex-scope project --dry-run
./script/install_hooks.py --target codex --codex-scope project --install
```

如果你不是在项目 checkout 里运行，而是只想给独立安装包提供用户级退回配置，可以使用：

```bash
./script/install_hooks.py --target codex --codex-scope user --install
```

不建议同时启用项目级和用户级同一套 Agent Signal Bar hook；Codex 可能会对同一个事件执行两次，导致状态文件出现重复事件。

安装脚本会保留已有 JSON 字段，只追加缺失的 Agent Signal Bar hook block，并在写入已有文件前生成 `hooks.json.bak-YYYYmmddHHMMSS` 备份。如果发现旧路径的 `codex-signal-hook`，会迁移到当前 checkout 或当前 app bundle 的 wrapper 路径，避免同一个事件重复触发多个 Agent Signal Bar hook。项目级 `.codex/hooks.json` 含有本机路径，默认被 `.gitignore` 忽略。

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
            "command": "'/path/to/AgentSignalLight/scripts/codex-signal-hook' PreToolUse",
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
            "command": "'/path/to/AgentSignalLight/scripts/codex-signal-hook' PermissionRequest",
            "timeout": 10
          }
        ],
        "matcher": ""
      }
    ]
  }
}
```

完整事件列表以 `./script/install_hooks.py --target codex --codex-scope project --dry-run` 输出为准。

## 数据目录与连接检查

应用内“连接”页支持选择包含 `sessions` 文件夹的 Codex 数据目录。优先使用用户选择的路径，其次使用应用进程收到的 `CODEX_HOME`，最后使用 `~/.codex`。从 Finder 启动时若终端环境变量不可见，可直接选择目录。活动监控、Token 历史扫描和应用内 Codex Hook 安装共用该路径；目录选择不切换账号凭据。

“检查连接”会检查目录及 Hook 配置。目录不存在、不可读取、没有日志和已读取事件分别显示；已读取事件会显示最近事件时间。Hook 已配置并不表示已收到客户端事件，请在客户端发起一个任务确认。

应用内 Hook 的预览、安装、修复与卸载由内置 Swift 代码执行，不需要 Python。随包 CLI 也支持 `agent-signal install-hooks --target codex --install`。源码中的 Python 安装脚本仍作为开发维护工具保留。
