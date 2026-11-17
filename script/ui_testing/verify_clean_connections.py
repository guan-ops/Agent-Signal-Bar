#!/usr/bin/env python3
"""Packaged-app acceptance test. Only synthetic profiles; never uses real accounts.
Run outside the host execution restrictions so the child macOS isolation policy can apply.
The test app is a copied, separately identified and ad-hoc-signed bundle, not a rebuild.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--interactive', action='store_true')
args = parser.parse_args()
r = args.output.resolve()
r.mkdir(parents=True, exist_ok=False)
app = r / 'Connection Repair Test.app'
subprocess.run(['/usr/bin/ditto', str(args.app), str(app)], check=True)
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['CFBundleIdentifier'] = 'com.agentsignallight.connectiontest.' + uuid.uuid4().hex
info['CFBundleDisplayName'] = 'Connection Repair Test'
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
profile = r / 'isolation.sb'
# Native child processes cannot invoke any Python or access this user's data/keychain/network.
real_user = str(Path.home())
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n'
    + '(deny file-read* file-write* (subpath ' + json.dumps(real_user) + '))\n'
    + '(deny process-exec (regex #".*/python[0-9.]*$"))\n'
    + '(deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))\n')
res = app / 'Contents/Resources'
cli = res / 'dist/bin/agent-signal'
checks = []

def isolated(command, env, **kwargs):
    return subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile)] + [str(x) for x in command],
        env=env, capture_output=True, text=True, timeout=20, **kwargs)

def record(label, passed, **detail):
    checks.append(dict(case=label, passed=passed, **detail))
    (r/'results.json').write_text(json.dumps(checks, indent=2, ensure_ascii=False))
    print(label, 'PASS' if passed else 'FAIL', flush=True)
    if not passed: raise AssertionError(label)

for mode in ['environment', 'saved-selection']:
    f = r / mode
    f.mkdir()
    custom = f / 'custom-codex'
    selected = custom if mode == 'environment' else f / 'selected-codex'
    state = f / 'status.json'; health = f / 'health.json'
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR': str(f), 'CFFIXED_USER_HOME': str(f),
        'CODEX_HOME': str(custom), 'AGENT_SIGNAL_LIGHT_STATE_FILE': str(state),
        'AGENT_SIGNAL_LIGHT_STATUS_ITEM_HEALTH_FILE': str(health)}
    launch = ['/usr/bin/sandbox-exec', '-f', str(profile), str(app/'Contents/MacOS/AgentSignalLight'),
        '-settingsPreferenceDefaultsVersion', '1', '-codexOpenAICookieMode', 'off',
        '-appLanguage', 'en', '-isDebugFileLoggingEnabled', 'NO', '-isFloatingSignalSoundEnabled', 'NO',
        '-isFloatingSignalEnabled', 'YES', '-isCodexDesktopMonitoringEnabled', 'YES']
    if mode == 'saved-selection': launch += ['-codexActivityDataDirectory', str(selected)]
    if args.interactive and mode == 'saved-selection': launch += ['--debug-window']
    log = (f/'runtime.log').open('w')
    proc = subprocess.Popen(launch, env=env, stdout=log, stderr=log)
    def await_health(label, predicate, timeout=20):
        end = time.monotonic()+timeout
        data = {}
        while time.monotonic()<end and proc.poll() is None:
            try:
                data = json.loads(health.read_text())
                if predicate(data):
                    record(mode+' '+label, True, health=data)
                    return data
            except (OSError, ValueError): pass
            time.sleep(.15)
        record(mode+' '+label, False, health=data, process_exit=proc.poll())
    try:
        await_health('startup missing-directory message', lambda h: h['aggregate']=='idle' and 'No session directory' in h.get('codex_connection',''))
        record(mode+' directory selection', json.loads(health.read_text())['codex_data_directory']==str(selected))
        denied = isolated(['/usr/bin/python3', '--version'], env)
        record(mode+' Python execution denied', denied.returncode!=0)
        sessions = selected/'sessions'
        sessions.mkdir(parents=True)
        await_health('empty-directory message', lambda h: 'No session logs' in h.get('codex_connection',''))
        sessions.rmdir(); sessions.write_text('not a directory')
        await_health('invalid-directory message', lambda h: 'Cannot read directory' in h.get('codex_connection',''))
        sessions.unlink(); sessions.mkdir()
        for source, originator in [('desktop','Codex Desktop'),('cli','codex_cli_rs')]:
            file = sessions / ('rollout-'+source+'.jsonl')
            def append(typ, payload):
                with file.open('a') as out:
                    out.write(json.dumps({'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'type':typ,'payload':payload})+'\n')
            append('session_meta', {'id':'fixture-'+source,'source':source,'originator':originator})
            for typ,payload,want in [('event_msg',{'type':'task_started'},'thinking'),
                    ('response_item',{'type':'function_call','name':'exec_command'},'working'),
                    ('event_msg',{'type':'task_complete'},'done')]:
                append(typ,payload)
                await_health(source+' '+want, lambda h,want=want: h['aggregate']==want and h['image_exists'])
        # Install using precisely the same native engine as the settings actions.
        claude=f/'.claude/settings.json';claude.parent.mkdir()
        claude.write_text(json.dumps({'fixturePreference':'preserve','hooks':{'WorktreeCreate':[{'hooks':[
            {'type':'command','command':"'/old/Agent Signal Bar/scripts/claude-code-signal-hook'"},
            {'type':'command','command':'/fixture/foreign-worktree'}]}]}}))
        command = [cli,'install-hooks','--resources',res,'--home',f,'--codex-home',selected,'--target','all','--install']
        install = isolated(command, env)
        record(mode+' native installation without Python', install.returncode==0, output=install.stdout, error=install.stderr)
        data=json.loads(claude.read_text())
        record(mode+' preserve foreign configuration', data['fixturePreference']=='preserve' and data['hooks']['WorktreeCreate'][0]['hooks']==[{'type':'command','command':'/fixture/foreign-worktree'}])
        again=isolated(command,env)
        record(mode+' idempotent install', again.returncode==0 and again.stdout.count('already configured')==2)
        # A fresh app process verifies the installed config using its own bundle URL,
        # including any /tmp vs /private/tmp aliases used by the CLI.
        proc.terminate()
        proc.wait(timeout=5)
        proc = subprocess.Popen(launch, env=env, stdout=log, stderr=log)
        await_health('configured awaiting event message after restart',
            lambda h: 'Hooks configured; no event received yet' in h.get('claude_connection',''))
        for provider,config in [('codex',selected/'hooks.json'),('claude',claude)]:
            cfg=json.loads(config.read_text())
            for event,want in [('UserPromptSubmit','thinking'),('PreToolUse','working'),('PermissionRequest','permission'),('Stop','done')]:
                hook=cfg['hooks'][event][-1]['hooks'][0]['command']
                emitted=isolated(['/bin/bash','-c',hook],env,input=json.dumps({'hook_event_name':event,'session_id':'fixture-'+provider}))
                record(mode+' '+provider+' '+event+' command',emitted.returncode==0)
                await_health(provider+' hook '+want, lambda h,want=want: h['aggregate']==want)
        if args.interactive and mode=='saved-selection':
            (r/'interactive-ready.json').write_text(json.dumps({'app':str(app),'home':str(f),'pid':proc.pid}))
            # Wait for UI inspection while callers remain free to report progress.
            deadline=time.monotonic()+600
            while not (r/'finish-ui').exists() and time.monotonic()<deadline and proc.poll() is None: time.sleep(.2)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:proc.wait(timeout=5)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        log.close()
print('All packaged checks passed.',flush=True)
