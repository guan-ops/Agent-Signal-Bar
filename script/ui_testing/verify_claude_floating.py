#!/usr/bin/env python3
"""Read only synthetic Claude history in a fresh, network/keychain-isolated packaged app."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--token-window', choices=['today', 'last-30-days'], default='today')
a=p.parse_args();r=a.output.resolve();r.mkdir(parents=True,exist_ok=False)
app=r/'Claude Floating Test.app';subprocess.run(['/usr/bin/ditto',str(a.app),str(app)],check=True)
info=app/'Contents/Info.plist';data=plistlib.loads(info.read_bytes());data['CFBundleIdentifier']='com.agentsignallight.claudefloat.'+uuid.uuid4().hex;info.write_bytes(plistlib.dumps(data))
subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(app)],check=True,capture_output=True)
f=r/'profile';f.mkdir();profile=r/'isolation.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-read* file-write* (subpath '+json.dumps(str(Path.home()))+'))\n(deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))\n')
health=f/'health.json';state=f/'status.json'
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','CFFIXED_USER_HOME':str(f),'CODEX_HOME':str(f/'.codex'),'CLAUDE_CONFIG_DIR':str(f/'.claude'),'TMPDIR':str(f),'AGENT_SIGNAL_LIGHT_STATE_FILE':str(state),'AGENT_SIGNAL_LIGHT_STATUS_ITEM_HEALTH_FILE':str(health)}
res=app/'Contents/Resources';checks=[]
def record(name,passed,**details):
 checks.append(dict(case=name,passed=passed,**details));(r/'results.json').write_text(json.dumps(checks,indent=2));print(name,passed,flush=True)
 if not passed:raise AssertionError(name)
def hook(provider,event):
 path=res/'scripts'/('claude-code-signal-hook' if provider=='claude' else 'codex-signal-hook')
 result=subprocess.run(['/usr/bin/sandbox-exec','-f',str(profile),str(path)],env=env,input=json.dumps({'hook_event_name':event,'session_id':'fixture-'+provider}),text=True,capture_output=True,timeout=5)
 assert result.returncode==0
root=f/'.claude/projects/fixture';root.mkdir(parents=True)
now=datetime.datetime.now(datetime.timezone.utc).isoformat()
(root/'session.jsonl').write_text(json.dumps({'type':'assistant','timestamp':now,'sessionId':'fixture','requestId':'fixture','message':{'id':'fixture','model':'claude-sonnet-4-6','usage':{'input_tokens':800,'output_tokens':200}}})+'\n')
yesterday=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1)).isoformat()
with (root/'session.jsonl').open('a') as history:
 history.write(json.dumps({'type':'assistant','timestamp':yesterday,'sessionId':'fixture','requestId':'prior-day','message':{'id':'prior-day','model':'claude-sonnet-4-6','usage':{'input_tokens':500,'output_tokens':100}}})+'\n')
expected_tokens=1000 if a.token_window=='today' else 1600
hook('claude','UserPromptSubmit')
log=(r/'runtime.log').open('w');proc=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(profile),str(app/'Contents/MacOS/AgentSignalLight'),'-settingsPreferenceDefaultsVersion','1','-codexOpenAICookieMode','off','-claude.credentialConsent','NO','-isDebugFileLoggingEnabled','NO','-isFloatingSignalSoundEnabled','NO','-isFloatingSignalEnabled','YES','-isFloatingSignalQuotaBadgeEnabled','YES','-isFloatingSignalTokenBadgeEnabled','YES','-floatingSignalTokenBadgeWindow',a.token_window,'-appLanguage','en'],env=env,stdout=log,stderr=log)
def wait_for(name,predicate,timeout=25):
 end=time.monotonic()+timeout;d={}
 while time.monotonic()<end and proc.poll() is None:
  try:
   d=json.loads(health.read_text())
   if predicate(d):record(name,True,health=d);return
  except (OSError,ValueError):pass
  time.sleep(.2)
 record(name,False,health=d,exit=proc.poll())
try:
 wait_for('Claude '+a.token_window+' history refreshes with menus closed',lambda d:d.get('floating_usage_provider')=='Claude' and d.get('floating_usage_tokens')==expected_tokens)
 wait_for('No login never fabricates quota',lambda d:d.get('claude_quota_available') is False and 'No verified quota' in d.get('claude_quota_message',''))
 hook('claude','Stop');hook('codex','UserPromptSubmit')
 wait_for('Switch to Codex never reuses Claude tokens',lambda d:d.get('floating_usage_provider')=='Codex' and d.get('floating_usage_tokens')!=expected_tokens)
 hook('codex','Stop');hook('claude','UserPromptSubmit')
 wait_for('Return to Claude restores device token summary',lambda d:d.get('floating_usage_provider')=='Claude' and d.get('floating_usage_tokens')==expected_tokens)
 hook('claude','PermissionRequest');wait_for('Claude permission lamp remains functional',lambda d:d.get('aggregate')=='permission')
 hook('claude','Stop');wait_for('Claude completion lamp remains functional',lambda d:d.get('aggregate')=='done')
finally:
 if proc.poll() is None:
  proc.terminate()
  try:proc.wait(timeout=5)
  except subprocess.TimeoutExpired:proc.kill();proc.wait()
 log.close()
