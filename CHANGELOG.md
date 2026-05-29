# Changelog

[English](#103---2026-05-30) | [简体中文](#103---2026-05-30-简体中文)

## 1.0.3 - 2026-05-30

### Fixed

- Fixed fresh installs and first launch showing stale `Step Done` / `步骤完成` from previous Codex Desktop logs.
- Codex Desktop monitoring now starts from the current file position instead of replaying old session history.
- Step-complete runtime signals now expire back to idle promptly instead of lingering as an active session.

### Changed

- Refreshed README screenshots for solid and standard glass settings-window comparisons.

## 1.0.3 - 2026-05-30 简体中文

### 修复

- 修复新安装或首次启动时，会把旧 Codex Desktop 日志里的 `步骤完成` 显示成当前状态的问题。
- Codex Desktop 监控现在从当前日志位置开始读取，不再回放旧会话历史。
- `步骤完成` 这类过渡状态会更快回到空闲，不会长时间停留为运行中会话。

### 改进

- 更新 README 中普通背景和标准毛玻璃设置窗口的对比截图。

## 1.0.1 - 2026-05-30

### Added

- Added a settings-window glass effect option with an on/off switch.
- Added standard and enhanced glass styles for the settings window.
- Added lighter glass dropdown panels so menus remain readable without fully covering the content underneath.

### Changed

- Renamed the settings `Appearance` page to `Style`.
- Unified settings control widths for dropdowns, segmented controls, and action buttons.
- Made the settings header, tab bar, and content area use a consistent background treatment.

### Fixed

- Fixed an intermittent issue where clicking the menu bar signal light could also open the settings window.
- Fixed settings-window tab-bar color mismatch against the rest of the window.

## 1.0.1 - 2026-05-30 简体中文

### 新增

- 新增设置窗口毛玻璃效果开关。
- 新增设置窗口毛玻璃 `标准 / 增强` 两种样式。
- 设置里的下拉菜单改为更浅的毛玻璃效果，减少遮挡。

### 改进

- 设置里的 `外观` 页面更名为 `样式`。
- 统一设置里的下拉框、分段选择和操作按钮宽度。
- 统一设置窗口顶部、菜单栏和内容区的背景显示。

### 修复

- 修复点击状态栏信号灯时，偶尔会误打开设置窗口的问题。
- 修复设置窗口菜单栏与其他区域颜色不一致的问题。
