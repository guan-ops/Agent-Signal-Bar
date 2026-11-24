; Agent Signal Bar for Windows: the installer (Inno Setup 6.7). package.ps1 builds it:
;   ISCC /DAppVersion=1.7.0 /DAppBuild=24 /DSourceDir=<staged app folder> /DOutputDir=<dist> /DOutputName=<name> AgentSignalBar.iss
;
; Per-user, no administrator rights: it installs to %LOCALAPPDATA%\Programs\AgentSignalBar like
; build.ps1, so the in-app updater (UpdateService) can run it silently:
;   setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /UPDATE=1 /RELAUNCH=1 /DIR=<app folder>
; With /UPDATE=1 it waits for the running app (mutex AgentSignalBarRunning) to quit first.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef AppBuild
  #define AppBuild "0"
#endif
#ifndef SourceDir
  #error Define SourceDir: the staged app folder (build.ps1 -InstallDir)
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputName
  #define OutputName "AgentSignalBar-setup"
#endif

[Setup]
AppId={{16343113-1624-4D58-B911-4EB9F0F0408F}
AppName=Agent Signal Bar
AppVersion={#AppVersion}
AppVerName=Agent Signal Bar {#AppVersion}
AppPublisher=XiongYang Guan
AppPublisherURL=https://github.com/guan-ops/Agent-Signal-Bar
AppSupportURL=https://github.com/guan-ops/Agent-Signal-Bar/issues
AppUpdatesURL=https://github.com/guan-ops/Agent-Signal-Bar/releases
AppCopyright=Copyright 2026 XiongYang Guan
VersionInfoVersion={#AppVersion}.{#AppBuild}
VersionInfoProductName=Agent Signal Bar
VersionInfoDescription=Agent Signal Bar Setup
DefaultDirName={localappdata}\Programs\AgentSignalBar
DefaultGroupName=Agent Signal Bar
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Qt 6.8 needs Windows 10 1809 or newer.
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\resources\AgentSignalBar.ico
UninstallDisplayIcon={app}\AgentSignalBar.exe
UninstallDisplayName=Agent Signal Bar
LicenseFile=..\..\..\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The running app is detected through its mutex in [Code], so no Restart Manager prompts.
CloseApplications=no
ShowLanguageDialog=auto
#ifdef SignToolName
SignTool={#SignToolName}
SignedUninstaller=yes
#endif

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
; Chinese ships with Inno Setup 7; for 6.x the 6.7 translations are bundled (from jrsoftware/issrc).
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "zh_CN"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "zh_TW"; MessagesFile: "compiler:Languages\ChineseTraditional.isl"
#else
Name: "zh_CN"; MessagesFile: "Languages\ChineseSimplified.isl"
Name: "zh_TW"; MessagesFile: "Languages\ChineseTraditional.isl"
#endif
Name: "ja"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "ko"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "pt"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[CustomMessages]
en.RemoveHooks=Also remove the Agent Signal Bar hooks from Claude Code and Codex?%n%nHooks left behind point at the removed agent-signal.exe and show errors in those tools.
zh_CN.RemoveHooks=同时从 Claude Code 和 Codex 中移除 Agent Signal Bar 的 Hook 吗？%n%n留下的 Hook 会指向已删除的 agent-signal.exe，并在这些工具中报错。
zh_TW.RemoveHooks=同時從 Claude Code 和 Codex 中移除 Agent Signal Bar 的 Hook 嗎？%n%n留下的 Hook 會指向已刪除的 agent-signal.exe，並在這些工具中報錯。
ja.RemoveHooks=Claude Code と Codex から Agent Signal Bar のフックも削除しますか？%n%n残ったフックは削除された agent-signal.exe を指し、エラーになります。
ko.RemoveHooks=Claude Code와 Codex에서 Agent Signal Bar 후크도 제거할까요?%n%n남은 후크는 삭제된 agent-signal.exe를 가리켜 오류가 납니다.
es.RemoveHooks=¿Quitar también los hooks de Agent Signal Bar de Claude Code y Codex?%n%nLos hooks que queden apuntan al agent-signal.exe eliminado y muestran errores.
fr.RemoveHooks=Supprimer aussi les hooks d'Agent Signal Bar de Claude Code et Codex ?%n%nLes hooks restants pointent vers agent-signal.exe supprimé et affichent des erreurs.
de.RemoveHooks=Auch die Agent-Signal-Bar-Hooks aus Claude Code und Codex entfernen?%n%nVerbleibende Hooks zeigen auf die entfernte agent-signal.exe und melden Fehler.
pt.RemoveHooks=Remover também os hooks do Agent Signal Bar do Claude Code e do Codex?%n%nHooks restantes apontam para o agent-signal.exe removido e mostram erros.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; windeployqt output that a newer Qt may lay out differently.
Type: filesandordirs; Name: "{app}\qml"

[UninstallDelete]
; Folders Setup did not create (an install over a build.ps1 folder) stay behind unless removed here;
; dirifempty never deletes anything a user put there.
Type: dirifempty; Name: "{app}\generic"
Type: dirifempty; Name: "{app}\iconengines"
Type: dirifempty; Name: "{app}\imageformats"
Type: dirifempty; Name: "{app}\networkinformation"
Type: dirifempty; Name: "{app}\platforms"
Type: dirifempty; Name: "{app}\qmltooling"
Type: dirifempty; Name: "{app}\styles"
Type: dirifempty; Name: "{app}\tls"
Type: dirifempty; Name: "{app}\translations"
Type: dirifempty; Name: "{app}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Agent Signal Bar"; Filename: "{app}\AgentSignalBar.exe"
Name: "{autodesktop}\Agent Signal Bar"; Filename: "{app}\AgentSignalBar.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\AgentSignalBar.exe"; Description: "{cm:LaunchProgram,Agent Signal Bar}"; Flags: nowait postinstall skipifsilent
; An in-app update: start the new version once the files are in place.
Filename: "{app}\AgentSignalBar.exe"; Flags: nowait; Check: RelaunchAfterUpdate

[Code]
var
  RemoveHooks: Boolean;

function IsUpdate(): Boolean;
begin
  Result := ExpandConstant('{param:UPDATE|0}') = '1';
end;

function RelaunchAfterUpdate(): Boolean;
begin
  Result := IsUpdate() and (ExpandConstant('{param:RELAUNCH|0}') = '1');
end;

function AppRunning(): Boolean;
begin
  Result := CheckForMutexes('AgentSignalBarRunning');
end;

// Waits up to `Seconds` for the app to quit.
function WaitForAppExit(Seconds: Integer): Boolean;
var
  I: Integer;
begin
  for I := 1 to Seconds * 4 do
  begin
    if not AppRunning() then Break;
    Sleep(250);
  end;
  Result := not AppRunning();
end;

// The app must not run while its files are replaced or removed. An in-app update quits by itself;
// otherwise ask, as Inno's AppMutex does.
function EnsureAppClosed(const Message: String; Silent: Boolean): Boolean;
begin
  Result := True;
  if Silent then
  begin
    Result := WaitForAppExit(30);
    Exit;
  end;
  while AppRunning() do
  begin
    if MsgBox(FmtMessage(Message, ['Agent Signal Bar']), mbError, MB_OKCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := EnsureAppClosed(SetupMessage(msgSetupAppRunningError), IsUpdate() or WizardSilent());
end;

function InitializeUninstall(): Boolean;
begin
  Result := EnsureAppClosed(SetupMessage(msgUninstallAppRunningError), UninstallSilent());
  if Result then
    RemoveHooks := UninstallSilent() or (MsgBox(CustomMessage('RemoveHooks'), mbConfirmation, MB_YESNO) = IDYES);
end;

// Drops `Dir` from the user's PATH (the app's "Install CLI" adds it).
procedure RemoveFromUserPath(const Dir: String);
var
  Path, Entry, Kept: String;
  P: Integer;
  Changed: Boolean;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path) then Exit;
  Kept := '';
  Changed := False;
  Path := Path + ';';
  while Length(Path) > 0 do
  begin
    P := Pos(';', Path);
    Entry := Copy(Path, 1, P - 1);
    Delete(Path, 1, P);
    if Entry = '' then Continue;
    if CompareText(RemoveBackslashUnlessRoot(Entry), RemoveBackslashUnlessRoot(Dir)) = 0 then
    begin
      Changed := True;
      Continue;
    end;
    if Kept <> '' then Kept := Kept + ';';
    Kept := Kept + Entry;
  end;
  if Changed then RegWriteExpandStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Kept);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  // Before the files go: agent-signal.exe removes its own hooks, from Claude Code, the default
  // Codex home and the Codex folder chosen in the app (it reads the app's settings itself).
  // ([UninstallRun] cannot do this: its Check runs at install time, before the question is asked.)
  if (CurUninstallStep = usUninstall) and RemoveHooks then
    Exec(ExpandConstant('{app}\agent-signal.exe'), 'install-hooks --install --remove', '', SW_HIDE,
         ewWaitUntilTerminated, ResultCode);
  if CurUninstallStep = usPostUninstall then
  begin
    // Start at login (AppController::applyLaunchAtLogin) and the CLI folder on PATH.
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'AgentSignalBar');
    RemoveFromUserPath(ExpandConstant('{app}'));
  end;
end;
