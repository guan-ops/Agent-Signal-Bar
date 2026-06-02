# Lamp Language

Agent Signal Bar v2 的状态栏灯语只回答一个问题：

```text
用户现在需不需要介入？
```

绿色表示正常，黄色表示需要注意，红色表示必须处理，灰色表示暂停或状态不可信。菜单栏当前灯效必须持续表达当前状态，不做只闪一下就结束的提示动画。

## Display States

| Display State | 含义 | 状态栏表现 |
| --- | --- | --- |
| `ready` | 空闲，系统正常 | 绿灯常亮 |
| `active` | Agent 正在运行 | 绿灯亮度+大小呼吸 |
| `completed` | 任务完成 | 绿色短闪并轻微缩放 |
| `needs_review` | 需要用户查看 | 黄灯慢闪并轻微缩放 |
| `permission` | 等待用户授权 | 红灯慢闪并轻微缩放 |
| `blocked` | 失败、阻塞、无法继续 | 红灯快闪 |
| `stale` | 状态可能过期或不可信 | 灰黄慢闪 |
| `paused` | 暂停监控 | 灰色静止 |

## Signal Mapping

保留现有 hook 和 CLI 的原始 signal 名称，但显示层统一映射到 display state。

| Signal / event | Display State |
| --- | --- |
| `idle`, `session_start`, `session_end`, `turn_end` | `ready` |
| `thinking`, `working`, `tool_done`, `subagent_start`, `subagent_stop` | `active` |
| `done`, successful `Stop` | `completed` |
| `attention`, `notification` | `needs_review` |
| `permission`, `permission_request` | `permission` |
| `blocked`, `failure`, `error`, `exception`, `max_tokens` | `blocked` |
| `stale` | `stale` |
| `off`, `pause`, `paused` | `paused` |

`active` 只能使用绿色动态，不出现黄色或红色。动态同时改变亮度和大小，灯位本身保持固定，避免状态栏布局抖动。运行详情单灯、极简圆点和经典灯牌都使用同一套亮度与大小呼吸曲线；经典灯牌只额外保留黑色灯牌外壳。`done` 默认是绿色 completed，不再是黄色。黄色只表示 needs review，红色只表示 permission 或 blocked。

`completed` 是短暂停留状态，默认 90 秒后自动回到 `ready`，可以用 `AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS` 覆盖。普通 active/warning session 过期仍会进入 `stale`，但 completed 过期代表“完成提示结束”，不会误报状态不可信。

Successful `Stop` events from Codex and Claude Code map to `done`. A following `SessionEnd` preserves completed and alert sessions, so the short completion hint is still visible until the completed TTL expires. A completed event does not downgrade an existing `needs_review` / `permission` / `blocked` / `stale` / `paused` session; those states keep priority until cleared or replaced by a stronger explicit event.

## Priority

多 session 聚合使用 display state 优先级：

```text
paused > blocked > permission > needs_review > stale > active > completed > ready
```

示例：

| Session A | Session B | 聚合结果 |
| --- | --- | --- |
| `active` | `ready` | `active` |
| `active` | `permission` | `permission` |
| `active` | `needs_review` | `needs_review` |
| `permission` | `blocked` | `blocked` |
| `completed` | `active` | `active` |
| `completed` | `ready` | `completed` |
| `stale` | `ready` | `stale` |
| `paused` | `active` | `paused` |

优先级只针对当前活跃 session 以及没有 session 时的 aggregate fallback。旧的 `paused` / `stale` aggregate 不会锁死后续事件；新的非暂停 session 写入后会恢复到对应的当前状态。

## Stale

`stale` 表示状态不可信。目前会在以下情况下出现：

- 状态 JSON 损坏或无法解码。
- session 超过 TTL 后被清理。
- 脚本显式写入 `stale`。

缺失的状态文件仍会显示 `ready`，因为这通常表示还没有 agent 写入状态。
