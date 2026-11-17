#!/usr/bin/env python3
"""Verify packaged credit presentation with synthetic snapshots and a loopback API; real data and external network access are denied."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
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
app = root / 'Credits Test.app'
subprocess.run(['/usr/bin/ditto', str(args.app), str(app)], check=True)
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['CFBundleIdentifier'] = 'com.agentsignallight.credit-test.' + uuid.uuid4().hex
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
isolation = root / 'isolation.sb'
isolation.write_text('(version 1)\n(allow default)\n(deny network*)\n'
    '(deny file-read* file-write* (subpath ' + json.dumps(str(Path.home())) + '))\n'
    '(deny mach-lookup (global-name "com.apple.securityd") '
    '(global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))\n')
results = []
cases = [
    ('quota-available', 60, 70, 125.5, False),
    ('five-hour-exhausted', 0, 70, 125.5, True),
    ('weekly-exhausted', 70, 0, 125.5, True),
    ('zero-balance', 0, 0, 0, False),
    ('credits-only', None, None, 125.5, True),
    ('stale-balance', 0, 0, 125.5, False),
    ('failed-refresh', 0, 0, 125.5, False),
    ('reset-passed', 0, 0, 125.5, False),
    ('quota-recovered', 40, 70, 125.5, False),
    ('other-account', 0, 0, 125.5, False),
]
for name, primary, weekly, balance, expected in cases:
    profile = root / name
    codex = profile / '.codex'
    codex.mkdir(parents=True)
    auth = json.dumps({'tokens': {'account_id': 'fixture-credits', 'access_token': 'synthetic-not-a-real-token'}}).encode()
    (codex / 'auth.json').write_bytes(auth)
    reference_now = time.time() - 978307200
    updated = reference_now - (600 if name == 'stale-balance' else 0)
    reset = reference_now + (-10 if name == 'reset-passed' else 3600)
    def window(value, minutes):
        return {'remaining_percent': value, 'used_percent': 100-value, 'window_minutes': minutes, 'resets_at': reset}
    cached_primary = 60 if name in ['five-hour-exhausted', 'weekly-exhausted'] else (0 if name == 'quota-recovered' else primary)
    cached_weekly = 70 if name == 'weekly-exhausted' else weekly
    quota = None if primary is None else dict(window(cached_primary, 300), updated_at=reference_now, source='oauth',
        primary=window(cached_primary, 300), secondary=window(cached_weekly, 10080))
    # Successful responses must change the cached balance, proving publication after an actual refresh.
    cached_balance = balance if name in ['stale-balance', 'failed-refresh', 'other-account'] else balance + 17
    snapshot = {'accountKey': 'account:' + ('other-fixture' if name == 'other-account' else 'fixture-credits'),
        'accountID': 'other-fixture' if name == 'other-account' else 'fixture-credits',
        'authFingerprint': hashlib.sha256(auth).hexdigest(), 'quota': quota,
        'credits': {'title': 'Credits', 'remaining': cached_balance, 'balance': cached_balance, 'updatedAt': updated},
        'usageFetchState': {'source': 'oauth', 'lastSuccessfulAt': updated, 'lastAttemptedAt': reference_now,
            'isStale': False, 'errorMessage': None},
        'tokenActivityDays': [], 'updatedAt': reference_now}
    cache = profile / 'Library/Application Support/AgentSignalLight/codex-account-usage-snapshots.json'
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({'version': 2, 'snapshots': [snapshot]}))
    requests = {'usage': 0}
    class FixtureAPI(BaseHTTPRequestHandler):
        def do_GET(self):
            status = 200
            if self.path.endswith('/usage'):
                requests['usage'] += 1
                if name in ['failed-refresh', 'stale-balance']:
                    status = 503
                    body = {'error': 'fixture unavailable'}
                elif name == 'other-account':
                    status = 401
                    body = {'error': 'fixture unauthorized'}
                else:
                    body = {'credits': {'balance': balance}}
                    if primary is not None:
                        unix_reset = int(time.time()) + (-10 if name == 'reset-passed' else 3600)
                        body['rate_limit'] = {
                            'primary_window': {'used_percent': 100-primary, 'limit_window_seconds': 18000, 'reset_at': unix_reset},
                            'secondary_window': {'used_percent': 100-weekly, 'limit_window_seconds': 604800, 'reset_at': unix_reset}}
            else:
                body = {'credits': [], 'available_count': 0}
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def log_message(self, *args):
            pass
    server = HTTPServer(('127.0.0.1', 0), FixtureAPI)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (codex / 'config.toml').write_text('chatgpt_base_url = "http://127.0.0.1:' + str(port) + '"\n')
    local_isolation = profile / 'isolation.sb'
    local_isolation.write_text(isolation.read_text() + '(allow network-outbound (remote ip "localhost:' + str(port) + '"))\n')
    health = profile / 'health.json'
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'CFFIXED_USER_HOME': str(profile),
        'CODEX_HOME': str(codex), 'CLAUDE_CONFIG_DIR': str(profile / '.claude'), 'TMPDIR': str(profile),
        'AGENT_SIGNAL_LIGHT_STATE_FILE': str(profile / 'status.json'),
        'AGENT_SIGNAL_LIGHT_STATUS_ITEM_HEALTH_FILE': str(health)}
    with (profile / 'runtime.log').open('w') as log:
        process = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(local_isolation),
            str(app / 'Contents/MacOS/AgentSignalLight'), '-settingsPreferenceDefaultsVersion', '1',
            '-codexOpenAICookieMode', 'off', '-codexUsageDataSource', 'oauth-api',
            '-claude.credentialConsent', 'NO', '-appLanguage', 'en'], env=env, stdout=log, stderr=log)
        observed = {}; passed = False
        stable_since = None
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    observed = json.loads(health.read_text())
                    expected_balance = None if name == 'other-account' else balance
                    matches = (requests['usage'] > 0
                        and observed.get('codex_credits_remaining') == expected_balance
                        and observed.get('codex_credit_badge') is expected)
                    if matches:
                        if stable_since is None:
                            stable_since = time.monotonic()
                        elif time.monotonic() - stable_since >= 1.5:
                            passed = True
                            break
                    else:
                        stable_since = None
                except (OSError, ValueError):
                    pass
                time.sleep(.15)
            results.append({'case': name, 'passed': passed, 'mock_usage_requests': requests['usage'], 'health': observed})
            (root / 'results.json').write_text(json.dumps(results, indent=2))
            print(name, passed, flush=True)
            if not passed:
                raise AssertionError(name)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()

            server.shutdown(); server.server_close(); thread.join(timeout=2)
