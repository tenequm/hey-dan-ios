#!/usr/bin/env python3
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
OUT = Path(os.environ.get('HEYDAN_RUN_DIR', ROOT / 'build/e2e')).resolve()
BUILD = ROOT / 'build/sim-e2e'
BUNDLE = sys.argv[1]
LINK = os.environ.get('HEYDAN_E2E_CALL_LINK') or os.environ.get('TEST_CALL_LINK', '')
# Xcode archives its environment. Only simctl's seeding launch receives the link.
ENV = {k: v for k, v in os.environ.items() if k in (
    'PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL', 'USER', 'LOGNAME')}
UDID = None
CHECK = 'sim-setup'
for directory in (OUT / 'results', OUT / 'logs', BUILD):
    directory.mkdir(parents=True, exist_ok=True)


def result(name, status, detail, evidence=()):
    record = dict(id=name, title=name.replace('-', ' ').capitalize(), status=status,
                  detail=detail, evidence=list(evidence),
                  at=datetime.datetime.now(datetime.timezone.utc).isoformat())
    (OUT / 'results' / f'{name}.json').write_text(json.dumps(record) + '\n')
    print(f'{name}: {status}: {detail}', flush=True)


def run(*args, seconds=60, env=None, check=True):
    proc = subprocess.run(['timeout', '--kill-after=5', str(seconds), *map(str, args)],
                          cwd=ROOT, env=env or ENV, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)
    if check and proc.returncode:
        # Commands never include links; raw SDK diagnostics are not retained.
        raise RuntimeError(f'{args[0]} {args[1] if len(args) > 1 else ""} exited {proc.returncode}')
    return proc


def sim(*args, **kwargs):
    return run('xcrun', 'simctl', *args, **kwargs).stdout.strip()


def build(*args):
    proc = run('xcodebuild', *args, '-project', 'HeyDan.xcodeproj', '-scheme', 'HeyDanChecks',
               '-destination', f'id={UDID}', '-derivedDataPath', BUILD,
               seconds=300 if 'test-without-building' in args else 900, check=False)
    (OUT / 'logs' / f'{CHECK}.log').write_text(proc.stdout)
    if proc.returncode:
        raise RuntimeError(f'xcodebuild exited {proc.returncode}; see logs/{CHECK}.log')


def notifications_ready(state):
    required = ('com.apple.usernotifications.listener', 'com.apple.usernotifications.coreservice',
                'com.apple.usernotifications.systemservice')
    for service in required:
        rows = [line.split() for line in state.splitlines() if line.split() and line.split()[-1] == service]
        if not rows or any(row[0] == '0' or 'not checked in' in ' '.join(row).lower() for row in rows):
            return False
    return True


def main():
    global UDID, CHECK
    for name in ('sim-setup', 'sim-local-ca', 'sim-build', 'sim-permission', 'sim-call'):
        result(name, 'skip', 'Not reached in this invocation')
    if not LINK:
        raise RuntimeError('Missing HEYDAN_E2E_CALL_LINK or TEST_CALL_LINK')
    devices = json.loads(sim('list', 'devices', 'available', '-j'))['devices']
    name = os.environ.get('HEYDAN_SIM', 'Hey Dan e2e')
    matches = [d for group in devices.values() for d in group if d['name'] == name]
    if len(matches) > 1:
        raise RuntimeError('Simulator name is ambiguous; use a unique HEYDAN_SIM')
    if matches:
        UDID = matches[0]['udid']
    else:
        runtimes = json.loads(sim('list', 'runtimes', 'available', '-j'))['runtimes']
        runtimes = [r for r in runtimes if r.get('platform') == 'iOS' and '-iPhone' not in r['identifier']]
        runtime = max(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))
        UDID = sim('create', name, 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max', runtime['identifier'])
    sim('bootstatus', UDID, '-b', seconds=180)
    state = sim('spawn', UDID, 'launchctl', 'print', 'user/501')
    (OUT / 'logs/sim-launchctl-before.log').write_text(state)
    kicked = not notifications_ready(state)
    if kicked:
        sim('spawn', UDID, 'launchctl', 'kickstart', '-k', 'user/501/com.apple.dasd')
    deadline = time.monotonic() + 30
    while not notifications_ready(state) and time.monotonic() < deadline:
        time.sleep(1)
        state = sim('spawn', UDID, 'launchctl', 'print', 'user/501')
    (OUT / 'logs/sim-launchctl-after.log').write_text(state)
    if not notifications_ready(state):
        raise RuntimeError('Notification services not checked in after dasd recovery')
    result(CHECK, 'pass', f'Device booted; dasd kickstart={kicked}', ['logs/sim-launchctl-after.log'])
    CHECK = 'sim-local-ca'
    ca = os.environ.get('HEYDAN_LOCAL_CA')
    if ca:
        sim('keychain', UDID, 'add-root-cert', str(Path(ca).resolve()))
        result(CHECK, 'pass', 'Installed supplied root certificate')
    else:
        result(CHECK, 'skip', 'HEYDAN_LOCAL_CA not supplied')
    CHECK = 'sim-build'
    run('xcodegen', 'generate')
    build('build-for-testing', '-quiet')
    sim('install', UDID, BUILD / 'Build/Products/Debug-iphonesimulator/HeyDan.app')
    result(CHECK, 'pass', 'Built and installed app and UI checks', ['logs/sim-build.log'])
    CHECK = 'sim-permission'
    sim('privacy', UDID, 'reset', 'microphone', BUNDLE)
    with tempfile.TemporaryDirectory(prefix='checks-', dir=BUILD) as temporary:
        build('test-without-building', '-parallel-testing-enabled', 'NO',
              '-resultBundlePath', Path(temporary) / 'checks.xcresult',
              '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '60',
              '-maximum-test-execution-time-allowance', '90',
              '-only-testing:HeyDanChecks/HeyDanChecks/testE2EMicrophonePermission')
    sim('privacy', UDID, 'grant', 'microphone', BUNDLE)
    result(CHECK, 'pass', 'SpringBoard Allow tapped on microphone permission alert', ['logs/sim-permission.log'])
    CHECK = 'sim-call'
    run('say', '-o', BUILD / 'feed.aiff', os.environ.get('HEYDAN_E2E_SAY', 'What is two plus two? Please answer briefly.'))
    run('afconvert', '-f', 'WAVE', '-d', 'LEF32@48000', '-c', '1', BUILD / 'feed.aiff', BUILD / 'feed.wav')
    container = Path(sim('get_app_container', UDID, BUNDLE, 'data'))
    logfile = container / 'Library/Caches/heydan.log'
    call_env = ENV | {f'SIMCTL_CHILD_{k}': v for k, v in {
        'HEYDAN_CALL_LINK': LINK, 'HEYDAN_AUTOCALL': '1', 'HEYDAN_HANGUP_AFTER': '65',
        'HEYDAN_FEED_WAV': str(BUILD / 'feed.wav'), 'HEYDAN_FEED_AFTER': '12',
        'HEYDAN_TURN_MODE': 'auto',
    }.items()}
    attempts = int(os.environ.get('HEYDAN_E2E_ATTEMPTS', '2'))
    if attempts not in (1, 2):
        raise RuntimeError('HEYDAN_E2E_ATTEMPTS must be 1 or 2')
    for attempt in range(1, attempts + 1):
        sim('terminate', UDID, BUNDLE, check=False)
        logfile.unlink(missing_ok=True)
        sim('launch', '--terminate-running-process', UDID, BUNDLE, env=call_env)
        deadline = time.monotonic() + 80
        text = ''
        while time.monotonic() < deadline:
            time.sleep(1)
            text = logfile.read_text() if logfile.exists() else ''
            if 'finish site=' in text and re.search(r'end reason=.* status=\d+', text):
                break
        sim('terminate', UDID, BUNDLE, check=False)
        evidence = f'logs/sim-call-{attempt}.log'
        # The app mirror has states/codes only; never collect LiveKit's SDK log.
        (OUT / evidence).write_text(text)
        connected = ' connected ms=' in text and re.search(r' live\n', text)
        caller = text.find('e2e caption final caller=true')
        answer = text.find('e2e reply turn=true notice=false unspoken=false', caller)
        reply = caller >= 0 and answer > caller and text.find('e2e caption final caller=false', answer) > answer and 'unspoken=true' not in text[answer:]
        clean = re.search(r'finish site=.* cause=caller .*connected=true mic=true live=true', text)
        ended = re.search(r'end reason=hangup status=2\d\d', text)
        fed = re.search(r'debug feed: wav frames=[1-9]\d*', text)
        audio = 'agent audio subscribed sid=' in text
        if connected and reply and audio and clean and ended and fed:
            result(CHECK, 'pass', f'Attempt {attempt}: connected, agent audio subscribed, caller and reply in transcript, clean hangup acknowledged', [evidence])
            return
        connect_timeout = not connected and re.search(r'connect failed .*([Tt]imed?[Oo]ut|[Tt]imeout)', text)
        if attempt < attempts and connect_timeout:
            result(CHECK, 'skip', 'Connect timeout; retrying once', [evidence])
            continue
        raise RuntimeError(f'Attempt {attempt}: connected={bool(connected)}, reply={reply}, audio={audio}, clean={bool(clean)}, endAcknowledged={bool(ended)}, WAV={bool(fed)}; see {evidence}')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        result(CHECK, 'fail', str(error))
        sys.exit(1)
    finally:
        if UDID:
            sim('terminate', UDID, BUNDLE, check=False)
