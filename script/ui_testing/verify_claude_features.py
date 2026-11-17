#!/usr/bin/env python3
"""Run the packaged app with synthetic CLI/logs and deny real home, keychain, preferences and all network."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=False)
app = root / 'Claude Features Test.app'
subprocess.run(['/usr/bin/ditto', str(args.app), str(app)], check=True)
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['CFBundleIdentifier'] = 'com.agentsignallight.claude-features.' + uuid.uuid4().hex
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
isolation = root / 'isolation.sb'
isolation.write_text('(version 1)\n(allow default)\n(deny network*)\n'
    '(deny file-read* file-write* (subpath ' + json.dumps(str(Path.home())) + '))\n'
    '(deny mach-lookup (global-name "com.apple.securityd") '
    '(global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))\n')
results = []
for case in ['clean-no-login', 'cli', 'automatic-cli', 'cli-login-required', 'web-disabled']:
    profile = root / case
    projects = profile / '.claude/projects/fixture'
    desktop = profile / 'Library/Application Support/Claude/local-agent-mode-sessions/org/session'
    projects.mkdir(parents=True)
    desktop.mkdir(parents=True)
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    def row(message, incomplete=False):
        return {'type': 'assistant', 'timestamp': timestamp, 'session_id': 'fixture-session',
            'message': {'id': message, 'model': 'claude-sonnet-4-6', 'stop_reason': None if incomplete else 'end_turn',
                'usage': {'input_tokens': 100, 'output_tokens': 0 if incomplete else 20}}}
    (projects / 'native.jsonl').write_text(json.dumps(row('shared')) + '\n')
    (desktop / 'audit.jsonl').write_text(json.dumps(row('shared')) + '\n' + json.dumps(row('pending', True)) + '\n')
    cli = profile / 'fixture-cli'
    output = 'Please run /login' if case == 'cli-login-required' else 'Current session\\n32%% used\\nResets in 2h\\nCurrent week (all models)\\n60%% used\\nResets in 2d'
    cli.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > probe-args.txt\nread command\n'
        'if [ "$command" = /usage ]; then\n  printf "' + output + '\\n"\nfi\n')
    cli.chmod(0o700)
    health = profile / 'health.json'
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'CFFIXED_USER_HOME': str(profile),
        'CODEX_HOME': str(profile / '.codex'), 'TMPDIR': str(profile),
        'AGENT_SIGNAL_LIGHT_STATE_FILE': str(profile / 'status.json'),
        'AGENT_SIGNAL_LIGHT_STATUS_ITEM_HEALTH_FILE': str(health)}
    def hook(event):
        result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(isolation),
            str(app / 'Contents/Resources/scripts/claude-code-signal-hook')], env=env,
            input=json.dumps({'hook_event_name': event, 'session_id': 'fixture-hook'}),
            text=True, capture_output=True, timeout=5)
        assert result.returncode == 0
    hook('UserPromptSubmit')
    source = 'automatic' if case == 'automatic-cli' else ('web' if case == 'web-disabled' else ('cli' if case.startswith('cli') else 'oauth'))
    command = ['/usr/bin/sandbox-exec', '-f', str(isolation), str(app / 'Contents/MacOS/AgentSignalLight'),
        '-settingsPreferenceDefaultsVersion', '1', '-codexOpenAICookieMode', 'off', '-codexUsageDataSource', 'oauth-api',
        '-claude.credentialConsent', 'NO', '-claude.providerSource', source, '-claude.cliFallback', 'YES',
        '-claude.cliBackground', 'YES', '-claude.webEnabled', 'NO', '-claude.executablePath', str(cli),
        '-isFloatingSignalSoundEnabled', 'NO', '-isFloatingSignalEnabled', 'YES',
        '-isFloatingSignalQuotaBadgeEnabled', 'YES', '-isFloatingSignalTokenBadgeEnabled', 'YES', '-appLanguage', 'en']
    with (profile / 'runtime.log').open('w') as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        def observe(label, predicate):
            observed = {}; stable = None
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    observed = json.loads(health.read_text())
                    if predicate(observed):
                        if stable is None: stable = time.monotonic()
                        elif time.monotonic() - stable > 1:
                            results.append({'case': case + ': ' + label, 'passed': True, 'health': observed})
                            (root / 'results.json').write_text(json.dumps(results, indent=2))
                            print(case, label, True, flush=True)
                            return
                    else: stable = None
                except (ValueError, OSError): pass
                time.sleep(.15)
            results.append({'case': case + ': ' + label, 'passed': False, 'health': observed, 'exit': process.poll()})
            (root / 'results.json').write_text(json.dumps(results, indent=2))
            raise AssertionError(case + ': ' + label)
        try:
            observe('deduplicated Cowork/native history', lambda d: d.get('floating_usage_provider') == 'Claude'
                and d.get('floating_usage_tokens') == 120 and d.get('claude_history_incomplete') == 1)
            if case in ['cli', 'automatic-cli']:
                observe('passive CLI quota', lambda d: d.get('claude_source') == 'Claude CLI'
                    and d.get('claude_badge') == '68%' and d.get('claude_window_count') == 2 and d.get('claude_quota_available') is True)
                args_path = profile / 'Library/Application Support/AgentSignalLight/ClaudeProbe/probe-args.txt'
                captured = args_path.read_text()
                assert '--allowed-tools\n\n' in captured and '--strict-mcp-config' in captured and 'disableAllHooks' in captured
                hook('PermissionRequest')
                observe('permission light', lambda d: d.get('aggregate') == 'permission')
                hook('Stop')
                observe('completion light', lambda d: d.get('aggregate') == 'done')
            else:
                observe('unavailable quota stays unknown', lambda d: d.get('claude_quota_available') is False
                    and d.get('claude_source') is None and d.get('claude_badge') == '—')
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
print('All', len(results), 'packaged Claude checks passed.', flush=True)
