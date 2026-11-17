#!/usr/bin/env python3
import contextlib
import datetime
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
OUT = Path(os.environ.get('HEYDAN_RUN_DIR', ROOT / 'build/e2e')).resolve()
BUILD = ROOT / 'build/sim-e2e'
LINK = os.environ.get('HEYDAN_E2E_CALL_LINK') or os.environ.get('TEST_CALL_LINK', '')
# Xcode archives its environment. Only simctl's seeding launch receives the link.
ENV = {k: v for k, v in os.environ.items() if k in (
    'PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL', 'USER', 'LOGNAME')}
HANGUP_AFTER = 65
LAUNCH_BOUND = 60
REFUSED = 'debug autocall refused'
UDID = None
CHECK = 'sim-setup'
STOPPED_BY = None


class Stopped(Exception):
    pass


def stop(signum, _frame):
    global STOPPED_BY
    # Only the first signal unwinds: a second one must not cut the cleanup short.
    if STOPPED_BY is None:
        STOPPED_BY = signum
        raise Stopped(signal.Signals(signum).name)


def result(name, status, detail, evidence=()):
    record = dict(id=name, title=name.replace('-', ' ').capitalize(), status=status,
                  detail=detail, evidence=list(evidence),
                  at=datetime.datetime.now(datetime.timezone.utc).isoformat())
    (OUT / 'results' / f'{name}.json').write_text(json.dumps(record) + '\n')
    print(f'{name}: {status}: {detail}', flush=True)


def run(*args, seconds=60, env=None, check=True, stdin=None, merge=False):
    # A session of its own: one signal to its group reaches timeout and everything the command started.
    with subprocess.Popen(['timeout', '--kill-after=5', str(seconds), *map(str, args)],
                          cwd=ROOT, env=env or ENV, start_new_session=True, text=True, errors='replace',
                          stdin=subprocess.DEVNULL if stdin is None else subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge else subprocess.PIPE) as proc:
        try:
            output = proc.communicate(stdin)[0]
        except BaseException:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
            raise
    if check and proc.returncode:
        # Commands never include links or message text; raw SDK diagnostics are not retained.
        command = ' '.join(map(str, args[:3]))
        if proc.returncode in (124, 137, -signal.SIGKILL):
            raise RuntimeError(f'{command} timed out after {seconds}s')
        raise RuntimeError(f'{command} exited {proc.returncode}')
    return subprocess.CompletedProcess(args, proc.returncode, output)


def sim(*args, **kwargs):
    return run('xcrun', 'simctl', *args, **kwargs).stdout.strip()


def build(*args, seconds):
    proc = run('xcodebuild', *args, '-project', 'HeyDan.xcodeproj', '-scheme', 'HeyDanChecks',
               '-destination', f'id={UDID}', '-derivedDataPath', BUILD,
               seconds=seconds, check=False, merge=True)
    (OUT / 'logs' / f'{CHECK}.log').write_text(proc.stdout)
    if proc.returncode:
        raise RuntimeError(f'xcodebuild exited {proc.returncode}; see logs/{CHECK}.log')
    return proc.stdout


def notifications_ready(state):
    rows = [line.split() for line in state.splitlines()]
    for service in ('com.apple.usernotifications.listener', 'com.apple.usernotifications.coreservice',
                    'com.apple.usernotifications.systemservice'):
        matches = [row for row in rows if row and row[-1] == service]
        if not matches or any(row[0] == '0' or 'not checked in' in ' '.join(row).lower() for row in matches):
            return False
    return True


# A plain line offers review and answers with a reply event; a jev line offers neither, so its proof is the agent
# thinking after the caller's caption, then its own caption.
def grade(text):
    caller = text.find('e2e caption final caller=true')
    jev = 'review grace ran out: not offered' in text and 'e2e reply ' not in text
    if caller < 0:
        reply = False
    elif jev:
        thinking = text.find(' thinking=1 ', caller)
        reply = thinking > caller and text.find('e2e caption final caller=false', thinking) > thinking
    else:
        answer = text.find('e2e reply turn=true notice=false unspoken=false', caller)
        reply = (answer > caller and text.find('e2e caption final caller=false', answer) > answer
                 and 'unspoken=true' not in text[answer:])
    connected = bool(' connected ms=' in text and re.search(r' live\n', text))
    return dict(
        mode='jev' if jev else 'plain', connected=connected, reply=reply,
        audio='agent audio subscribed sid=' in text,
        clean=bool(re.search(r'finish site=.* cause=caller .*connected=true mic=true live=true', text)),
        ended=bool(re.search(r'end reason=hangup status=2\d\d', text)),
        fed=bool(re.search(r'debug feed: wav frames=[1-9]\d*', text)),
        refused=REFUSED in text,
        # CallLog.describe prints LiveKit's timedOut by its description; -1001 is URLError.timedOut.
        connect_timeout=not connected and bool(re.search(r'connect failed (LiveKitError\(Timed out\)|URLError\(-1001\))', text)),
    )


def main():
    global UDID, CHECK
    for name in ('sim-setup', 'sim-local-ca', 'sim-build', 'sim-permission', 'sim-call'):
        result(name, 'skip', 'Not reached in this invocation')
    if not LINK:
        raise RuntimeError('Missing HEYDAN_E2E_CALL_LINK or TEST_CALL_LINK')
    attempts = os.environ.get('HEYDAN_E2E_ATTEMPTS', '2')
    if attempts not in ('1', '2'):
        raise RuntimeError('HEYDAN_E2E_ATTEMPTS must be 1 or 2')
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
        if not runtimes:
            raise RuntimeError('No iOS Simulator runtime: run xcodebuild -downloadPlatform iOS')
        runtime = max(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))
        UDID = sim('create', name, 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max', runtime['identifier'])
    sim('bootstatus', UDID, '-b', seconds=180)
    domain = f'user/{os.getuid()}'
    state = sim('spawn', UDID, 'launchctl', 'print', domain)
    (OUT / 'logs/sim-launchctl-before.log').write_text(state)
    kicked = not notifications_ready(state)
    if kicked:
        sim('spawn', UDID, 'launchctl', 'kickstart', '-k', f'{domain}/com.apple.dasd')
    deadline = time.monotonic() + 30
    while not notifications_ready(state) and time.monotonic() < deadline:
        time.sleep(1)
        state = sim('spawn', UDID, 'launchctl', 'print', domain)
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
    build('build-for-testing', '-quiet', seconds=900)
    sim('install', UDID, BUILD / 'Build/Products/Debug-iphonesimulator/HeyDan.app')
    result(CHECK, 'pass', 'Built and installed app and UI checks', ['logs/sim-build.log'])
    CHECK = 'sim-permission'
    sim('privacy', UDID, 'reset', 'microphone', BUNDLE)
    with tempfile.TemporaryDirectory(prefix='checks-', dir=BUILD) as temporary:
        output = build('test-without-building', '-parallel-testing-enabled', 'NO',
                       '-resultBundlePath', Path(temporary) / 'checks.xcresult',
                       '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '60',
                       '-maximum-test-execution-time-allowance', '90',
                       '-only-testing:HeyDanChecks/HeyDanChecks/testE2EMicrophonePermission', seconds=300)
    # A renamed test id runs nothing and still exits 0.
    if 'Executed 1 test, with 0 failures' not in output:
        raise RuntimeError('The microphone permission check did not run; see logs/sim-permission.log')
    sim('privacy', UDID, 'grant', 'microphone', BUNDLE)
    result(CHECK, 'pass', 'SpringBoard Allow tapped on microphone permission alert', ['logs/sim-permission.log'])
    CHECK = 'sim-call'
    run('say', '-o', BUILD / 'feed.aiff', '-f', '-',
        stdin=os.environ.get('HEYDAN_E2E_SAY', 'What is two plus two? Please answer briefly.'))
    run('afconvert', '-f', 'WAVE', '-d', 'LEF32@48000', '-c', '1', BUILD / 'feed.aiff', BUILD / 'feed.wav')
    container = Path(sim('get_app_container', UDID, BUNDLE, 'data'))
    logfile = container / 'Library/Caches/heydan.log'
    call_env = ENV | {f'SIMCTL_CHILD_{k}': v for k, v in {
        'HEYDAN_CALL_LINK': LINK, 'HEYDAN_AUTOCALL': '1', 'HEYDAN_HANGUP_AFTER': str(HANGUP_AFTER),
        'HEYDAN_FEED_WAV': str(BUILD / 'feed.wav'), 'HEYDAN_FEED_AFTER': '12',
        'HEYDAN_TURN_MODE': 'auto',
    }.items()}
    for attempt in range(1, int(attempts) + 1):
        sim('terminate', UDID, BUNDLE, check=False)
        logfile.unlink(missing_ok=True)
        sim('launch', '--terminate-running-process', UDID, BUNDLE, env=call_env)
        deadline = time.monotonic() + LAUNCH_BOUND
        claimed = False
        text = ''
        while time.monotonic() < deadline:
            time.sleep(1)
            text = logfile.read_text() if logfile.exists() else ''
            if REFUSED in text or ('finish site=' in text and re.search(r'end reason=.* status=\d+', text)):
                break
            if not claimed and 'claim line=' in text:
                claimed = True
                # The app hangs up HANGUP_AFTER after the claim, then the host has up to 10 s to acknowledge it.
                deadline = time.monotonic() + HANGUP_AFTER + 20
        sim('terminate', UDID, BUNDLE, check=False)
        evidence = f'logs/sim-call-{attempt}.log'
        # The app mirror has states/codes only; never collect LiveKit's SDK log.
        (OUT / evidence).write_text(text)
        g = grade(text)
        if g['refused']:
            raise RuntimeError(f'Attempt {attempt}: the app refused the autocall: the supplied link is not a call link or was not selected; see {evidence}')
        if g['connected'] and g['reply'] and g['audio'] and g['clean'] and g['ended'] and g['fed']:
            result(CHECK, 'pass', f'Attempt {attempt}: mode={g["mode"]}, connected, agent audio subscribed, caller and reply in transcript, clean hangup acknowledged', [evidence])
            return
        # The host admitted the first call before connect failed: retry only once it acknowledged that call's end.
        if attempt < int(attempts) and g['connect_timeout'] and g['ended']:
            result(CHECK, 'skip', 'Connect timeout; retrying once', [evidence])
            continue
        raise RuntimeError(f'Attempt {attempt}: mode={g["mode"]}, claimed={claimed}, connected={g["connected"]}, reply={g["reply"]}, audio={g["audio"]}, clean={g["clean"]}, endAcknowledged={g["ended"]}, WAV={g["fed"]}; see {evidence}')


if __name__ == '__main__':
    BUNDLE = sys.argv[1]
    for directory in (OUT / 'results', OUT / 'logs', BUILD):
        directory.mkdir(parents=True, exist_ok=True)
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, stop)
    try:
        main()
    except Stopped as stopped:
        result(CHECK, 'fail', f'Stopped by {stopped}')
        sys.exit(128 + STOPPED_BY)
    except (RuntimeError, OSError, ValueError) as error:
        result(CHECK, 'fail', str(error))
        sys.exit(1)
    except BaseException as error:
        result(CHECK, 'fail', f'Unexpected {type(error).__name__}: {error}')
        raise
    finally:
        if UDID:
            sim('terminate', UDID, BUNDLE, check=False)
