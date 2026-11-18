#!/usr/bin/env python3
import contextlib
import datetime
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import threading


ROOT = Path(__file__).resolve().parent.parent
OUT = Path(os.environ.get('HEYDAN_RUN_DIR', ROOT / 'build/e2e')).resolve()
BUILD = (ROOT / os.environ.get('HEYDAN_DERIVED_DATA', 'build/sim-e2e')).resolve()
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
APP_CHECKS = {
    'app-pair': None,
    'app-pair-used': None,
    'app-pair-screen': 'testPastePair',
    'app-signature-refusal': None,
    'app-send-reply': 'testSendReply',
    'app-history': 'testHistory',
    'app-resume-app': 'testResumeAfterRelaunch',
    'app-resume-server': None,
    'app-offline-send': 'testOfflineSend',
    'app-question': 'testQuestion',
    'app-working-status': 'testWorkingStatus',
    'app-download-files': 'testDownloadFiles',
    'app-upload-photo': None,
    'app-upload-document': None,
    'app-unread-relaunch': 'testUnreadRelaunch',
    'app-push-banner': 'testPushBanner',
    'app-push-suppressed': 'testPushSuppressed',
    'app-push-tap': 'testPushTap',
    'app-push-read-clears': None,
    'app-push-communication': None,
    'app-push-extension': None,
    'app-push-edit': None,
    'app-paired-call': None,
    'app-paired-voice': None,
    'app-paired-intent': None,
    'app-unpair': None,
    'app-line-call': None,
}
RECORDS = {}


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
    RECORDS[name] = record
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
        # `sh -c <HEYDAN_PAIR_CMD>` names only `sh -c`: the command may carry a secret.
        command = ' '.join(map(str, args[:2] if args[0] == 'sh' else args[:3]))
        if proc.returncode in (124, 137, -signal.SIGKILL):
            raise RuntimeError(f'{command} timed out after {seconds}s')
        raise RuntimeError(f'{command} exited {proc.returncode}')
    return subprocess.CompletedProcess(args, proc.returncode, output)


def sim(*args, **kwargs):
    return run('xcrun', 'simctl', *args, **kwargs).stdout.strip()


def build(*args, seconds, env=None):
    proc = run('xcodebuild', *args, '-project', 'HeyDan.xcodeproj', '-scheme', 'HeyDanChecks',
               '-destination', f'id={UDID}', '-derivedDataPath', BUILD,
               seconds=seconds, check=False, merge=True, env=env)
    output = proc.stdout
    if 'test-without-building' in args:
        # XCTest activity trees can contain chat text or a pasted pairing link.
        output = '\n'.join(line for line in output.splitlines()
                           if re.match(r"^(Test (Case|Suite) .* (passed|failed)|\s*Executed \d+ test|\*\* TEST)", line))
    (OUT / 'logs' / f'{CHECK}.log').write_text(output)
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


@contextlib.contextmanager
def push_driver(directory, enabled):
    stopped = threading.Event()
    failures = []
    def drive():
        try:
            request = directory / 'push.json'
            while not stopped.wait(0.1):
                if request.exists():
                    conversation = json.loads(request.read_text())['conversation']
                    if not isinstance(conversation, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', conversation):
                        raise RuntimeError('Invalid conversation identifier from UI check')
                    fixtures = ROOT / 'HeyDanCore/Tests/HeyDanCoreTests/Resources/app-contract.fixtures.json'
                    payload = json.loads(fixtures.read_text())['pushPayload']['body']
                    payload['hd']['h'] = os.environ['HEYDAN_LOCAL_BASE'].rstrip('/')
                    payload['hd']['c'] = conversation
                    payload['aps']['thread-id'] = conversation
                    payload['aps']['alert']['body'] = 'New message'
                    payload_file = directory / 'push.apns'
                    payload_file.write_text(json.dumps(payload))
                    sim('push', UDID, BUNDLE, payload_file)
                    (directory / 'pushed').touch()
                    return
        except Exception:
            failures.append('simctl push driver failed')
    worker = threading.Thread(target=drive) if enabled else None
    if worker:
        worker.start()
    try:
        yield
    finally:
        stopped.set()
        if worker:
            worker.join(65)
            if worker.is_alive():
                raise RuntimeError('simctl push driver did not stop')
        if failures:
            raise RuntimeError(failures[0])


def ui_check(name, method, stack=False):
    global CHECK
    CHECK = name
    runner = ENV | ({'TEST_RUNNER_HEYDAN_CHAT_STACK': '1'} if stack else {})
    screenshots = []
    try:
        with tempfile.TemporaryDirectory(prefix='chat-checks-', dir=BUILD) as temporary, push_driver(
                Path(temporary), method.startswith('ChatChecks/testPush')):
            runner['TEST_RUNNER_HEYDAN_CHAT_CONTROL'] = temporary
            output = build('test-without-building', '-parallel-testing-enabled', 'NO',
                           '-resultBundlePath', Path(temporary) / 'checks.xcresult',
                           '-test-timeouts-enabled', 'YES',
                           '-default-test-execution-time-allowance', '120',
                           '-maximum-test-execution-time-allowance', '150',
                           '-only-testing:HeyDanChecks/' + method, seconds=240, env=runner)
            if name == 'app-push-communication':
                run('xcrun', 'xcresulttool', 'export', 'attachments',
                    '--path', Path(temporary) / 'checks.xcresult',
                    '--output-path', Path(temporary) / 'screenshots', '--filter', '*.png')
                destination = OUT / 'logs' / name
                destination.mkdir(exist_ok=True)
                for path in sorted((Path(temporary) / 'screenshots').glob('*.png')):
                    shutil.copyfile(path, destination / path.name)
                    screenshots.append(str((destination / path.name).relative_to(OUT)))
        if re.search(r'Executed 1 test, with 1 test skipped', output):
            reasons = ('No local stack is running: HEYDAN_LOCAL_BASE and HEYDAN_PAIR_CMD are required',
                       'Stack conversation needs more than one page of history',
                       'Stack must seed an unread conversation')
            reason = next((reason for reason in reasons if reason in output), 'UI prerequisite unavailable; see lane report')
            result(name, 'skip', reason, [f'logs/{name}.log'])
        elif 'Executed 1 test, with 0 failures' not in output:
            result(name, 'fail', 'Expected exactly one executed test with zero failures', [f'logs/{name}.log'])
        else:
            evidence = [f'logs/{name}.log']
            if name == 'app-push-communication':
                evidence.extend(screenshots)
            result(name, 'pass', 'One UI check executed with zero failures', evidence)
    except RuntimeError as error:
        result(name, 'fail', str(error), [f'logs/{name}.log'])


def pair_link():
    command = os.environ['HEYDAN_PAIR_CMD']
    # stdout is a secret and stderr is intentionally discarded by run().
    link = run('sh', '-c', command, env=os.environ.copy()).stdout.strip()
    if not link or '\n' in link:
        raise RuntimeError('HEYDAN_PAIR_CMD did not return exactly one link')
    return link


def chat_checks():
    ui_check('app-fixture-unread', 'ChatChecks/testFixtureUnreadRelaunch')
    if bundle_ready(BUNDLE):
        ui_check('app-push-communication', 'ChatPushChecks/testCommunicationBannerAndTap')
    else:
        result('app-push-communication', 'skip', PUSH_BUNDLE)
    if not os.environ.get('HEYDAN_LOCAL_BASE') or not os.environ.get('HEYDAN_PAIR_CMD'):
        return
    global CHECK
    CHECK = 'app-pair'
    container = Path(sim('get_app_container', UDID, BUNDLE, 'data'))
    logfile = container / 'Library/Caches/heydan.log'
    link = pair_link()
    for name, expected in (('app-pair', 'pair ok'), ('app-pair-used', 'pair failed http_403_invalid_code')):
        CHECK = name
        sim('terminate', UDID, BUNDLE, check=False)
        logfile.unlink(missing_ok=True)
        sim('launch', UDID, BUNDLE, env=ENV | {'SIMCTL_CHILD_HEYDAN_PAIR_LINK': link})
        deadline = time.monotonic() + 30
        observed = False
        while time.monotonic() < deadline:
            text = logfile.read_text() if logfile.exists() else ''
            if expected in text:
                observed = True
                break
            time.sleep(0.5)
        sim('terminate', UDID, BUNDLE, check=False)
        result(name, 'pass' if observed else 'fail',
               'Expected pairing outcome observed' if observed else 'Pairing outcome not observed within 30s')
        if not observed:
            return
    # The real pairing screen consumes a fresh code via pasteboard, never a runner variable.
    CHECK = 'app-pair-screen'
    fresh = pair_link()
    run('xcrun', 'simctl', 'pbcopy', UDID, stdin=fresh)
    try:
        ui_check('app-pair-screen', 'ChatChecks/testPastePair', stack=True)
    finally:
        run('xcrun', 'simctl', 'pbcopy', UDID, stdin='')
    for name, method in APP_CHECKS.items():
        if not method or name == 'app-pair-screen':
            continue
        if name.startswith('app-push-') and not bundle_ready(BUNDLE):
            result(name, 'skip', PUSH_BUNDLE)
        else:
            ui_check(name, 'ChatChecks/' + method, stack=True)


def report():
    order = ['sim-setup', 'sim-local-ca', 'sim-build', 'sim-permission', 'sim-call',
             'app-fixture-unread', *APP_CHECKS]
    (OUT / 'check-order.json').write_text(json.dumps(order) + '\n')
    lines = ['# Simulator run', '']
    for name in order:
        if name in RECORDS:
            row = RECORDS[name]
            lines.append(f"- {row['status'].upper()} {name}: {row['detail']}")
    (OUT / 'report.md').write_text('\n'.join(lines) + '\n')


PUSH_BUNDLE = 'Push checks need your own HEYDAN_BUNDLE_ID in gitignored Local.xcconfig, not the placeholder com.example.HeyDan'


def bundle_ready(bundle):
    return bool(bundle) and bundle != 'com.example.HeyDan'


def main():
    global UDID, CHECK
    for name in ('sim-setup', 'sim-local-ca', 'sim-build', 'sim-permission', 'sim-call'):
        result(name, 'skip', 'Not reached in this invocation')
    no_stack = not os.environ.get('HEYDAN_LOCAL_BASE') or not os.environ.get('HEYDAN_PAIR_CMD')
    for name in APP_CHECKS:
        result(name, 'skip', 'No local stack is running: HEYDAN_LOCAL_BASE and HEYDAN_PAIR_CMD required'
               if no_stack else 'Flow requires additional observable app hooks; see lane report')
    pending = {
        'app-signature-refusal': 'Signed malformed-request checks belong to the N9b scripted client',
        'app-upload-photo': 'HEYDAN_FIXTURE_ATTACHMENT is fixture-only; needs a stack-safe staging hook from H4b',
        'app-upload-document': 'HEYDAN_FIXTURE_ATTACHMENT is fixture-only; needs a stack-safe staging hook from H4b',
        'app-paired-call': 'Needs a paired call WAV and bounded hangup hook from H6; existing AUTOCALL selects a saved line',
        'app-paired-voice': 'Needs paired voice restore/readback evidence from H6 before mutating saved voice',
        'app-paired-intent': 'Needs paired entity selection in AppIntentsTesting from H6; never fall back to a saved line',
        'app-unpair': 'Needs signed post-unpair refusal evidence; the UI cannot issue a request with the revoked key',
        'app-push-read-clears': 'Needs delivered-notification and badge readback from the app',
        'app-resume-server': 'Missing HEYDAN_STACK_RESTART_CMD' if not os.environ.get('HEYDAN_STACK_RESTART_CMD') else 'Needs stream cursor readback across host restart',
    }
    if not no_stack:
        for name, reason in pending.items():
            result(name, 'skip', reason)
    result('app-push-extension', 'skip', 'simctl push does not execute the notification service extension; requires real APNs')
    result('app-push-edit', 'skip', 'Replacing a delivered banner requires a real APNs push')

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
    # Registered ports can still leave notificationSettings() waiting on dasd indefinitely.
    sim('spawn', UDID, 'launchctl', 'kickstart', '-k', f'{domain}/com.apple.dasd')
    deadline = time.monotonic() + 30
    while not notifications_ready(state) and time.monotonic() < deadline:
        time.sleep(1)
        state = sim('spawn', UDID, 'launchctl', 'print', domain)
    (OUT / 'logs/sim-launchctl-after.log').write_text(state)
    if not notifications_ready(state):
        raise RuntimeError('Notification services not checked in after dasd recovery')
    result(CHECK, 'pass', 'Device booted; dasd kickstarted', ['logs/sim-launchctl-after.log'])
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
    try:
        chat_checks()
    except RuntimeError as error:
        # A broken stack fails its own check; the saved-line call below still runs.
        result(CHECK, 'fail', str(error))
    CHECK = 'sim-call'
    if not LINK:
        result(CHECK, 'skip', 'Missing HEYDAN_E2E_CALL_LINK or TEST_CALL_LINK')
        result('app-line-call', 'skip', 'Missing HEYDAN_E2E_CALL_LINK or TEST_CALL_LINK')
        return
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
            result('app-line-call', 'pass', 'Saved line call passed the audio and clean-end grader', [evidence])
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
        if any(row['status'] == 'fail' for row in RECORDS.values()):
            sys.exit(1)
    except Stopped as stopped:
        result(CHECK, 'fail', f'Stopped by {stopped}')
        sys.exit(128 + STOPPED_BY)
    except (RuntimeError, OSError, ValueError) as error:
        result(CHECK, 'fail', str(error))
        sys.exit(1)
    except Exception as error:
        result(CHECK, 'fail', f'Unexpected {type(error).__name__}: {error}')
        raise
    finally:
        if CHECK == 'sim-call' and RECORDS.get(CHECK, {}).get('status') == 'fail':
            result('app-line-call', 'fail', RECORDS[CHECK]['detail'], RECORDS[CHECK]['evidence'])
        report()
        if UDID:
            sim('terminate', UDID, BUNDLE, check=False)
