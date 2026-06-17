import AgentSignalLightCore
import AgentSignalLightUI
import Foundation

enum AppLanguage: String, CaseIterable {
    case system = "system"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"

    var displayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .zhHans:
            return "简体中文"
        case .zhHant:
            return "繁體中文"
        case .english:
            return "English"
        case .japanese:
            return "日本語"
        case .korean:
            return "한국어"
        case .spanish:
            return "Español"
        case .french:
            return "Français"
        case .german:
            return "Deutsch"
        case .portuguese:
            return "Português"
        }
    }

    var resolvedLanguage: AppLanguage {
        switch self {
        case .system:
            return Self.systemPreferredLanguage()
        default:
            return self
        }
    }

    static func systemPreferredLanguage(_ preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in preferredLanguages {
            let normalized = identifier
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()

            if normalized.hasPrefix("zh-hant")
                || normalized.hasPrefix("zh-tw")
                || normalized.hasPrefix("zh-hk")
                || normalized.hasPrefix("zh-mo")
            {
                return .zhHant
            }

            if normalized.hasPrefix("zh") {
                return .zhHans
            }

            if normalized.hasPrefix("ja") {
                return .japanese
            }

            if normalized.hasPrefix("ko") {
                return .korean
            }

            if normalized.hasPrefix("es") {
                return .spanish
            }

            if normalized.hasPrefix("fr") {
                return .french
            }

            if normalized.hasPrefix("de") {
                return .german
            }

            if normalized.hasPrefix("pt") {
                return .portuguese
            }

            if normalized.hasPrefix("en") {
                return .english
            }
        }

        return .english
    }
}

extension AppLanguage {
    var usesCompactLatinLayout: Bool {
        switch resolvedLanguage {
        case .english, .japanese, .spanish, .french, .german, .portuguese:
            return true
        case .system, .zhHans, .zhHant, .korean:
            return false
        }
    }
}

extension MenuBarStatusModel {
    func text(_ zhHans: String, _ english: String) -> String {
        AppLocalization.text(english, language: appLanguage, zhHans: zhHans)
    }

    func displayName(for signal: AgentSignal) -> String {
        AppLocalization.signalName(signal, language: appLanguage)
    }

    func humanAction(for signal: AgentSignal) -> String {
        AppLocalization.humanAction(signal.displayState, language: appLanguage)
    }

    func summary(for signal: AgentSignal) -> String {
        AppLocalization.summary(signal, language: appLanguage)
    }

    func displayName(for language: AppLanguage) -> String {
        if language == .system {
            return text("跟随系统", "Follow System")
        }

        return language.displayName
    }

    func displayName(for theme: AppTheme) -> String {
        switch theme {
        case .system:
            return text("跟随系统", "Follow System")
        case .light:
            return text("浅色", "Light")
        case .dark:
            return text("深色", "Dark")
        }
    }

    func displayName(for effect: SettingsGlassEffect) -> String {
        switch effect {
        case .reduced:
            return text("标准", "Standard")
        case .standard:
            return text("增强", "Enhanced")
        }
    }

    func displayName(for mode: StatusMenuMode) -> String {
        switch mode {
        case .detailed:
            return text("复杂", "Detailed")
        case .simple:
            return text("简约", "Simple")
        }
    }

    func displayName(for scale: FloatingSignalScale) -> String {
        switch scale {
        case .compact:
            return text("小", "Small")
        case .standard:
            return text("默认", "Default")
        case .large:
            return text("大", "Large")
        }
    }

    func displayName(for level: FloatingSignalSoundLevel) -> String {
        switch level {
        case .soft:
            return text("轻", "Soft")
        case .standard:
            return text("标准", "Standard")
        case .loud:
            return text("响", "Loud")
        }
    }

    func displayName(for sound: FloatingSignalCompletionSound) -> String {
        switch sound {
        case .off:
            return text("关闭", "Off")
        case .newZealandCrossing:
            return text("新西兰", "New Zealand")
        case .aiAurora:
            return text("清亮", "Bright")
        case .aiGlow:
            return text("柔和", "Soft")
        }
    }

    func displayName(for sound: FloatingSignalWaitingSound) -> String {
        switch sound {
        case .off:
            return text("关闭", "Off")
        case .newZealandCrossing:
            return text("新西兰", "New Zealand")
        case .aiTick:
            return text("短促", "Tick")
        case .aiOrbit:
            return text("圆润", "Round")
        }
    }

    func displayName(for sound: FloatingSignalAlertSound) -> String {
        switch sound {
        case .off:
            return text("关闭", "Off")
        case .defaultPulse:
            return text("脉冲", "Pulse")
        case .aiBeacon:
            return text("提醒", "Beacon")
        case .aiUrgent:
            return text("警示", "Alert")
        }
    }

    func displayName(for layout: TrafficSignalLayout) -> String {
        switch layout {
        case .horizontal:
            return text("横向", "Horizontal")
        case .vertical:
            return text("竖向", "Vertical")
        }
    }

    func displayName(for style: TrafficSignalStyle) -> String {
        switch style {
        case .trafficLight:
            return text("经典灯牌", "Classic Lamp")
        case .macOS:
            return text("极简圆点", "Minimal Dots")
        }
    }

    func displayName(for strength: MacOSBreathingStrength) -> String {
        switch strength {
        case .standard:
            return text("弱", "Soft")
        case .pronounced:
            return text("标准", "Standard")
        case .maximum:
            return text("强", "Strong")
        }
    }

    func displayName(for effect: ActiveSignalEffect) -> String {
        switch effect {
        case .greenBreathing:
            return text("绿灯呼吸", "Green breathe")
        case .greenSteady:
            return text("绿灯常亮", "Green steady")
        case .greenSlowFlash:
            return text("绿灯慢闪", "Green slow")
        case .greenFastFlash:
            return text("绿灯快闪", "Green fast")
        case .trafficCycle:
            return text("红黄绿依次亮灯", "R/Y/G sequence")
        }
    }

    func displayName(for speed: SignalEffectSpeed) -> String {
        switch speed {
        case .slow:
            return text("慢", "Slow")
        case .standard:
            return text("标准", "Standard")
        case .fast:
            return text("快", "Fast")
        }
    }

    func displayName(for effect: CompletedSignalEffect) -> String {
        switch effect {
        case .greenPulse:
            return text("绿灯慢闪", "Green slow")
        case .greenSteady:
            return text("绿灯常亮", "Green steady")
        case .yellowPulse:
            return text("黄灯慢闪", "Yellow slow")
        case .yellowSteady:
            return text("黄灯常亮", "Yellow steady")
        case .allSteady:
            return text("三灯全亮", "All steady")
        case .allPulse:
            return text("三灯同步闪", "All flash")
        }
    }

    func friendlyAgentName(_ rawValue: String?) -> String {
        guard let rawValue, !rawValue.isEmpty else { return "Agent" }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        switch normalized {
        case "codex", "codex-desktop", "codex-cli", "codex-ide", "codex-xcode",
             "codex-terminal", "terminal-codex", "codex-tui", "codex-shell",
             "idea-codex", "intellij-codex", "jetbrains-codex", "codex-idea",
             "codex-intellij", "codex-jetbrains", "codex-vscode", "vscode-codex",
             "xcode-codex":
            return "Codex"
        case "claude", "claude-code", "claude-desktop", "claude-cli",
             "claude-terminal", "terminal-claude", "claude-ide",
             "idea-claude", "intellij-claude", "jetbrains-claude":
            return "Claude"
        case "manual":
            return text("手动", "Manual")
        default:
            return rawValue
        }
    }

    func displayName(for scope: SignalLightAgentScope) -> String {
        switch scope {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .codexDesktop:
            return text("Codex 桌面版", "Codex Desktop")
        case .codexCLI:
            return text("Codex 终端", "Codex CLI")
        case .codexVSCode:
            return "Codex VS Code"
        case .codexXcode:
            return "Codex Xcode"
        case .codexIDEA:
            return "Codex IDEA"
        case .claudeCode:
            return text("Claude 桌面版", "Claude Desktop")
        case .claudeDesktop:
            return "Claude Desktop"
        case .localScript:
            return text("本地脚本", "Local Script")
        }
    }

    func displayName(for scopes: Set<SignalLightAgentScope>) -> String {
        let selectableScopes = Set(SignalLightAgentScope.selectableCases)
        let normalizedScopes = scopes.intersection(selectableScopes)

        if normalizedScopes.isEmpty {
            return text("选择 Agent", "Select Agent")
        }

        if normalizedScopes == selectableScopes {
            return text("全部 Agent", "All Agents")
        }

        if normalizedScopes == SignalLightAgentScope.codexCases {
            return "Codex"
        }

        if normalizedScopes == SignalLightAgentScope.claudeCases {
            return "Claude"
        }

        if normalizedScopes.count == 1,
           let scope = normalizedScopes.first {
            return displayName(for: scope)
        }

        return text("已选 \(normalizedScopes.count) 个", "\(normalizedScopes.count) selected")
    }

    func displayName(for group: SignalLightAgentScopeGroup) -> String {
        switch group {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .other:
            return text("其他 Agent", "Other Agents")
        }
    }

    func friendlyEventName(_ rawValue: String) -> String {
        if rawValue.hasPrefix("DesktopToolCall:") {
            let toolName = String(rawValue.dropFirst("DesktopToolCall:".count))
            switch appLanguage.resolvedLanguage {
            case .system:
                return "Running step \(toolName)"
            case .zhHans:
                return "正在执行步骤 \(toolName)"
            case .zhHant:
                return "正在執行步驟 \(toolName)"
            case .japanese:
                return "ステップ実行中 \(toolName)"
            case .korean:
                return "단계 실행 중 \(toolName)"
            case .spanish:
                return "Ejecutando paso \(toolName)"
            case .french:
                return "Execution de l'etape \(toolName)"
            case .german:
                return "Schritt wird ausgefuehrt \(toolName)"
            case .portuguese:
                return "Executando etapa \(toolName)"
            case .english:
                return "Running step \(toolName)"
            }
        }

        switch rawValue {
        case let value where value.hasPrefix("PreToolUse:"):
            return "\(text("正在执行步骤", "Running Step")) \(String(value.dropFirst("PreToolUse:".count)))"
        case let value where value.hasPrefix("PostToolUse:"):
            return "\(text("步骤完成", "Step Done")) \(String(value.dropFirst("PostToolUse:".count)))"
        case let value where value.hasPrefix("PostToolUseFailure:"):
            return "\(text("工具失败", "Tool Failed")) \(String(value.dropFirst("PostToolUseFailure:".count)))"
        case "ConfigChange":
            return text("配置变化", "Config Changed")
        case "CwdChanged":
            return text("目录变化", "Directory Changed")
        case "Elicitation":
            return text("请求输入", "Input Requested")
        case "ElicitationResult":
            return text("输入返回", "Input Returned")
        case "FileChanged":
            return text("文件变化", "File Changed")
        case "InstructionsLoaded":
            return text("指令加载", "Instructions Loaded")
        case "SessionStart":
            return text("开始", "Started")
        case "TaskCreated":
            return text("任务创建", "Task Created")
        case "TaskCompleted":
            return text("任务完成", "Task Completed")
        case "TeammateIdle":
            return text("队友空闲", "Teammate Idle")
        case "UserPromptExpansion":
            return text("扩展任务", "Prompt Expanded")
        case "UserPromptSubmit":
            return text("收到任务", "Prompt Received")
        case "PreToolUse":
            return text("正在执行步骤", "Running Step")
        case "PostToolBatch":
            return text("工具批次完成", "Tool Batch Done")
        case "PostToolUse":
            return text("步骤完成", "Step Done")
        case "PostToolUseFailure":
            return text("工具失败", "Tool Failed")
        case "PreCompact":
            return text("整理上下文", "Compacting")
        case "PostCompact":
            return text("上下文整理完成", "Compacted")
        case "SubagentStart":
            return text("子 Agent 开始", "Subagent Started")
        case "SubagentStop":
            return text("子 Agent 完成", "Subagent Done")
        case "PermissionRequest":
            return text("等待授权", "Waiting for Permission")
        case "PermissionDenied":
            return text("授权被拒绝", "Permission Denied")
        case "Notification":
            return text("通知", "Notification")
        case "Stop":
            return text("完成", "Done")
        case "StopFailure":
            return text("停止失败", "Stop Failed")
        case "WorktreeCreate":
            return text("创建工作区", "Worktree Created")
        case "WorktreeRemove":
            return text("移除工作区", "Worktree Removed")
        case "SessionEnd":
            return text("会话结束", "Session Ended")
        case "ManualSet":
            return text("手动设置", "Manual Set")
        case "DesktopThinking":
            return text("思考中", "Thinking")
        case "DesktopToolDone":
            return text("步骤完成", "Step Done")
        case "DesktopMessage":
            return text("输出中", "Responding")
        case "DesktopTaskStarted":
            return text("思考中", "Thinking")
        case "DesktopActivityHeartbeat":
            return text("活动中", "Active")
        case "DesktopContextCompacted":
            return text("整理上下文", "Compacting Context")
        case "DesktopTaskComplete":
            return text("完成", "Done")
        case "DesktopTurnAborted":
            return text("已取消", "Canceled")
        case "DesktopAppRunning":
            return text("桌面版运行中", "Desktop app running")
        default:
            return rawValue
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        }
    }
}

private enum AppLocalization {
    static func text(_ english: String, language: AppLanguage, zhHans: String) -> String {
        let language = language.resolvedLanguage
        switch language {
        case .system:
            return english
        case .zhHans:
            return zhHans
        case .english:
            return english
        default:
            return uiText[english]?[language] ?? english
        }
    }

    static func signalName(_ signal: AgentSignal, language: AppLanguage) -> String {
        let language = language.resolvedLanguage
        if language == .zhHans {
            return signal.displayName
        }

        let english = englishSignalName(signal)
        if language == .english {
            return english
        }
        return signalNames[english]?[language] ?? english
    }

    static func humanAction(_ state: DisplayState, language: AppLanguage) -> String {
        let english: String
        let zhHans: String
        switch state {
        case .ready, .active, .completed:
            english = "No action needed"
            zhHans = "不用处理"
        case .needsReview:
            english = "Review when available"
            zhHans = "有空看一眼"
        case .permission, .blocked:
            english = "Needs action now"
            zhHans = "马上处理"
        case .stale:
            english = "Confirm status"
            zhHans = "确认状态"
        case .paused:
            english = "Monitoring paused"
            zhHans = "监控已暂停"
        }
        return text(english, language: language, zhHans: zhHans)
    }

    static func summary(_ signal: AgentSignal, language: AppLanguage) -> String {
        let language = language.resolvedLanguage
        if language == .zhHans {
            return signal.summary
        }

        let english = englishSignalSummary(signal)
        if language == .english {
            return english
        }
        return signalSummaries[english]?[language] ?? english
    }

    private static func localized(
        zhHant: String,
        ja: String,
        ko: String,
        es: String,
        fr: String,
        de: String,
        pt: String
    ) -> [AppLanguage: String] {
        [
            .zhHant: zhHant,
            .japanese: ja,
            .korean: ko,
            .spanish: es,
            .french: fr,
            .german: de,
            .portuguese: pt
        ]
    }

    private static let uiText: [String: [AppLanguage: String]] = [
        "General": localized(zhHant: "一般", ja: "一般", ko: "일반", es: "General", fr: "General", de: "Allgemein", pt: "Geral"),
        "Activity": localized(zhHant: "執行", ja: "実行", ko: "활동", es: "Actividad", fr: "Activite", de: "Aktivitaet", pt: "Atividade"),
        "Agent Activity": localized(zhHant: "Agent 執行詳情", ja: "Agent の実行状況", ko: "Agent 활동 세부 정보", es: "Actividad del Agent", fr: "Activite de l'agent", de: "Agent Aktivitaet", pt: "Atividade do Agent"),
        "Status": localized(zhHant: "狀態", ja: "状態", ko: "상태", es: "Estado", fr: "Etat", de: "Status", pt: "Status"),
        "Style": localized(zhHant: "樣式", ja: "スタイル", ko: "스타일", es: "Estilo", fr: "Style", de: "Stil", pt: "Estilo"),
        "Signals": localized(zhHant: "燈效", ja: "信号", ko: "신호", es: "Senales", fr: "Signaux", de: "Signale", pt: "Sinais"),
        "Effects": localized(zhHant: "燈效", ja: "エフェクト", ko: "등 효과", es: "Efectos", fr: "Effets", de: "Effekte", pt: "Efeitos"),
        "Connect": localized(zhHant: "連接", ja: "接続", ko: "연결", es: "Conectar", fr: "Connexion", de: "Verbinden", pt: "Conectar"),
        "Advanced": localized(zhHant: "進階", ja: "詳細", ko: "고급", es: "Avanzado", fr: "Avance", de: "Erweitert", pt: "Avancado"),
        "Advanced Settings": localized(zhHant: "進階設定", ja: "詳細設定", ko: "고급 설정", es: "Ajustes avanzados", fr: "Reglages avances", de: "Erweiterte Einstellungen", pt: "Configuracoes avancadas"),
        "About": localized(zhHant: "關於", ja: "情報", ko: "정보", es: "Acerca de", fr: "A propos", de: "Info", pt: "Sobre"),
        "Updated": localized(zhHant: "更新", ja: "更新", ko: "업데이트", es: "Actualizado", fr: "Mis a jour", de: "Aktualisiert", pt: "Atualizado"),
        "Live": localized(zhHant: "即時", ja: "ライブ", ko: "실시간", es: "En vivo", fr: "Direct", de: "Live", pt: "Ao vivo"),
        "Refresh": localized(zhHant: "重新整理", ja: "更新", ko: "새로고침", es: "Actualizar", fr: "Actualiser", de: "Aktualisieren", pt: "Atualizar"),
        "Live monitoring": localized(zhHant: "即時監控", ja: "ライブ監視", ko: "실시간 모니터링", es: "Supervision en vivo", fr: "Surveillance en direct", de: "Live Ueberwachung", pt: "Monitoramento ao vivo"),
        "sessions": localized(zhHant: "個會話", ja: "セッション", ko: "세션", es: "sesiones", fr: "sessions", de: "Sitzungen", pt: "sessoes"),
        "Active Sessions": localized(zhHant: "目前會話", ja: "現在のセッション", ko: "현재 세션", es: "Sesiones activas", fr: "Sessions actives", de: "Aktive Sitzungen", pt: "Sessoes ativas"),
        "Recent Events": localized(zhHant: "最近事件", ja: "最近のイベント", ko: "최근 이벤트", es: "Eventos recientes", fr: "Evenements recents", de: "Letzte Ereignisse", pt: "Eventos recentes"),
        "Recent Event": localized(zhHant: "最近事件", ja: "最近のイベント", ko: "최근 이벤트", es: "Evento reciente", fr: "Evenement recent", de: "Letztes Ereignis", pt: "Evento recente"),
        "Session": localized(zhHant: "會話", ja: "セッション", ko: "세션", es: "Sesion", fr: "Session", de: "Sitzung", pt: "Sessao"),
        "The status bar updates automatically when an agent reports activity.": localized(zhHant: "收到 Agent 事件後，狀態列會自動更新。", ja: "Agent のイベントで自動更新します。", ko: "Agent 이벤트를 받으면 상태 막대가 자동으로 업데이트됩니다.", es: "La barra se actualiza automaticamente cuando un Agent informa actividad.", fr: "La barre se met a jour quand un agent signale une activite.", de: "Die Statusleiste aktualisiert sich, wenn ein Agent Aktivitaet meldet.", pt: "A barra atualiza automaticamente quando um Agent relata atividade."),
        "No recent events yet": localized(zhHant: "尚無最近事件", ja: "イベントなし", ko: "최근 이벤트가 아직 없습니다", es: "Aun no hay eventos recientes", fr: "Aucun evenement recent", de: "Noch keine Ereignisse", pt: "Ainda sem eventos recentes"),
        "After connection, events from Codex, Claude Code, or other agents appear here.": localized(zhHant: "連接後，Codex、Claude Code 或其他 Agent 的事件會顯示在這裡。", ja: "接続後、Agent のイベントがここに表示されます。", ko: "연결 후 Codex, Claude Code 또는 다른 Agent의 이벤트가 여기에 표시됩니다.", es: "Tras conectar, aqui apareceran eventos de Codex, Claude Code u otros agentes.", fr: "Apres connexion, les evenements de Codex, Claude Code ou autres agents apparaissent ici.", de: "Nach der Verbindung erscheinen hier Ereignisse von Codex, Claude Code oder anderen Agents.", pt: "Depois de conectar, eventos do Codex, Claude Code ou outros agents aparecem aqui."),
        "Start at login": localized(zhHant: "登入時啟動", ja: "ログイン時に起動", ko: "로그인 시 시작", es: "Iniciar al entrar", fr: "Lancer a l'ouverture", de: "Beim Anmelden starten", pt: "Iniciar no login"),
        "Open Agent Signal Bar automatically after macOS login": localized(zhHant: "登入 macOS 後自動開啟 Agent Signal Bar", ja: "macOS ログイン後に Agent Signal Bar を自動で開きます", ko: "macOS 로그인 후 Agent Signal Bar를 자동으로 엽니다", es: "Abrir Agent Signal Bar automaticamente al iniciar sesion en macOS", fr: "Ouvrir Agent Signal Bar automatiquement apres la connexion macOS", de: "Agent Signal Bar nach der macOS Anmeldung automatisch oeffnen", pt: "Abrir Agent Signal Bar automaticamente apos login no macOS"),
        "Low power mode": localized(zhHant: "低功耗模式", ja: "低電力モード", ko: "저전력 모드", es: "Modo de bajo consumo", fr: "Mode economie d'energie", de: "Energiesparmodus", pt: "Modo de baixo consumo"),
        "Reduce background polling and animation refresh while the app stays running.": localized(zhHant: "降低背景輪詢和動畫更新頻率，適合長時間常駐。", ja: "常駐中のバックグラウンド確認とアニメーション更新を減らします。", ko: "앱이 계속 실행되는 동안 백그라운드 확인과 애니메이션 새로고침을 줄입니다.", es: "Reduce la comprobacion en segundo plano y la actualizacion de animaciones mientras la app sigue abierta.", fr: "Reduit les verifications en arriere-plan et le rafraichissement des animations pendant que l'app reste ouverte.", de: "Reduziert Hintergrundabfragen und Animationsaktualisierungen, waehrend die App weiterlaeuft.", pt: "Reduz a verificacao em segundo plano e a atualizacao das animacoes enquanto o app continua aberto."),
        "New Zealand": localized(zhHant: "紐西蘭", ja: "ニュージーランド", ko: "뉴질랜드", es: "Nueva Zelanda", fr: "Nouvelle-Zelande", de: "Neuseeland", pt: "Nova Zelandia"),
        "New Zealand original mode": localized(zhHant: "紐西蘭原版模式", ja: "ニュージーランド原版モード", ko: "뉴질랜드 원본 모드", es: "Modo original de Nueva Zelanda", fr: "Mode original neo-zelandais", de: "Neuseeland-Originalmodus", pt: "Modo original da Nova Zelandia"),
        "Use the original New Zealand pedestrian crossing cadence and switch completion and blink sounds to New Zealand.": localized(zhHant: "依照紐西蘭行人紅綠燈節奏慢閃，並將完成音和閃爍音切換為紐西蘭。", ja: "ニュージーランドの歩行者信号の周期を使い、完了音と点滅音をニュージーランドに切り替えます。", ko: "뉴질랜드 보행자 신호등 박자로 느리게 깜박이고 완료음과 깜박임음을 뉴질랜드로 바꿉니다.", es: "Usa la cadencia original del cruce peatonal de Nueva Zelanda y cambia los sonidos de finalizacion y parpadeo a Nueva Zelanda.", fr: "Utilise la cadence originale des passages pietons neo-zelandais et passe les sons de fin et de clignotement sur Nouvelle-Zelande.", de: "Nutzt den originalen Neuseeland-Takt fuer Fussgaengerampeln und stellt Abschluss- und Blinktoene auf Neuseeland um.", pt: "Usa a cadencia original das travessias de pedestres da Nova Zelandia e muda os sons de conclusao e piscar para Nova Zelandia."),
        "Open Agent": localized(zhHant: "開啟 Agent", ja: "Agent を開く", ko: "Agent 열기", es: "Abrir Agent", fr: "Ouvrir l'agent", de: "Agent oeffnen", pt: "Abrir Agent"),
        "Status Bar": localized(zhHant: "狀態列", ja: "ステータスバー", ko: "상태 막대", es: "Barra de estado", fr: "Barre d'etat", de: "Statusleiste", pt: "Barra de status"),
        "Show status bar signal": localized(zhHant: "顯示狀態列信號", ja: "信号を表示", ko: "상태 막대 신호 표시", es: "Mostrar senal en la barra", fr: "Afficher le signal dans la barre", de: "Signal in der Statusleiste anzeigen", pt: "Mostrar sinal na barra"),
        "Hold Command and drag the status bar signal to move its position.": localized(zhHant: "按住 Command 並拖動狀態列信號燈，即可調整它在狀態列中的位置。", ja: "Command キーを押しながらステータスバー信号をドラッグすると位置を移動できます。", ko: "Command 키를 누른 채 상태 막대 신호를 드래그하면 위치를 옮길 수 있습니다.", es: "Manten Command y arrastra la senal de la barra de estado para moverla.", fr: "Maintenez Command et faites glisser le signal de la barre d'etat pour le deplacer.", de: "Halte Command gedrueckt und ziehe das Signal in der Statusleiste, um es zu verschieben.", pt: "Segure Command e arraste o sinal da barra de status para mover a posicao."),
        "Agent Sources": localized(zhHant: "Agent 來源", ja: "Agent ソース", ko: "Agent 소스", es: "Fuentes de Agent", fr: "Sources d'agent", de: "Agent Quellen", pt: "Fontes de Agent"),
        "Automatically detects local Codex activity": localized(zhHant: "自動識別本機 Codex 活動", ja: "ローカル Codex を自動検出", ko: "로컬 Codex 활동 자동 감지", es: "Detecta actividad local de Codex", fr: "Detecte l'activite Codex locale", de: "Erkennt lokale Codex Aktivitaet automatisch", pt: "Detecta atividade local do Codex"),
        "Automatically detect local Codex Desktop activity": localized(zhHant: "自動識別本機 Codex Desktop 活動", ja: "ローカル Codex Desktop を自動検出", ko: "로컬 Codex Desktop 활동 자동 감지", es: "Detectar actividad local de Codex Desktop", fr: "Detecter l'activite Codex Desktop locale", de: "Lokale Codex Desktop Aktivitaet automatisch erkennen", pt: "Detectar atividade local do Codex Desktop"),
        "Codex Desktop is detected automatically; Claude running state comes from Claude Code hooks": localized(zhHant: "Codex Desktop 自動識別；Claude 執行狀態來自 Claude Code Hook", ja: "Codex Desktop は自動検出、Claude は Hook から取得", ko: "Codex Desktop은 자동 감지되고 Claude 실행 상태는 Claude Code Hook에서 옵니다", es: "Codex Desktop se detecta automaticamente; Claude viene de hooks de Claude Code", fr: "Codex Desktop est detecte automatiquement; Claude vient des hooks Claude Code", de: "Codex Desktop wird automatisch erkannt; Claude kommt ueber Claude Code Hooks", pt: "Codex Desktop e detectado automaticamente; Claude vem dos hooks do Claude Code"),
        "Monitor Codex Desktop": localized(zhHant: "監控 Codex Desktop", ja: "Codex Desktop を監視", ko: "Codex Desktop 모니터링", es: "Supervisar Codex Desktop", fr: "Surveiller Codex Desktop", de: "Codex Desktop ueberwachen", pt: "Monitorar Codex Desktop"),
        "Connected by hooks and merged into the same signal light": localized(zhHant: "透過 Hook 接入，狀態會彙總到同一個紅綠燈", ja: "Hook で接続し、同じ信号灯に統合します", ko: "Hook으로 연결되어 같은 신호등에 합쳐집니다", es: "Conectado por hooks y combinado en la misma luz", fr: "Connecte par hooks et fusionne dans le meme signal", de: "Per Hooks verbunden und im selben Signal zusammengefuehrt", pt: "Conectado por hooks e combinado no mesmo sinal"),
        "Install": localized(zhHant: "安裝", ja: "インストール", ko: "설치", es: "Instalar", fr: "Installer", de: "Installieren", pt: "Instalar"),
        "Local Scripts / Other Agents": localized(zhHant: "本機腳本 / 其他 Agent", ja: "ローカルスクリプト / 他の Agent", ko: "로컬 스크립트 / 다른 Agent", es: "Scripts locales / Otros Agent", fr: "Scripts locaux / Autres agents", de: "Lokale Skripte / Andere Agents", pt: "Scripts locais / Outros Agents"),
        "Report state with the command or generic JSON events": localized(zhHant: "透過接入命令或通用 JSON 事件上報狀態", ja: "接続コマンドまたは汎用 JSON イベントで状態を送信", ko: "접속 명령 또는 일반 JSON 이벤트로 상태 보고", es: "Reporta estado con el comando o eventos JSON genericos", fr: "Signale l'etat avec la commande ou des evenements JSON generiques", de: "Meldet Status per Befehl oder generischen JSON Ereignissen", pt: "Envia estado com o comando ou eventos JSON genericos"),
        "Copy Command": localized(zhHant: "複製接入命令", ja: "コマンドをコピー", ko: "명령 복사", es: "Copiar comando", fr: "Copier la commande", de: "Befehl kopieren", pt: "Copiar comando"),
        "Connection result": localized(zhHant: "連接結果", ja: "接続結果", ko: "연결 결과", es: "Resultado de conexion", fr: "Resultat de connexion", de: "Verbindungsergebnis", pt: "Resultado da conexao"),
        "Connected": localized(zhHant: "已連接", ja: "接続済み", ko: "연결됨", es: "Conectado", fr: "Connecte", de: "Verbunden", pt: "Conectado"),
        "Needs install": localized(zhHant: "需要安裝", ja: "インストールが必要", ko: "설치 필요", es: "Necesita instalacion", fr: "Installation requise", de: "Installation noetig", pt: "Precisa instalar"),
        "Hook updated": localized(zhHant: "已更新", ja: "更新済み", ko: "업데이트됨", es: "Actualizado", fr: "Mis a jour", de: "Aktualisiert", pt: "Atualizado"),
        "Completed": localized(zhHant: "已完成", ja: "完了", ko: "완료", es: "Completado", fr: "Termine", de: "Abgeschlossen", pt: "Concluido"),
        "Check complete": localized(zhHant: "檢查完成", ja: "確認完了", ko: "검사 완료", es: "Comprobacion lista", fr: "Verification terminee", de: "Pruefung abgeschlossen", pt: "Verificacao concluida"),
        "Install complete": localized(zhHant: "安裝完成", ja: "インストール完了", ko: "설치 완료", es: "Instalacion lista", fr: "Installation terminee", de: "Installation abgeschlossen", pt: "Instalacao concluida"),
        "Uninstall complete": localized(zhHant: "卸載完成", ja: "アンインストール完了", ko: "제거 완료", es: "Desinstalacion lista", fr: "Desinstallation terminee", de: "Deinstallation abgeschlossen", pt: "Desinstalacao concluida"),
        "Removed": localized(zhHant: "已移除", ja: "削除済み", ko: "제거됨", es: "Eliminado", fr: "Supprime", de: "Entfernt", pt: "Removido"),
        "Nothing to remove": localized(zhHant: "無需卸載", ja: "削除不要", ko: "제거할 항목 없음", es: "Nada que eliminar", fr: "Rien a supprimer", de: "Nichts zu entfernen", pt: "Nada para remover"),
        "Config file": localized(zhHant: "設定檔", ja: "設定ファイル", ko: "설정 파일", es: "Archivo de configuracion", fr: "Fichier de configuration", de: "Konfigurationsdatei", pt: "Arquivo de configuracao"),
        "No files were written. Click Install to apply changes.": localized(zhHant: "尚未寫入檔案，點擊安裝連接套用更改。", ja: "ファイルは未変更です。インストールで変更を適用します。", ko: "파일은 아직 쓰지 않았습니다. 설치를 눌러 적용하세요.", es: "No se escribieron archivos. Haz clic en Instalar para aplicar.", fr: "Aucun fichier ecrit. Cliquez Installer pour appliquer.", de: "Keine Dateien geschrieben. Mit Installieren anwenden.", pt: "Nenhum arquivo foi escrito. Clique em Instalar para aplicar."),
        "Connections are ready.": localized(zhHant: "連接已準備好。", ja: "接続は準備できています。", ko: "연결이 준비되었습니다.", es: "Las conexiones estan listas.", fr: "Les connexions sont pretes.", de: "Verbindungen sind bereit.", pt: "Conexoes prontas."),
        "Hooks are up to date.": localized(zhHant: "Hook 已是最新。", ja: "Hooks は最新です。", ko: "Hook이 최신 상태입니다.", es: "Los hooks estan actualizados.", fr: "Les hooks sont a jour.", de: "Hooks sind aktuell.", pt: "Hooks atualizados."),
        "Hooks removed.": localized(zhHant: "Hook 已移除。", ja: "Hooks を削除しました。", ko: "Hook이 제거되었습니다.", es: "Hooks eliminados.", fr: "Hooks supprimes.", de: "Hooks entfernt.", pt: "Hooks removidos."),
        "Language": localized(zhHant: "語言", ja: "言語", ko: "언어", es: "Idioma", fr: "Langue", de: "Sprache", pt: "Idioma"),
        "Theme": localized(zhHant: "主題", ja: "テーマ", ko: "테마", es: "Tema", fr: "Theme", de: "Theme", pt: "Tema"),
        "Liquid glass": localized(zhHant: "液態玻璃", ja: "リキッドグラス", ko: "리퀴드 글래스", es: "Cristal liquido", fr: "Verre liquide", de: "Liquid Glass", pt: "Vidro liquido"),
        "Liquid glass strength": localized(zhHant: "液態玻璃強度", ja: "リキッドグラス強度", ko: "리퀴드 글래스 강도", es: "Intensidad del cristal liquido", fr: "Intensite du verre liquide", de: "Liquid Glass Staerke", pt: "Intensidade do vidro liquido"),
        "Follow System": localized(zhHant: "跟隨系統", ja: "システム連動", ko: "시스템 따르기", es: "Seguir sistema", fr: "Suivre le systeme", de: "System folgen", pt: "Seguir sistema"),
        "Reduced": localized(zhHant: "減弱", ja: "控えめ", ko: "약하게", es: "Reducido", fr: "Reduit", de: "Reduziert", pt: "Reduzido"),
        "Enhanced": localized(zhHant: "增強", ja: "強調", ko: "강화", es: "Mejorado", fr: "Renforce", de: "Verstaerkt", pt: "Reforcado"),
        "Light": localized(zhHant: "淺色", ja: "ライト", ko: "밝게", es: "Claro", fr: "Clair", de: "Hell", pt: "Claro"),
        "Dark": localized(zhHant: "深色", ja: "ダーク", ko: "어둡게", es: "Oscuro", fr: "Sombre", de: "Dunkel", pt: "Escuro"),
        "Status bar style": localized(zhHant: "狀態列風格", ja: "表示スタイル", ko: "상태 막대 스타일", es: "Estilo de barra", fr: "Style de barre", de: "Statusleistenstil", pt: "Estilo da barra"),
        "Status bar menu": localized(zhHant: "狀態列選單", ja: "ステータスメニュー", ko: "상태 막대 메뉴", es: "Menu de barra", fr: "Menu de barre", de: "Statusleistenmenue", pt: "Menu da barra"),
        "Simple": localized(zhHant: "簡約", ja: "シンプル", ko: "간단", es: "Simple", fr: "Simple", de: "Einfach", pt: "Simples"),
        "Detailed": localized(zhHant: "複雜", ja: "詳細", ko: "상세", es: "Detallado", fr: "Detaille", de: "Detailliert", pt: "Detalhado"),
        "Direction": localized(zhHant: "方向", ja: "方向", ko: "방향", es: "Direccion", fr: "Direction", de: "Richtung", pt: "Direcao"),
        "Dot breathing": localized(zhHant: "圓點呼吸強度", ja: "ドットの呼吸", ko: "점 호흡", es: "Respiracion del punto", fr: "Respiration du point", de: "Punkt Atmung", pt: "Respiracao do ponto"),
        "Effect Customization": localized(zhHant: "燈效自訂", ja: "効果設定", ko: "등 효과 사용자화", es: "Personalizacion de efectos", fr: "Personnalisation des effets", de: "Effektanpassung", pt: "Personalizacao de efeitos"),
        "Active effect": localized(zhHant: "執行燈效", ja: "実行効果", ko: "활성 효과", es: "Efecto activo", fr: "Effet actif", de: "Aktiver Effekt", pt: "Efeito ativo"),
        "Work effect speed": localized(zhHant: "工作燈效速度", ja: "作業速度", ko: "작업 효과 속도", es: "Velocidad del efecto de trabajo", fr: "Vitesse de l'effet de travail", de: "Arbeitseffekt-Tempo", pt: "Velocidade do efeito de trabalho"),
        "Alert flash speed": localized(zhHant: "提醒閃爍速度", ja: "通知速度", ko: "알림 깜박임 속도", es: "Velocidad de alerta", fr: "Vitesse de clignotement", de: "Warnblinktempo", pt: "Velocidade do alerta"),
        "Done effect": localized(zhHant: "完成燈效", ja: "完了効果", ko: "완료 효과", es: "Efecto de listo", fr: "Effet termine", de: "Fertig Effekt", pt: "Efeito concluido"),
        "Breathing strength": localized(zhHant: "呼吸強度", ja: "呼吸強度", ko: "호흡 강도", es: "Intensidad de respiracion", fr: "Intensite de respiration", de: "Atemstaerke", pt: "Intensidade da respiracao"),
        "Light Agent": localized(zhHant: "燈效 Agent", ja: "信号対象", ko: "신호 Agent", es: "Agent de luz", fr: "Agent du signal", de: "Signal Agent", pt: "Agent do sinal"),
        "Horizontal dot size": localized(zhHant: "圓點橫向尺寸", ja: "横ドットサイズ", ko: "가로 점 크기", es: "Tamano horizontal del punto", fr: "Taille horizontale du point", de: "Horizontale Punktgroesse", pt: "Tamanho horizontal do ponto"),
        "Vertical lamp size": localized(zhHant: "燈牌直向尺寸", ja: "縦ランプサイズ", ko: "세로 램프 크기", es: "Tamano vertical de la lampara", fr: "Taille verticale du feu", de: "Vertikale Lampengroesse", pt: "Tamanho vertical da lampada"),
        "Default": localized(zhHant: "預設", ja: "標準", ko: "기본", es: "Predeterminado", fr: "Par defaut", de: "Standard", pt: "Padrao"),
        "Small": localized(zhHant: "小", ja: "小", ko: "작게", es: "Pequeno", fr: "Petit", de: "Klein", pt: "Pequeno"),
        "Large": localized(zhHant: "大", ja: "大", ko: "크게", es: "Grande", fr: "Grand", de: "Gross", pt: "Grande"),
        "Enable signal test": localized(zhHant: "啟用燈效測試", ja: "テスト有効", ko: "신호 테스트 켜기", es: "Activar prueba de senal", fr: "Activer le test du signal", de: "Signaltest aktivieren", pt: "Ativar teste de sinal"),
        "Turn this off to leave manual testing and return to live agent status.": localized(zhHant: "關閉後會退出手動測試，並恢復真實 Agent 狀態。", ja: "オフにすると手動テストを終了し、実際の Agent 状態に戻ります。", ko: "끄면 수동 테스트를 종료하고 실제 Agent 상태로 돌아갑니다.", es: "Desactivalo para salir de la prueba manual y volver al estado real del Agent.", fr: "Desactivez pour quitter le test manuel et revenir a l'etat reel de l'agent.", de: "Ausschalten beendet den manuellen Test und kehrt zum echten Agent Status zurueck.", pt: "Desative para sair do teste manual e voltar ao status real do Agent."),
        "Idle": localized(zhHant: "空閒", ja: "待機中", ko: "유휴", es: "Inactivo", fr: "Inactif", de: "Leerlauf", pt: "Ocioso"),
        "Working": localized(zhHant: "工作中", ja: "作業中", ko: "작업 중", es: "Trabajando", fr: "En cours", de: "Arbeitet", pt: "Trabalhando"),
        "Needs Review": localized(zhHant: "需要查看", ja: "確認が必要", ko: "검토 필요", es: "Requiere revision", fr: "A verifier", de: "Pruefung noetig", pt: "Precisa revisao"),
        "Done": localized(zhHant: "已完成", ja: "完了", ko: "완료", es: "Listo", fr: "Termine", de: "Fertig", pt: "Concluido"),
        "Permission": localized(zhHant: "請求授權", ja: "権限", ko: "권한", es: "Permiso", fr: "Autorisation", de: "Berechtigung", pt: "Permissao"),
        "Blocked": localized(zhHant: "阻塞", ja: "ブロック", ko: "차단됨", es: "Bloqueado", fr: "Bloque", de: "Blockiert", pt: "Bloqueado"),
        "Off": localized(zhHant: "關閉", ja: "オフ", ko: "꺼짐", es: "Apagado", fr: "Arret", de: "Aus", pt: "Desligado"),
        "Reset": localized(zhHant: "重設", ja: "リセット", ko: "재설정", es: "Restablecer", fr: "Reinitialiser", de: "Zuruecksetzen", pt: "Redefinir"),
        "Advanced Signals": localized(zhHant: "進階信號", ja: "詳細信号", ko: "고급 신호", es: "Senales avanzadas", fr: "Signaux avances", de: "Erweiterte Signale", pt: "Sinais avancados"),
        "Connections": localized(zhHant: "連接", ja: "接続", ko: "연결", es: "Conexiones", fr: "Connexions", de: "Verbindungen", pt: "Conexoes"),
        "Automatic setup": localized(zhHant: "自動接入", ja: "自動セットアップ", ko: "자동 설정", es: "Configuracion automatica", fr: "Configuration automatique", de: "Automatische Einrichtung", pt: "Configuracao automatica"),
        "Codex and Claude Code": localized(zhHant: "Codex 和 Claude Code", ja: "Codex と Claude Code", ko: "Codex 및 Claude Code", es: "Codex y Claude Code", fr: "Codex et Claude Code", de: "Codex und Claude Code", pt: "Codex e Claude Code"),
        "Connect Codex CLI / Codex IDE events with project hooks": localized(zhHant: "透過專案 Hook 接入 Codex CLI / Codex IDE 事件", ja: "プロジェクト Hook で Codex CLI / Codex IDE イベントを接続", ko: "프로젝트 Hook으로 Codex CLI / Codex IDE 이벤트 연결", es: "Conecta eventos de Codex CLI / Codex IDE con hooks del proyecto", fr: "Connecte les evenements Codex CLI / Codex IDE avec les hooks projet", de: "Codex CLI / Codex IDE Events ueber Projekt Hooks verbinden", pt: "Conecta eventos do Codex CLI / Codex IDE com hooks do projeto"),
        "Codex Hook": localized(zhHant: "Codex Hook", ja: "Codex Hook", ko: "Codex Hook", es: "Hook de Codex", fr: "Hook Codex", de: "Codex Hook", pt: "Hook do Codex"),
        "Codex Desktop": localized(zhHant: "Codex Desktop", ja: "Codex Desktop", ko: "Codex Desktop", es: "Codex Desktop", fr: "Codex Desktop", de: "Codex Desktop", pt: "Codex Desktop"),
        "Supports Codex Desktop, CLI, VS Code, Xcode, and IDEA": localized(zhHant: "支援 Codex Desktop、CLI、VS Code、Xcode、IDEA", ja: "Codex Desktop、CLI、VS Code、Xcode、IDEA に対応", ko: "Codex Desktop, CLI, VS Code, Xcode, IDEA 지원", es: "Compatible con Codex Desktop, CLI, VS Code, Xcode e IDEA", fr: "Prend en charge Codex Desktop, CLI, VS Code, Xcode et IDEA", de: "Unterstuetzt Codex Desktop, CLI, VS Code, Xcode und IDEA", pt: "Suporta Codex Desktop, CLI, VS Code, Xcode e IDEA"),
        "Automatically detect Codex Desktop, CLI, VS Code, Xcode, and IDEA activity": localized(zhHant: "自動識別 Codex Desktop、CLI、VS Code、Xcode、IDEA 活動", ja: "Codex Desktop、CLI、VS Code、Xcode、IDEA の活動を自動検出", ko: "Codex Desktop, CLI, VS Code, Xcode, IDEA 활동 자동 감지", es: "Detectar automaticamente actividad de Codex Desktop, CLI, VS Code, Xcode e IDEA", fr: "Detecter automatiquement l'activite Codex Desktop, CLI, VS Code, Xcode et IDEA", de: "Aktivitaet von Codex Desktop, CLI, VS Code, Xcode und IDEA automatisch erkennen", pt: "Detectar automaticamente atividade do Codex Desktop, CLI, VS Code, Xcode e IDEA"),
        "Auto monitor": localized(zhHant: "自動監控", ja: "自動監視", ko: "자동 모니터링", es: "Monitor automatico", fr: "Surveillance auto", de: "Auto-Ueberwachung", pt: "Monitor automatico"),
        "Codex Hook (Optional)": localized(zhHant: "Codex Hook（可選）", ja: "Codex Hook（任意）", ko: "Codex Hook(선택 사항)", es: "Hook de Codex (opcional)", fr: "Hook Codex (facultatif)", de: "Codex Hook (optional)", pt: "Hook do Codex (opcional)"),
        "Optional enhancement for permission requests, lower latency, and compatibility": localized(zhHant: "可選增強：用於權限請求、低延遲和相容舊版本", ja: "任意の拡張: 権限リクエスト、低遅延、互換性向け", ko: "선택적 확장: 권한 요청, 낮은 지연 시간, 호환성용", es: "Mejora opcional para permisos, menor latencia y compatibilidad", fr: "Extension facultative pour autorisations, latence reduite et compatibilite", de: "Optionale Erweiterung fuer Berechtigungen, geringere Latenz und Kompatibilitaet", pt: "Melhoria opcional para permissoes, menor latencia e compatibilidade"),
        "Claude (Untested)": localized(zhHant: "Claude（尚未測試）", ja: "Claude（未テスト）", ko: "Claude(아직 테스트 안 됨)", es: "Claude (sin probar)", fr: "Claude (non teste)", de: "Claude (ungetestet)", pt: "Claude (nao testado)"),
        "Claude Code (Untested)": localized(zhHant: "Claude Code（尚未測試）", ja: "Claude Code（未テスト）", ko: "Claude Code(아직 테스트 안 됨)", es: "Claude Code (sin probar)", fr: "Claude Code (non teste)", de: "Claude Code (ungetestet)", pt: "Claude Code (nao testado)"),
        "Supports Claude Desktop": localized(zhHant: "支援 Claude Desktop", ja: "Claude Desktop に対応", ko: "Claude Desktop 지원", es: "Compatible con Claude Desktop", fr: "Prend en charge Claude Desktop", de: "Unterstuetzt Claude Desktop", pt: "Suporta Claude Desktop"),
        "Automatically detect Claude Desktop activity": localized(zhHant: "自動識別 Claude Desktop 活動", ja: "Claude Desktop の活動を自動検出", ko: "Claude Desktop 활동 자동 감지", es: "Detectar automaticamente actividad de Claude Desktop", fr: "Detecter automatiquement l'activite Claude Desktop", de: "Claude Desktop Aktivitaet automatisch erkennen", pt: "Detectar automaticamente atividade do Claude Desktop"),
        "Claude Hook (Optional)": localized(zhHant: "Claude Hook（可選）", ja: "Claude Hook（任意）", ko: "Claude Hook(선택 사항)", es: "Hook de Claude (opcional)", fr: "Hook Claude (facultatif)", de: "Claude Hook (optional)", pt: "Hook do Claude (opcional)"),
        "Check Codex": localized(zhHant: "檢查 Codex", ja: "Codex を確認", ko: "Codex 확인", es: "Comprobar Codex", fr: "Verifier Codex", de: "Codex pruefen", pt: "Verificar Codex"),
        "Install Codex": localized(zhHant: "安裝 Codex", ja: "Codex をインストール", ko: "Codex 설치", es: "Instalar Codex", fr: "Installer Codex", de: "Codex installieren", pt: "Instalar Codex"),
        "Uninstall": localized(zhHant: "解除安裝", ja: "アンインストール", ko: "제거", es: "Desinstalar", fr: "Desinstaller", de: "Deinstallieren", pt: "Desinstalar"),
        "Global Claude Code hooks for tools, permissions, notifications, subtasks, and stop failures": localized(zhHant: "透過 Claude Code Hook 全域接入，支援工具、權限、通知、子任務和停止失敗", ja: "Claude Code のグローバル Hook でツール、権限、通知、サブタスク、停止失敗に対応", ko: "Claude Code 전역 Hook으로 도구, 권한, 알림, 하위 작업, 중지 실패 지원", es: "Hooks globales de Claude Code para herramientas, permisos, notificaciones, subtareas y fallos al detener", fr: "Hooks globaux Claude Code pour outils, autorisations, notifications, sous-taches et echecs d'arret", de: "Globale Claude Code Hooks fuer Tools, Berechtigungen, Hinweise, Unteraufgaben und Stop Fehler", pt: "Hooks globais do Claude Code para ferramentas, permissoes, notificacoes, subtarefas e falhas ao parar"),
        "Claude Code global hooks can be checked or installed separately": localized(zhHant: "Claude Code 全域 Hook 可單獨檢查或安裝", ja: "Claude Code のグローバル Hook は個別に確認またはインストールできます", ko: "Claude Code 전역 Hook은 별도로 확인하거나 설치할 수 있습니다", es: "Los hooks globales de Claude Code se comprueban o instalan por separado", fr: "Les hooks globaux Claude Code se verifient ou s'installent separement", de: "Globale Claude Code Hooks lassen sich separat pruefen oder installieren", pt: "Hooks globais do Claude Code podem ser verificados ou instalados separadamente"),
        "Install Claude": localized(zhHant: "安裝 Claude", ja: "Claude をインストール", ko: "Claude 설치", es: "Instalar Claude", fr: "Installer Claude", de: "Claude installieren", pt: "Instalar Claude"),
        "Check Claude": localized(zhHant: "檢查 Claude", ja: "Claude を確認", ko: "Claude 확인", es: "Comprobar Claude", fr: "Verifier Claude", de: "Claude pruefen", pt: "Verificar Claude"),
        "Check or install Claude Code global hooks only": localized(zhHant: "單獨檢查或安裝 Claude Code 全域 Hook", ja: "Claude Code のグローバル Hook だけを確認またはインストール", ko: "Claude Code 전역 Hook만 확인하거나 설치", es: "Comprobar o instalar solo los hooks globales de Claude Code", fr: "Verifier ou installer uniquement les hooks globaux Claude Code", de: "Nur globale Claude Code Hooks pruefen oder installieren", pt: "Verificar ou instalar apenas hooks globais do Claude Code"),
        "Check": localized(zhHant: "檢查", ja: "確認", ko: "확인", es: "Comprobar", fr: "Verifier", de: "Pruefen", pt: "Verificar"),
        "Other agents": localized(zhHant: "其他 Agent", ja: "他の Agent", ko: "다른 Agent", es: "Otros Agent", fr: "Autres agents", de: "Andere Agents", pt: "Outros Agents"),
        "Local scripts, generic JSON events": localized(zhHant: "本機腳本、通用 JSON 事件", ja: "ローカルスクリプト、汎用 JSON イベント", ko: "로컬 스크립트, 일반 JSON 이벤트", es: "Scripts locales, eventos JSON genericos", fr: "Scripts locaux, evenements JSON generiques", de: "Lokale Skripte, generische JSON Ereignisse", pt: "Scripts locais, eventos JSON genericos"),
        "Copy command": localized(zhHant: "複製接入命令", ja: "コマンドをコピー", ko: "명령 복사", es: "Copiar comando", fr: "Copier la commande", de: "Befehl kopieren", pt: "Copiar comando"),
        "Diagnostics": localized(zhHant: "診斷與版本", ja: "診断", ko: "진단", es: "Diagnostico", fr: "Diagnostics", de: "Diagnose", pt: "Diagnostico"),
        "Export diagnostics, state file, and version": localized(zhHant: "匯出診斷包、查看狀態檔案和版本", ja: "診断、状態ファイル、バージョンを表示", ko: "진단, 상태 파일, 버전 확인", es: "Exportar diagnostico, archivo de estado y version", fr: "Exporter diagnostics, fichier d'etat et version", de: "Diagnose, Statusdatei und Version exportieren", pt: "Exportar diagnostico, arquivo de estado e versao"),
        "Export": localized(zhHant: "匯出", ja: "書き出し", ko: "내보내기", es: "Exportar", fr: "Exporter", de: "Exportieren", pt: "Exportar"),
        "Export Diagnostics": localized(zhHant: "匯出診斷", ja: "診断出力", ko: "진단 내보내기", es: "Exportar diagnostico", fr: "Exporter diagnostics", de: "Diagnose exportieren", pt: "Exportar diagnostico"),
        "State File": localized(zhHant: "狀態檔案", ja: "状態ファイル", ko: "상태 파일", es: "Archivo de estado", fr: "Fichier d'etat", de: "Statusdatei", pt: "Arquivo de estado"),
        "Copy Path": localized(zhHant: "複製路徑", ja: "パスをコピー", ko: "경로 복사", es: "Copiar ruta", fr: "Copier le chemin", de: "Pfad kopieren", pt: "Copiar caminho"),
        "Release": localized(zhHant: "版本", ja: "リリース", ko: "릴리스", es: "Version", fr: "Version", de: "Release", pt: "Versao"),
        "Version": localized(zhHant: "版本", ja: "バージョン", ko: "버전", es: "Version", fr: "Version", de: "Version", pt: "Versao"),
        "Updates": localized(zhHant: "更新", ja: "アップデート", ko: "업데이트", es: "Actualizaciones", fr: "Mises a jour", de: "Updates", pt: "Atualizacoes"),
        "Check for Updates": localized(zhHant: "檢查更新", ja: "アップデートを確認", ko: "업데이트 확인", es: "Buscar actualizaciones", fr: "Rechercher des mises a jour", de: "Nach Updates suchen", pt: "Buscar atualizacoes"),
        "Check for Updates...": localized(zhHant: "檢查更新...", ja: "アップデートを確認...", ko: "업데이트 확인...", es: "Buscar actualizaciones...", fr: "Rechercher des mises a jour...", de: "Nach Updates suchen...", pt: "Buscar atualizacoes..."),
        "Checking": localized(zhHant: "檢查中", ja: "確認中", ko: "확인 중", es: "Comprobando", fr: "Verification", de: "Prueft", pt: "Verificando"),
        "Checking...": localized(zhHant: "檢查中...", ja: "確認中...", ko: "확인 중...", es: "Comprobando...", fr: "Verification...", de: "Prueft...", pt: "Verificando..."),
        "Open Download Page": localized(zhHant: "開啟下載頁", ja: "ダウンロードページを開く", ko: "다운로드 페이지 열기", es: "Abrir descarga", fr: "Ouvrir le telechargement", de: "Downloadseite oeffnen", pt: "Abrir pagina de download"),
        "Automatically check for updates": localized(zhHant: "自動檢查更新", ja: "アップデートを自動確認", ko: "업데이트 자동 확인", es: "Buscar actualizaciones automaticamente", fr: "Verifier automatiquement les mises a jour", de: "Automatisch nach Updates suchen", pt: "Verificar atualizacoes automaticamente"),
        "Send a macOS notification when a newer release is available. Updates are not installed automatically.": localized(zhHant: "偵測到新版本時發送 macOS 通知，不會自動安裝。", ja: "新しいリリースがあると macOS 通知を送ります。自動インストールはしません。", ko: "새 릴리스가 있으면 macOS 알림을 보냅니다. 자동 설치는 하지 않습니다.", es: "Envia una notificacion de macOS cuando haya una version nueva. No se instala automaticamente.", fr: "Envoie une notification macOS quand une nouvelle version est disponible. L'installation n'est pas automatique.", de: "Sendet eine macOS Mitteilung, wenn eine neue Version verfuegbar ist. Updates werden nicht automatisch installiert.", pt: "Envia uma notificacao do macOS quando houver uma nova versao. Nao instala automaticamente."),
        "Sends a notification when a newer release is available. Updates are not installed automatically.": localized(zhHant: "偵測到新版本時發送通知，不會自動安裝。", ja: "新しいリリースがあると通知します。自動インストールはしません。", ko: "새 릴리스가 있으면 알림을 보냅니다. 자동 설치는 하지 않습니다.", es: "Envia una notificacion cuando haya una version nueva. No se instala automaticamente.", fr: "Envoie une notification quand une nouvelle version est disponible. L'installation n'est pas automatique.", de: "Sendet eine Mitteilung, wenn eine neue Version verfuegbar ist. Updates werden nicht automatisch installiert.", pt: "Envia uma notificacao quando houver uma nova versao. Nao instala automaticamente."),
        "Sparkle checks periodically and can download the update, then relaunch to install.": localized(zhHant: "Sparkle 會定期檢查更新，可直接下載並重新啟動安裝。", ja: "Sparkle が定期的にアップデートを確認し、ダウンロードして再起動後にインストールできます。", ko: "Sparkle이 주기적으로 업데이트를 확인하고 다운로드한 뒤 재실행하여 설치할 수 있습니다.", es: "Sparkle busca actualizaciones periodicamente y puede descargarlas, luego reiniciar para instalarlas.", fr: "Sparkle recherche regulierement les mises a jour, peut les telecharger puis relancer l'app pour les installer.", de: "Sparkle sucht regelmaessig nach Updates, kann sie laden und die App zum Installieren neu starten.", pt: "O Sparkle verifica atualizacoes periodicamente, pode baixa-las e reiniciar para instalar."),
        "This debug build has no Sparkle configuration, so it opens the GitHub download page.": localized(zhHant: "目前除錯版本沒有 Sparkle 設定，會開啟 GitHub 下載頁。", ja: "このデバッグビルドには Sparkle 設定がないため、GitHub のダウンロードページを開きます。", ko: "이 디버그 빌드에는 Sparkle 구성이 없어 GitHub 다운로드 페이지를 엽니다.", es: "Esta compilacion de depuracion no tiene configuracion de Sparkle, por lo que abre la pagina de descarga de GitHub.", fr: "Cette version de debug n'a pas de configuration Sparkle et ouvre donc la page de telechargement GitHub.", de: "Dieser Debug Build hat keine Sparkle Konfiguration und oeffnet deshalb die GitHub Downloadseite.", pt: "Esta compilacao de depuracao nao tem configuracao do Sparkle, entao abre a pagina de download do GitHub."),
        "Automatic update checks are off.": localized(zhHant: "已關閉自動檢查更新。", ja: "アップデートの自動確認はオフです。", ko: "업데이트 자동 확인이 꺼져 있습니다.", es: "La busqueda automatica de actualizaciones esta desactivada.", fr: "La verification automatique des mises a jour est desactivee.", de: "Automatische Updatepruefung ist aus.", pt: "A verificacao automatica de atualizacoes esta desativada."),
        "Checking GitHub Releases...": localized(zhHant: "正在檢查 GitHub Releases...", ja: "GitHub Releases を確認中...", ko: "GitHub Releases 확인 중...", es: "Comprobando GitHub Releases...", fr: "Verification de GitHub Releases...", de: "GitHub Releases werden geprueft...", pt: "Verificando GitHub Releases..."),
        "Current version": localized(zhHant: "目前版本", ja: "現在のバージョン", ko: "현재 버전", es: "Version actual", fr: "Version actuelle", de: "Aktuelle Version", pt: "Versao atual"),
        "No updates are available.": localized(zhHant: "暫無可用更新。", ja: "利用可能なアップデートはありません。", ko: "사용 가능한 업데이트가 없습니다.", es: "No hay actualizaciones disponibles.", fr: "Aucune mise a jour disponible.", de: "Keine Updates verfuegbar.", pt: "Nenhuma atualizacao disponivel."),
        "Diagnostics result": localized(zhHant: "診斷結果", ja: "診断結果", ko: "진단 결과", es: "Resultado de diagnostico", fr: "Resultat du diagnostic", de: "Diagnoseergebnis", pt: "Resultado do diagnostico"),
        "Copy release info": localized(zhHant: "複製版本資訊", ja: "リリース情報をコピー", ko: "릴리스 정보 복사", es: "Copiar info de version", fr: "Copier les infos de version", de: "Release Info kopieren", pt: "Copiar info da versao"),
        "Developer": localized(zhHant: "開發者", ja: "開発者", ko: "개발자", es: "Desarrollador", fr: "Developpeur", de: "Entwickler", pt: "Desenvolvedor"),
        "Waiting for status": localized(zhHant: "等待狀態", ja: "状態待ち", ko: "상태 대기 중", es: "Esperando estado", fr: "En attente d'etat", de: "Wartet auf Status", pt: "Aguardando status"),
        "Not Running": localized(zhHant: "尚未執行", ja: "未実行", ko: "실행 중 아님", es: "No se esta ejecutando", fr: "Non lance", de: "Laeuft nicht", pt: "Nao esta em execucao"),
        "Waiting to launch": localized(zhHant: "等待啟動", ja: "起動待ち", ko: "실행 대기 중", es: "Esperando inicio", fr: "En attente de lancement", de: "Wartet auf Start", pt: "Aguardando inicio"),
        "The selected agent is not running.": localized(zhHant: "目前選擇的 Agent 尚未執行。", ja: "選択中の Agent は実行されていません。", ko: "선택한 Agent가 실행 중이 아닙니다.", es: "El Agent seleccionado no esta en ejecucion.", fr: "L'agent selectionne n'est pas en cours.", de: "Der ausgewaehlte Agent laeuft nicht.", pt: "O Agent selecionado nao esta em execucao."),
        "The selected agent is not running": localized(zhHant: "目前選擇的 Agent 尚未執行", ja: "選択中の Agent は実行されていません", ko: "선택한 Agent가 실행 중이 아닙니다", es: "El Agent seleccionado no esta en ejecucion", fr: "L'agent selectionne n'est pas en cours", de: "Der ausgewaehlte Agent laeuft nicht", pt: "O Agent selecionado nao esta em execucao"),
        "Launch the selected agent to show live status here.": localized(zhHant: "啟動對應 Agent 後，這裡會顯示即時狀態。", ja: "選択した Agent を起動すると、ここにライブ状態が表示されます。", ko: "선택한 Agent를 실행하면 여기에 실시간 상태가 표시됩니다.", es: "Inicia el Agent seleccionado para ver aqui el estado en vivo.", fr: "Lancez l'agent selectionne pour afficher son etat ici.", de: "Starte den ausgewaehlten Agent, um hier den Live Status zu sehen.", pt: "Inicie o Agent selecionado para mostrar o status ao vivo aqui."),
        "Paused": localized(zhHant: "已暫停", ja: "一時停止中", ko: "일시 중지됨", es: "Pausado", fr: "En pause", de: "Pausiert", pt: "Pausado"),
        "No active agent sessions": localized(zhHant: "沒有執行中的 Agent", ja: "実行中の Agent なし", ko: "활성 Agent 세션 없음", es: "No hay sesiones activas", fr: "Aucune session d'agent active", de: "Keine aktiven Agent Sitzungen", pt: "Nenhuma sessao ativa"),
        "No running agents": localized(zhHant: "沒有執行中的 Agent", ja: "実行中なし", ko: "실행 중인 Agent 없음", es: "No hay agentes en ejecucion", fr: "Aucun agent en cours", de: "Keine laufenden Agents", pt: "Nenhum Agent em execucao"),
        "Running Now": localized(zhHant: "正在執行", ja: "実行中", ko: "실행 중", es: "En ejecucion", fr: "En cours", de: "Laeuft gerade", pt: "Em execucao"),
        "Recent": localized(zhHant: "最近", ja: "最近", ko: "최근", es: "Reciente", fr: "Recent", de: "Zuletzt", pt: "Recente"),
        "Settings": localized(zhHant: "設定", ja: "設定", ko: "설정", es: "Ajustes", fr: "Reglages", de: "Einstellungen", pt: "Configuracoes"),
        "Resume": localized(zhHant: "繼續監控", ja: "再開", ko: "재개", es: "Reanudar", fr: "Reprendre", de: "Fortsetzen", pt: "Retomar"),
        "Pause": localized(zhHant: "暫停監控", ja: "一時停止", ko: "일시 중지", es: "Pausar", fr: "Pause", de: "Pause", pt: "Pausar"),
        "Resume Monitoring": localized(zhHant: "繼續監控", ja: "監視を再開", ko: "모니터링 재개", es: "Reanudar supervision", fr: "Reprendre la surveillance", de: "Ueberwachung fortsetzen", pt: "Retomar monitoramento"),
        "Pause Monitoring": localized(zhHant: "暫停監控", ja: "監視を一時停止", ko: "모니터링 일시 중지", es: "Pausar supervision", fr: "Mettre la surveillance en pause", de: "Ueberwachung pausieren", pt: "Pausar monitoramento"),
        "When paused, the status bar light turns off and agent events stop refreshing.": localized(zhHant: "暫停後狀態列燈會熄滅，Agent 事件暫不刷新。", ja: "一時停止中はステータスバーのライトが消え、Agent イベントの更新を止めます。", ko: "일시 중지하면 상태 막대 불이 꺼지고 Agent 이벤트 새로고침이 멈춥니다.", es: "En pausa, la luz de la barra se apaga y los eventos dejan de actualizarse.", fr: "En pause, le voyant de la barre s'eteint et les evenements agent ne se rafraichissent plus.", de: "Bei Pause erlischt das Statusleistenlicht und Agent Ereignisse werden nicht aktualisiert.", pt: "Ao pausar, a luz da barra apaga e os eventos do Agent deixam de atualizar."),
        "Quit": localized(zhHant: "退出", ja: "終了", ko: "종료", es: "Salir", fr: "Quitter", de: "Beenden", pt: "Sair"),
        "Manual": localized(zhHant: "手動", ja: "手動", ko: "수동", es: "Manual", fr: "Manuel", de: "Manuell", pt: "Manual"),
        "Started": localized(zhHant: "開始", ja: "開始", ko: "시작됨", es: "Iniciado", fr: "Demarre", de: "Gestartet", pt: "Iniciado"),
        "Prompt Received": localized(zhHant: "收到任務", ja: "プロンプト受信", ko: "프롬프트 수신", es: "Prompt recibido", fr: "Prompt recu", de: "Prompt empfangen", pt: "Prompt recebido"),
        "Running Step": localized(zhHant: "正在執行步驟", ja: "ステップ実行中", ko: "단계 실행 중", es: "Ejecutando paso", fr: "Execution de l'etape", de: "Schritt wird ausgefuehrt", pt: "Executando etapa"),
        "Step Done": localized(zhHant: "步驟完成", ja: "ステップ完了", ko: "단계 완료", es: "Paso listo", fr: "Etape terminee", de: "Schritt fertig", pt: "Etapa concluida"),
        "Desktop app running": localized(zhHant: "桌面版執行中", ja: "デスクトップ版実行中", ko: "데스크톱 앱 실행 중", es: "App de escritorio en ejecucion", fr: "App de bureau en cours", de: "Desktop App laeuft", pt: "App desktop em execucao"),
        "Desktop app is running": localized(zhHant: "桌面端正在執行", ja: "デスクトップ版が実行中", ko: "데스크톱 앱 실행 중", es: "La app de escritorio esta en ejecucion", fr: "L'app de bureau est en cours", de: "Desktop App laeuft", pt: "O app desktop esta em execucao"),
        "CLI / hook is running": localized(zhHant: "CLI / Hook 正在執行", ja: "CLI / Hook が実行中", ko: "CLI / Hook 실행 중", es: "CLI / hook en ejecucion", fr: "CLI / hook en cours", de: "CLI / Hook laeuft", pt: "CLI / hook em execucao"),
        "Claude Code is running": localized(zhHant: "Claude Code 正在執行", ja: "Claude Code が実行中", ko: "Claude Code 실행 중", es: "Claude Code en ejecucion", fr: "Claude Code en cours", de: "Claude Code laeuft", pt: "Claude Code em execucao"),
        "Local integration is running": localized(zhHant: "本機接入正在執行", ja: "ローカル連携が実行中", ko: "로컬 연동 실행 중", es: "Integracion local en ejecucion", fr: "Integration locale en cours", de: "Lokale Integration laeuft", pt: "Integracao local em execucao"),
        "Waiting for Permission": localized(zhHant: "等待授權", ja: "権限待ち", ko: "권한 대기 중", es: "Esperando permiso", fr: "Attente d'autorisation", de: "Wartet auf Berechtigung", pt: "Aguardando permissao"),
        "Manual Set": localized(zhHant: "手動設定", ja: "手動設定", ko: "수동 설정", es: "Ajuste manual", fr: "Reglage manuel", de: "Manuell gesetzt", pt: "Definido manualmente"),
        "Thinking": localized(zhHant: "思考中", ja: "考え中", ko: "생각 중", es: "Pensando", fr: "Reflexion", de: "Denkt", pt: "Pensando"),
        "Responding": localized(zhHant: "輸出中", ja: "応答中", ko: "응답 중", es: "Respondiendo", fr: "Reponse en cours", de: "Antwortet", pt: "Respondendo"),
        "No action needed": localized(zhHant: "不用處理", ja: "対応不要", ko: "조치 필요 없음", es: "No requiere accion", fr: "Aucune action requise", de: "Keine Aktion noetig", pt: "Nenhuma acao necessaria"),
        "Review when available": localized(zhHant: "有空看一眼", ja: "時間があるときに確認", ko: "가능할 때 확인", es: "Revisar cuando puedas", fr: "Verifier quand possible", de: "Bei Gelegenheit pruefen", pt: "Revise quando puder"),
        "Needs action now": localized(zhHant: "馬上處理", ja: "今すぐ対応", ko: "지금 조치 필요", es: "Requiere accion ahora", fr: "Action requise maintenant", de: "Jetzt Aktion noetig", pt: "Precisa de acao agora"),
        "Confirm status": localized(zhHant: "確認狀態", ja: "状態を確認", ko: "상태 확인", es: "Confirmar estado", fr: "Confirmer l'etat", de: "Status bestaetigen", pt: "Confirmar status"),
        "Monitoring paused": localized(zhHant: "監控已暫停", ja: "監視は一時停止中", ko: "모니터링 일시 중지됨", es: "Supervision pausada", fr: "Surveillance en pause", de: "Ueberwachung pausiert", pt: "Monitoramento pausado"),
        "Horizontal": localized(zhHant: "橫向", ja: "横向き", ko: "가로", es: "Horizontal", fr: "Horizontal", de: "Horizontal", pt: "Horizontal"),
        "Vertical": localized(zhHant: "直向", ja: "縦向き", ko: "세로", es: "Vertical", fr: "Vertical", de: "Vertikal", pt: "Vertical"),
        "Classic Lamp": localized(zhHant: "經典燈牌", ja: "クラシック", ko: "클래식 램프", es: "Lampara clasica", fr: "Feu classique", de: "Klassische Lampe", pt: "Lampada classica"),
        "Minimal Dots": localized(zhHant: "極簡圓點", ja: "ドット", ko: "미니멀 점", es: "Puntos minimos", fr: "Points minimalistes", de: "Minimalpunkte", pt: "Pontos minimos"),
        "Green breathe": localized(zhHant: "綠燈呼吸", ja: "緑呼吸", ko: "초록 호흡", es: "Verde respira", fr: "Vert respire", de: "Gruen atmet", pt: "Verde respira"),
        "Green breathing": localized(zhHant: "綠燈呼吸", ja: "緑呼吸", ko: "초록 호흡", es: "Respiracion verde", fr: "Respiration verte", de: "Gruenes Atmen", pt: "Respiracao verde"),
        "Thinking effect": localized(zhHant: "思考燈效", ja: "思考効果", ko: "생각 중 효과", es: "Efecto al pensar", fr: "Effet reflexion", de: "Denken Effekt", pt: "Efeito pensando"),
        "Working effect": localized(zhHant: "工作燈效", ja: "作業効果", ko: "작업 중 효과", es: "Efecto trabajando", fr: "Effet travail", de: "Arbeits Effekt", pt: "Efeito trabalhando"),
        "R/Y/G sequence": localized(zhHant: "紅黃綠依序", ja: "赤黄緑順", ko: "빨강/노랑/초록 순서", es: "Secuencia R/A/V", fr: "Sequence R/J/V", de: "R/Gruen Folge", pt: "Sequencia V/A/V"),
        "Red yellow green sequence": localized(zhHant: "紅黃綠依序亮燈", ja: "赤黄緑順に点灯", ko: "빨강 노랑 초록 순차 점등", es: "Rojo amarillo verde secuencial", fr: "Rouge jaune vert sequentiel", de: "Rot Gelb Gruen nacheinander", pt: "Vermelho amarelo verde sequencial"),
        "Slow": localized(zhHant: "慢", ja: "遅い", ko: "느림", es: "Lento", fr: "Lent", de: "Langsam", pt: "Lento"),
        "Fast": localized(zhHant: "快", ja: "速い", ko: "빠름", es: "Rapido", fr: "Rapide", de: "Schnell", pt: "Rapido"),
        "Green fast": localized(zhHant: "綠燈快閃", ja: "緑高速", ko: "초록 빠름", es: "Verde rapido", fr: "Vert rapide", de: "Gruen schnell", pt: "Verde rapido"),
        "Green fast flash": localized(zhHant: "綠燈快閃", ja: "緑の速い点滅", ko: "초록 빠른 깜박임", es: "Verde rapido", fr: "Vert rapide", de: "Gruen schnell blinkend", pt: "Verde rapido"),
        "Green slow": localized(zhHant: "綠燈慢閃", ja: "緑低速", ko: "초록 느림", es: "Verde lento", fr: "Vert lent", de: "Gruen langsam", pt: "Verde lento"),
        "Green slow flash": localized(zhHant: "綠燈慢閃", ja: "緑のゆっくり点滅", ko: "초록 느린 깜박임", es: "Verde lento", fr: "Vert lent", de: "Gruen langsam blinkend", pt: "Verde lento"),
        "Green steady": localized(zhHant: "綠燈常亮", ja: "緑点灯", ko: "초록 계속 켜짐", es: "Verde fijo", fr: "Vert fixe", de: "Gruen dauerhaft", pt: "Verde fixo"),
        "Yellow slow": localized(zhHant: "黃燈慢閃", ja: "黄低速", ko: "노랑 느림", es: "Amarillo lento", fr: "Jaune lent", de: "Gelb langsam", pt: "Amarelo lento"),
        "Yellow slow flash": localized(zhHant: "黃燈慢閃", ja: "黄のゆっくり点滅", ko: "노랑 느린 깜박임", es: "Amarillo lento", fr: "Jaune lent", de: "Gelb langsam blinkend", pt: "Amarelo lento"),
        "Yellow steady": localized(zhHant: "黃燈常亮", ja: "黄点灯", ko: "노랑 계속 켜짐", es: "Amarillo fijo", fr: "Jaune fixe", de: "Gelb dauerhaft", pt: "Amarelo fixo"),
        "All steady": localized(zhHant: "三燈全亮", ja: "全点灯", ko: "모두 켜짐", es: "Todas fijas", fr: "Tout fixe", de: "Alle an", pt: "Todas fixas"),
        "All lights steady": localized(zhHant: "三燈全亮", ja: "全ライト点灯", ko: "세 조명 모두 켜짐", es: "Todas las luces fijas", fr: "Toutes lumieres fixes", de: "Alle Lichter dauerhaft", pt: "Todas as luzes fixas"),
        "All flash": localized(zhHant: "三燈同步閃", ja: "全点滅", ko: "모두 깜박임", es: "Todas parpadean", fr: "Tout clignote", de: "Alle blinken", pt: "Todas piscam"),
        "All lights flash together": localized(zhHant: "三燈同步閃", ja: "全ライト同時点滅", ko: "세 조명 동시 깜박임", es: "Todas las luces parpadean", fr: "Toutes lumieres clignotent", de: "Alle Lichter blinken zusammen", pt: "Todas as luzes piscam juntas"),
        "Soft": localized(zhHant: "弱", ja: "弱", ko: "약함", es: "Suave", fr: "Faible", de: "Schwach", pt: "Suave"),
        "Standard": localized(zhHant: "標準", ja: "標準", ko: "표준", es: "Estandar", fr: "Standard", de: "Standard", pt: "Padrao"),
        "Strong": localized(zhHant: "強", ja: "強", ko: "강함", es: "Fuerte", fr: "Fort", de: "Stark", pt: "Forte"),
        "Horizontal dot size: Small": localized(zhHant: "圓點橫向尺寸：小", ja: "横向きドットサイズ: 小", ko: "가로 점 크기: 작게", es: "Tamano horizontal del punto: pequeno", fr: "Taille horizontale du point : petit", de: "Horizontale Punktgroesse: klein", pt: "Tamanho horizontal do ponto: pequeno"),
        "Vertical lamp size: Large": localized(zhHant: "燈牌直向尺寸：大", ja: "縦向きランプサイズ: 大", ko: "세로 램프 크기: 크게", es: "Tamano vertical de la lampara: grande", fr: "Taille verticale du feu : grand", de: "Vertikale Lampengroesse: gross", pt: "Tamanho vertical da lampada: grande"),
        "Codex auto monitoring is on": localized(zhHant: "Codex 自動監控已開啟", ja: "Codex 自動監視はオン", ko: "Codex 자동 모니터링 켜짐", es: "Supervision automatica de Codex activa", fr: "Surveillance automatique Codex active", de: "Codex Auto-Ueberwachung ist an", pt: "Monitoramento automatico do Codex ativo"),
        "Release info file was not found.": localized(zhHant: "找不到版本資訊檔案。", ja: "リリース情報ファイルが見つかりません。", ko: "릴리스 정보 파일을 찾을 수 없습니다.", es: "No se encontro el archivo de version.", fr: "Fichier d'information de version introuvable.", de: "Release Info Datei wurde nicht gefunden.", pt: "Arquivo de informacoes da versao nao encontrado."),
        "Generic agent hook script was not found.": localized(zhHant: "找不到通用 Agent hook 腳本。", ja: "汎用 Agent hook スクリプトが見つかりません。", ko: "일반 Agent hook 스크립트를 찾을 수 없습니다.", es: "No se encontro el script hook generico.", fr: "Script hook generique introuvable.", de: "Generisches Agent Hook Skript wurde nicht gefunden.", pt: "Script hook generico nao encontrado."),
        "Generic agent hook command copied.": localized(zhHant: "已複製通用 Agent Hook 命令。", ja: "汎用 Agent Hook コマンドをコピーしました。", ko: "일반 Agent Hook 명령을 복사했습니다.", es: "Comando hook generico copiado.", fr: "Commande hook generique copiee.", de: "Generischer Agent Hook Befehl kopiert.", pt: "Comando hook generico copiado."),
        "Exporting diagnostics...": localized(zhHant: "正在匯出診斷...", ja: "診断を書き出しています...", ko: "진단 내보내는 중...", es: "Exportando diagnostico...", fr: "Export des diagnostics...", de: "Diagnose wird exportiert...", pt: "Exportando diagnostico..."),
        "Processing hooks...": localized(zhHant: "正在處理 hooks...", ja: "Hooks を処理しています...", ko: "Hook 처리 중...", es: "Procesando hooks...", fr: "Traitement des hooks...", de: "Hooks werden verarbeitet...", pt: "Processando hooks...")
    ]

    private static let signalNames: [String: [AppLanguage: String]] = [
        "Idle": uiText["Idle"] ?? [:],
        "Thinking": uiText["Thinking"] ?? [:],
        "Working": uiText["Working"] ?? [:],
        "Step Done": uiText["Step Done"] ?? [:],
        "Subagent Started": localized(zhHant: "子 Agent 開始", ja: "サブ Agent 開始", ko: "하위 Agent 시작", es: "Subagent iniciado", fr: "Sous-agent demarre", de: "Subagent gestartet", pt: "Subagent iniciado"),
        "Subagent Done": localized(zhHant: "子 Agent 完成", ja: "サブ Agent 完了", ko: "하위 Agent 완료", es: "Subagent listo", fr: "Sous-agent termine", de: "Subagent fertig", pt: "Subagent concluido"),
        "Needs Review": uiText["Needs Review"] ?? [:],
        "Notification": localized(zhHant: "通知", ja: "通知", ko: "알림", es: "Notificacion", fr: "Notification", de: "Benachrichtigung", pt: "Notificacao"),
        "Done": uiText["Done"] ?? [:],
        "Permission Required": localized(zhHant: "請求授權", ja: "権限が必要", ko: "권한 필요", es: "Permiso requerido", fr: "Autorisation requise", de: "Berechtigung erforderlich", pt: "Permissao necessaria"),
        "Waiting for Permission": uiText["Waiting for Permission"] ?? [:],
        "Blocked": uiText["Blocked"] ?? [:],
        "Failed": localized(zhHant: "失敗", ja: "失敗", ko: "실패", es: "Fallido", fr: "Echec", de: "Fehlgeschlagen", pt: "Falhou"),
        "Error": localized(zhHant: "錯誤", ja: "エラー", ko: "오류", es: "Error", fr: "Erreur", de: "Fehler", pt: "Erro"),
        "Exception": localized(zhHant: "例外", ja: "例外", ko: "예외", es: "Excepcion", fr: "Exception", de: "Ausnahme", pt: "Excecao"),
        "Context Blocked": localized(zhHant: "上下文阻塞", ja: "コンテキストで停止", ko: "컨텍스트 차단", es: "Contexto bloqueado", fr: "Contexte bloque", de: "Kontext blockiert", pt: "Contexto bloqueado"),
        "Stale": localized(zhHant: "狀態不可信", ja: "状態が古い", ko: "상태 오래됨", es: "Desactualizado", fr: "Obsolete", de: "Veraltet", pt: "Desatualizado"),
        "Session Started": localized(zhHant: "會話開始", ja: "セッション開始", ko: "세션 시작", es: "Sesion iniciada", fr: "Session demarree", de: "Sitzung gestartet", pt: "Sessao iniciada"),
        "Session Ended": localized(zhHant: "會話結束", ja: "セッション終了", ko: "세션 종료", es: "Sesion terminada", fr: "Session terminee", de: "Sitzung beendet", pt: "Sessao encerrada"),
        "Turn Ended": localized(zhHant: "回合結束", ja: "ターン終了", ko: "턴 종료", es: "Turno terminado", fr: "Tour termine", de: "Runde beendet", pt: "Turno encerrado"),
        "Off": uiText["Off"] ?? [:],
        "Paused": uiText["Paused"] ?? [:]
    ]

    private static let signalSummaries: [String: [AppLanguage: String]] = [
        "Agent is idle.": localized(zhHant: "Agent 空閒。", ja: "Agent は待機中です。", ko: "Agent가 유휴 상태입니다.", es: "El Agent esta inactivo.", fr: "L'agent est inactif.", de: "Der Agent ist im Leerlauf.", pt: "O Agent esta ocioso."),
        "Agent has received the task and is thinking.": localized(zhHant: "Agent 已收到任務，正在思考。", ja: "Agent はタスクを受け取り考えています。", ko: "Agent가 작업을 받고 생각 중입니다.", es: "El Agent recibio la tarea y esta pensando.", fr: "L'agent a recu la tache et reflechit.", de: "Der Agent hat die Aufgabe erhalten und denkt.", pt: "O Agent recebeu a tarefa e esta pensando."),
        "Agent is reading files, running tools, or testing.": localized(zhHant: "Agent 正在讀寫檔案、執行工具或測試。", ja: "Agent はファイル確認、ツール実行、またはテスト中です。", ko: "Agent가 파일을 읽거나 도구를 실행하거나 테스트 중입니다.", es: "El Agent lee archivos, ejecuta herramientas o prueba.", fr: "L'agent lit des fichiers, lance des outils ou teste.", de: "Der Agent liest Dateien, fuehrt Tools aus oder testet.", pt: "O Agent le arquivos, executa ferramentas ou testa."),
        "A step finished; the workflow may continue.": localized(zhHant: "一個步驟已完成，工作流可能繼續。", ja: "ステップが完了し、作業は続く可能性があります。", ko: "단계가 끝났고 워크플로가 계속될 수 있습니다.", es: "Un paso termino; el flujo puede continuar.", fr: "Une etape est terminee; le flux peut continuer.", de: "Ein Schritt ist fertig; der Ablauf kann weitergehen.", pt: "Uma etapa terminou; o fluxo pode continuar."),
        "A tool call finished; the workflow may continue.": localized(zhHant: "一次工具呼叫完成，工作流可能繼續。", ja: "ツール呼び出しが完了し、作業は続く可能性があります。", ko: "도구 호출이 끝났고 워크플로가 계속될 수 있습니다.", es: "Una herramienta termino; el flujo puede continuar.", fr: "Un appel d'outil est termine; le flux peut continuer.", de: "Ein Tool Aufruf ist fertig; der Ablauf kann weitergehen.", pt: "Uma ferramenta terminou; o fluxo pode continuar."),
        "A subagent is running.": localized(zhHant: "子 Agent 正在執行。", ja: "サブ Agent が実行中です。", ko: "하위 Agent가 실행 중입니다.", es: "Un subagent esta ejecutandose.", fr: "Un sous-agent est en cours.", de: "Ein Subagent laeuft.", pt: "Um subagent esta em execucao."),
        "A subagent finished; the main workflow may continue.": localized(zhHant: "子 Agent 已完成，主工作流可能繼續。", ja: "サブ Agent が完了し、メイン作業は続く可能性があります。", ko: "하위 Agent가 완료되었고 주 흐름은 계속될 수 있습니다.", es: "Un subagent termino; el flujo principal puede continuar.", fr: "Un sous-agent est termine; le flux principal peut continuer.", de: "Ein Subagent ist fertig; der Hauptablauf kann weitergehen.", pt: "Um subagent terminou; o fluxo principal pode continuar."),
        "Agent needs you to review or continue.": localized(zhHant: "Agent 需要你查看或繼續。", ja: "Agent は確認または続行を必要としています。", ko: "Agent가 검토 또는 계속 진행을 필요로 합니다.", es: "El Agent necesita que revises o continues.", fr: "L'agent a besoin d'une verification ou suite.", de: "Der Agent braucht Pruefung oder Fortsetzung.", pt: "O Agent precisa que voce revise ou continue."),
        "Agent sent a notification that needs review.": localized(zhHant: "Agent 發出了需要查看的通知。", ja: "Agent が確認必要な通知を送信しました。", ko: "Agent가 검토가 필요한 알림을 보냈습니다.", es: "El Agent envio una notificacion para revisar.", fr: "L'agent a envoye une notification a verifier.", de: "Der Agent hat eine zu pruefende Benachrichtigung gesendet.", pt: "O Agent enviou uma notificacao para revisar."),
        "Task is complete.": localized(zhHant: "任務完成。", ja: "タスクは完了しました。", ko: "작업이 완료되었습니다.", es: "La tarea esta completa.", fr: "La tache est terminee.", de: "Die Aufgabe ist abgeschlossen.", pt: "A tarefa foi concluida."),
        "Agent is requesting permission or approval.": localized(zhHant: "Agent 正在請求權限或批准。", ja: "Agent は権限または承認を要求しています。", ko: "Agent가 권한 또는 승인을 요청 중입니다.", es: "El Agent solicita permiso o aprobacion.", fr: "L'agent demande une autorisation.", de: "Der Agent fordert Berechtigung oder Zustimmung an.", pt: "O Agent pede permissao ou aprovacao."),
        "Agent is waiting for user authorization.": localized(zhHant: "Agent 正在等待使用者授權。", ja: "Agent はユーザー承認を待っています。", ko: "Agent가 사용자 승인을 기다립니다.", es: "El Agent espera autorizacion del usuario.", fr: "L'agent attend l'autorisation utilisateur.", de: "Der Agent wartet auf Benutzerfreigabe.", pt: "O Agent aguarda autorizacao do usuario."),
        "Agent hit a failure, blocker, or cannot continue.": localized(zhHant: "Agent 遇到失敗、阻塞或無法繼續。", ja: "Agent は失敗またはブロックで続行できません。", ko: "Agent가 실패, 차단 또는 진행 불가 상태입니다.", es: "El Agent encontro un fallo o bloqueo.", fr: "L'agent a rencontre un echec ou blocage.", de: "Der Agent ist auf Fehler oder Blocker gestossen.", pt: "O Agent encontrou falha ou bloqueio."),
        "Agent or tool reported a failure.": localized(zhHant: "Agent 或工具回報失敗。", ja: "Agent またはツールが失敗を報告しました。", ko: "Agent 또는 도구가 실패를 보고했습니다.", es: "El Agent o una herramienta informo un fallo.", fr: "L'agent ou un outil a signale un echec.", de: "Agent oder Tool meldete einen Fehler.", pt: "O Agent ou ferramenta relatou falha."),
        "Agent or tool reported an error.": localized(zhHant: "Agent 或工具回報錯誤。", ja: "Agent またはツールがエラーを報告しました。", ko: "Agent 또는 도구가 오류를 보고했습니다.", es: "El Agent o una herramienta informo un error.", fr: "L'agent ou un outil a signale une erreur.", de: "Agent oder Tool meldete einen Fehler.", pt: "O Agent ou ferramenta relatou erro."),
        "Agent or tool reported an exception.": localized(zhHant: "Agent 或工具回報例外。", ja: "Agent またはツールが例外を報告しました。", ko: "Agent 또는 도구가 예외를 보고했습니다.", es: "El Agent o una herramienta informo una excepcion.", fr: "L'agent ou un outil a signale une exception.", de: "Agent oder Tool meldete eine Ausnahme.", pt: "O Agent ou ferramenta relatou excecao."),
        "Agent cannot continue because of context or token limits.": localized(zhHant: "Agent 因上下文或 token 限制無法繼續。", ja: "Agent はコンテキストまたは token 制限で続行できません。", ko: "Agent가 컨텍스트 또는 token 제한으로 계속할 수 없습니다.", es: "El Agent no puede continuar por limites de contexto o tokens.", fr: "L'agent ne peut pas continuer a cause des limites de contexte ou tokens.", de: "Der Agent kann wegen Kontext- oder Tokenlimits nicht fortfahren.", pt: "O Agent nao pode continuar por limites de contexto ou tokens."),
        "The status file is stale, corrupt, or unreliable.": localized(zhHant: "狀態檔案過期、損壞，或目前狀態不可信。", ja: "状態ファイルが古い、壊れている、または信頼できません。", ko: "상태 파일이 오래되었거나 손상되었거나 신뢰할 수 없습니다.", es: "El archivo de estado esta viejo, danado o no es fiable.", fr: "Le fichier d'etat est ancien, corrompu ou peu fiable.", de: "Die Statusdatei ist veraltet, beschaedigt oder unzuverlaessig.", pt: "O arquivo de status esta antigo, corrompido ou nao confiavel."),
        "Monitoring is paused.": localized(zhHant: "監控已暫停。", ja: "監視は一時停止中です。", ko: "모니터링이 일시 중지되었습니다.", es: "La supervision esta pausada.", fr: "La surveillance est en pause.", de: "Die Ueberwachung ist pausiert.", pt: "O monitoramento esta pausado.")
    ]

    private static func englishSignalName(_ signal: AgentSignal) -> String {
        switch signal {
        case .idle:
            return "Idle"
        case .thinking:
            return "Thinking"
        case .working:
            return "Working"
        case .toolDone:
            return "Step Done"
        case .subagentStart:
            return "Subagent Started"
        case .subagentStop:
            return "Subagent Done"
        case .attention:
            return "Needs Review"
        case .notification:
            return "Notification"
        case .done:
            return "Done"
        case .permission:
            return "Permission Required"
        case .permissionRequest:
            return "Waiting for Permission"
        case .blocked:
            return "Blocked"
        case .failure:
            return "Failed"
        case .error:
            return "Error"
        case .exception:
            return "Exception"
        case .maxTokens:
            return "Context Blocked"
        case .stale:
            return "Stale"
        case .sessionStart:
            return "Session Started"
        case .sessionEnd:
            return "Session Ended"
        case .turnEnd:
            return "Turn Ended"
        case .off:
            return "Off"
        case .pause, .paused:
            return "Paused"
        }
    }

    private static func englishSignalSummary(_ signal: AgentSignal) -> String {
        switch signal {
        case .idle, .sessionStart, .sessionEnd, .turnEnd:
            return "Agent is idle."
        case .thinking:
            return "Agent has received the task and is thinking."
        case .working:
            return "Agent is reading files, running tools, or testing."
        case .toolDone:
            return "A step finished; the workflow may continue."
        case .subagentStart:
            return "A subagent is running."
        case .subagentStop:
            return "A subagent finished; the main workflow may continue."
        case .attention:
            return "Agent needs you to review or continue."
        case .notification:
            return "Agent sent a notification that needs review."
        case .done:
            return "Task is complete."
        case .permission:
            return "Agent is requesting permission or approval."
        case .permissionRequest:
            return "Agent is waiting for user authorization."
        case .blocked:
            return "Agent hit a failure, blocker, or cannot continue."
        case .failure:
            return "Agent or tool reported a failure."
        case .error:
            return "Agent or tool reported an error."
        case .exception:
            return "Agent or tool reported an exception."
        case .maxTokens:
            return "Agent cannot continue because of context or token limits."
        case .stale:
            return "The status file is stale, corrupt, or unreliable."
        case .off, .pause, .paused:
            return "Monitoring is paused."
        }
    }
}
