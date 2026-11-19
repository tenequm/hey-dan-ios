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
import uuid


ROOT = Path(__file__).resolve().parent.parent
OUT = Path(os.environ.get('HEYDAN_RUN_DIR', ROOT / 'build/e2e')).resolve()
BUILD = (ROOT / os.environ.get('HEYDAN_DERIVED_DATA', 'build/sim-e2e')).resolve()
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
    'app-history': None,
    'app-resume-app': 'testResumeAfterRelaunch',
    'app-resume-server': None,
    'app-offline-send': 'testOfflineSend',
    'app-question': 'testQuestion',
    'app-working-status': 'testWorkingStatus',
    'app-download-files': 'testDownloadFiles',
    'app-upload-photo': 'testUploadPhoto',
    'app-upload-document': 'testUploadDocument',
    'app-unread-relaunch': 'testUnreadRelaunch',
    'app-push-banner': 'testPushBanner',
    'app-push-suppressed': 'testPushSuppressed',
    'app-push-tap': 'testPushTap',
    'app-push-read-clears': 'testPushReadClears',
    'app-push-communication': None,
    'app-push-extension': None,
    'app-push-edit': None,
    'app-paired-call': None,
    'app-paired-voice': None,
    'app-voice-picker-screen': 'testPairedVoicePicker',
    'app-paired-intent': None,
    'app-unpair': 'testUnpair',
    'app-call-pair': None,
    'app-call-unpair': None,
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
        sites = re.findall(r'([^ /]+\.swift:\d+): error:', output)
        # XCTest activity trees can contain chat text or a pasted pairing link.
        output = '\n'.join(line for line in output.splitlines()
                           if re.match(r"^(Test (Case|Suite) .* (passed|failed)|\s*Executed \d+ test|\*\* TEST)", line))
    if 'test-without-building' in args and sites:
        output += '\nFailure sites: ' + ', '.join(sites)
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


# A Jev worker has no command vocabulary or reply events. Its thinking transition and final caption prove the reply.
def grade(text):
    caller = text.find('e2e caption final caller=true')
    jev = (' commands=- ' in text and not re.search(r' commands=[23] ', text) and 'e2e reply ' not in text)
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
        ended=bool(re.search(r'end reason=hangup acknowledged', text)),
        fed=bool(re.search(r'debug feed: wav frames=[1-9]\d*', text)),
        refused=REFUSED in text,
        # CallLog.describe prints LiveKit's timedOut by its description; -1001 is URLError.timedOut.
        connect_timeout=not connected and bool(re.search(r'connect failed (LiveKitError\(Timed out\)|URLError\(-1001\))', text)),
    )


def grade_paired(text):
    evidence = grade(text)
    # A jev call speaks its reply without marking the thread's copy spoken.
    marks = ('caller', 'spoken') if evidence['mode'] == 'plain' else ('caller',)
    return (all(evidence[key] for key in ('connected', 'reply', 'audio', 'clean', 'ended', 'fed'))
            and bool(re.search(r'end reason=hangup acknowledged[^\n]*paired=true', text))
            and all('check thread voice=' + voice in text for voice in marks))


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
                    container = Path(sim('get_app_container', UDID, BUNDLE, 'data'))
                    metadata = json.loads((container / 'Library/Caches/chat-check-context.json').read_text())
                    agent = next(row['agent'] for row in metadata if row['id'] == conversation)
                    payload['hd']['a'] = agent
                    payload['aps']['alert']['title'] = agent['name']
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


def ui_check(name, method, stack=False, call_run=None):
    global CHECK
    selected = set(filter(None, os.environ.get('HEYDAN_CHAT_ONLY', '').split(',')))
    if selected and name not in selected:
        result(name, 'skip', 'Not selected by HEYDAN_CHAT_ONLY')
        return
    CHECK = name
    runner = ENV | ({'TEST_RUNNER_HEYDAN_CHAT_STACK': '1',
                     'TEST_RUNNER_HEYDAN_STACK_PROFILE': os.environ.get('HEYDAN_STACK_PROFILE', 'fast')} if stack else {})
    if name in ('app-upload-photo', 'app-upload-document'):
        import base64
        attachment = BUILD / ('upload.png' if name.endswith('photo') else 'upload.pdf')
        if name.endswith('photo'):
            attachment.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aEn8AAAAASUVORK5CYII='))
        else:
            objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>', b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>']
            data = b'%PDF-1.4\n'
            offsets = [0]
            for index, obj in enumerate(objects, 1):
                offsets.append(len(data))
                data += str(index).encode() + b' 0 obj\n' + obj + b'\nendobj\n'
            xref = len(data)
            data += b'xref\n0 4\n0000000000 65535 f \n'
            data += b''.join(f'{offset:010} 00000 n \n'.encode() for offset in offsets[1:])
            data += f'trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
            attachment.write_bytes(data)
        runner['TEST_RUNNER_HEYDAN_CHAT_ATTACHMENT'] = str(attachment)
    container = Path(sim('get_app_container', UDID, BUNDLE, 'data'))
    logfile = container / 'Library/Caches/heydan.log'
    if call_run:
        runner['TEST_RUNNER_HEYDAN_CALL_RUN'] = call_run
        runner['TEST_RUNNER_HEYDAN_CALL_AGENT'] = os.environ['HEYDAN_CALL_AGENT']
    baseline = len(logfile.read_text()) if logfile.exists() else 0
    revoked = container / 'Library/Caches/revoked-request.json'
    if name == 'app-unpair':
        if not os.environ.get('HEYDAN_REVOKED_CMD'):
            result(name, 'skip', 'Missing HEYDAN_REVOKED_CMD signed-request verifier')
            return
        revoked.unlink(missing_ok=True)
    screenshots = []
    try:
        with tempfile.TemporaryDirectory(prefix='chat-checks-', dir=BUILD) as temporary, push_driver(
                Path(temporary), method.startswith('ChatChecks/testPush')):
            if name == 'app-pair-screen':
                link_file = Path(temporary) / 'pair-link'
                with open(link_file, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as out:
                    out.write(pair_link())
            runner['TEST_RUNNER_HEYDAN_CHAT_CONTROL'] = temporary
            output = build('test-without-building', '-parallel-testing-enabled', 'NO',
                           '-resultBundlePath', Path(temporary) / 'checks.xcresult',
                           '-test-timeouts-enabled', 'YES',
                           '-default-test-execution-time-allowance', '120',
                           '-maximum-test-execution-time-allowance', '150',
                           '-only-testing:HeyDanChecks/' + method, seconds=240, env=runner)
            if name in ('app-push-communication', 'app-pair-screen', 'app-voice-picker-screen'):
                run('xcrun', 'xcresulttool', 'export', 'attachments',
                    '--path', Path(temporary) / 'checks.xcresult',
                    '--output-path', Path(temporary) / 'screenshots', '--filter', '*.png')
                destination = OUT / 'logs' / name
                destination.mkdir(exist_ok=True)
                for path in sorted((Path(temporary) / 'screenshots').glob('*.png')):
                    shutil.copyfile(path, destination / path.name)
                    screenshots.append(str((destination / path.name).relative_to(OUT)))
        if re.search(r'Executed 1 test, with 1 test skipped', output):
            reason = 'UI prerequisite unavailable; see check log'
            result(name, 'skip', reason, [f'logs/{name}.log'])
        elif 'Executed 1 test, with 0 failures' not in output:
            result(name, 'fail', 'Expected exactly one executed test with zero failures', [f'logs/{name}.log'])
        else:
            evidence = [f'logs/{name}.log', *screenshots]
            logfile = Path(sim('get_app_container', UDID, BUNDLE, 'data')) / 'Library/Caches/heydan.log'
            current = logfile.read_text() if logfile.exists() else ''
            delta = current[baseline:] if len(current) >= baseline else current
            if name == 'app-pair-screen':
                paired = 'pair ok' in delta
                result(name, 'pass' if paired else 'fail', 'Screen pairing acknowledged by server' if paired else 'Screen pairing acknowledgement missing', evidence)
            elif name == 'app-unpair':
                revoked = logfile.parent / 'revoked-request.json'
                try:
                    response = run('sh', '-c', os.environ['HEYDAN_REVOKED_CMD'],
                                   env=os.environ.copy() | {'HEYDAN_REVOKED_REQUEST': str(revoked)})
                    proof = json.loads(response.stdout)
                    passed = proof.get('status') == 401 and proof.get('error') == 'device_revoked'
                    result(name, 'pass' if passed else 'fail', 'Signed request refused after UI unpair' if passed else 'Revoked signed request was not refused as device_revoked', evidence)
                finally:
                    revoked.unlink(missing_ok=True)
            elif name == 'app-push-read-clears':
                counts = re.findall(r'check push delivered=(\d+) badge=(-?\d+)', delta)
                delivered = any(int(count) > 0 for count, _ in counts)
                cleared = bool(counts and counts[-1] == ('0', '0'))
                result(name, 'pass' if delivered and cleared else 'fail', 'Delivered notification and badge cleared' if delivered and cleared else 'Notification/badge cleanup not observed', evidence)
            elif name == 'app-paired-intent':
                deadline = time.monotonic() + 10
                while 'end reason=hangup acknowledged' not in delta and time.monotonic() < deadline:
                    time.sleep(0.25)
                    delta = logfile.read_text()[baseline:]
                passed = ('intent call-agent start mode=background' in delta and 'paired=true' in delta
                          and ' connected ms=' in delta and 'end reason=hangup acknowledged' in delta)
                result(name, 'pass' if passed else 'fail', 'Paired intent connected and ended' if passed else 'Paired intent call evidence missing', evidence)
            elif name == 'app-send-reply':
                stored = 'check send acknowledged' in delta and 'delivery=stored' in delta
                result(name, 'pass' if stored else 'fail', 'UI reply and stored acknowledgement observed' if stored else 'UI reply passed; stored acknowledgement missing', evidence)
            else:
                result(name, 'pass', 'One UI check executed with zero failures', evidence)
    except RuntimeError as error:
        result(name, 'fail', str(error), [f'logs/{name}.log'])
    finally:
        if name == 'app-unpair':
            revoked.unlink(missing_ok=True)
            with contextlib.suppress(RuntimeError, OSError):
                current = Path(sim('get_app_container', UDID, BUNDLE, 'data'))
                (current / 'Library/Caches/revoked-request.json').unlink(missing_ok=True)


def pair_link(variable='HEYDAN_PAIR_CMD'):
    command = os.environ[variable]
    # stdout is a secret and stderr is intentionally discarded by run().
    link = run('sh', '-c', command, env=os.environ.copy()).stdout.strip()
    if not link or '\n' in link:
        raise RuntimeError(f'{variable} did not return exactly one link')
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
    # Only the temporary directory name enters the XCTest environment. The runner seeds the
    # device-local pasteboard because simctl pbcopy can acknowledge a write without applying it.
    CHECK = 'app-pair-screen'
    ui_check('app-pair-screen', 'ChatChecks/testPastePair', stack=True)
    logfile = Path(sim('get_app_container', UDID, BUNDLE, 'data')) / 'Library/Caches/heydan.log'
    CHECK = 'app-paired-voice'
    offset = len(logfile.read_text()) if logfile.exists() else 0
    sim('launch', '--terminate-running-process', UDID, BUNDLE,
        env=ENV | {'SIMCTL_CHILD_HEYDAN_CHAT_CHECKS': '1', 'SIMCTL_CHILD_HEYDAN_CHECK_VOICE': '1'})
    deadline = time.monotonic() + 60
    voice_ok = False
    while time.monotonic() < deadline:
        delta = logfile.read_text()[offset:] if logfile.exists() else ''
        if 'check voice saved=true restored=true' in delta:
            voice_ok = True
            break
        if 'check voice failed' in delta:
            break
        time.sleep(.5)
    result(CHECK, 'pass' if voice_ok else 'fail', 'Saved voice read back and original restored' if voice_ok else 'Voice save/read/restore not proven')
    sim('terminate', UDID, BUNDLE, check=False)
    restart = os.environ.get('HEYDAN_STACK_RESTART_CMD')
    if restart:
        CHECK = 'app-resume-server'
        sim('launch', '--terminate-running-process', UDID, BUNDLE)
        time.sleep(3)
        before = logfile.read_text() if logfile.exists() else ''
        cursors = re.findall(r'synchronized cursor=(\d+)', before)
        if not cursors:
            result(CHECK, 'fail', 'No synchronized cursor before restart')
        else:
            offset = len(before)
            run('sh', '-c', restart, env=os.environ.copy(), seconds=120)
            deadline = time.monotonic() + 60
            resumed = False
            while time.monotonic() < deadline:
                delta = logfile.read_text()[offset:] if logfile.exists() else ''
                after = re.findall(r'synchronized cursor=(\d+)', delta)
                if after and int(after[-1]) >= int(cursors[-1]):
                    resumed = True
                    break
                time.sleep(.5)
            result(CHECK, 'pass' if resumed else 'fail', 'Cursor synchronized after host restart' if resumed else 'No resumed cursor within 60s')
        sim('terminate', UDID, BUNDLE, check=False)
    for name, method in APP_CHECKS.items():
        if name == 'app-history':
            CHECK = name
            logfile = Path(sim('get_app_container', UDID, BUNDLE, 'data')) / 'Library/Caches/heydan.log'
            offset = len(logfile.read_text()) if logfile.exists() else 0
            sim('launch', '--terminate-running-process', UDID, BUNDLE,
                env=ENV | {'SIMCTL_CHILD_HEYDAN_CHAT_CHECKS': '1', 'SIMCTL_CHILD_HEYDAN_CHECK_HISTORY': '1'})
            deadline = time.monotonic() + 30
            passed = False
            while time.monotonic() < deadline:
                delta = logfile.read_text()[offset:] if logfile.exists() else ''
                if 'check history before=true after=true' in delta:
                    passed = True
                    break
                time.sleep(.5)
            result(name, 'pass' if passed else 'fail', 'REST history pages verified in both directions' if passed else 'History before/after proof missing')
            sim('terminate', UDID, BUNDLE, check=False)
        if not method or name == 'app-pair-screen':
            continue
        if name.startswith('app-push-') and not bundle_ready(BUNDLE):
            result(name, 'skip', PUSH_BUNDLE)
        else:
            ui_check(name, 'ChatChecks/' + method, stack=True)


def report():
    order = ['sim-setup', 'sim-local-ca', 'sim-build', 'sim-permission', 'sim-call',
             'app-fixture-unread', *APP_CHECKS]
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
    for name in (() if call_only else ('sim-setup', 'sim-local-ca', 'sim-build', 'sim-permission', 'sim-call')):
        result(name, 'skip', 'Not reached in this invocation')
    no_stack = not os.environ.get('HEYDAN_LOCAL_BASE') or not os.environ.get('HEYDAN_PAIR_CMD')
    for name in (() if call_only else APP_CHECKS):
        result(name, 'skip', 'No local stack is running: HEYDAN_LOCAL_BASE and HEYDAN_PAIR_CMD required'
               if no_stack else 'Not reached in this invocation')
    if not call_only:
        result('app-push-extension', 'skip', 'simctl push does not execute the notification service extension; requires real APNs')
        result('app-push-edit', 'skip', 'Replacing a delivered banner requires a real APNs push')

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
    if call_only:
        sim('privacy', UDID, 'grant', 'microphone', BUNDLE)
        CHECK = 'sim-call'
        paired_test_call()
        return
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
        result(CHECK, 'fail', str(error))
    selected = set(filter(None, os.environ.get('HEYDAN_CHAT_ONLY', '').split(',')))
    if not selected or selected.intersection({'sim-call', 'app-paired-call', 'app-paired-intent'}):
        CHECK = 'sim-call'
        if not os.environ.get('HEYDAN_CALL_PAIR_CMD'):
            result(CHECK, 'skip', 'Missing HEYDAN_CALL_PAIR_CMD')
            return
        if not selected or selected.intersection({'sim-call', 'app-paired-call'}):
            paired_test_call()
        if not selected or 'app-paired-intent' in selected:
            paired_test_call(intent=True)


def call_launch_environment(run_id, agent, extra, device=False):
    hooks = ('HEYDAN_STEPS', 'HEYDAN_VOICE_STEPS', 'HEYDAN_FEED_ON_VOICE', 'HEYDAN_AUDIO_METER',
             'HEYDAN_PAIRED_ICE', 'HEYDAN_SIMULATE')
    variables = {} if 'HEYDAN_CALL_CLEANUP' in extra else {key: os.environ[key] for key in hooks if key in os.environ}
    variables.update(HEYDAN_CALL_AGENT=agent, HEYDAN_CALL_RUN=run_id, HEYDAN_AUTOCALL='1', HEYDAN_CHAT_CHECKS='1')
    prefix = 'DEVICECTL_CHILD_' if device else 'SIMCTL_CHILD_'
    return ENV | {prefix + key: value for key, value in (variables | extra).items()}


def paired_test_call(device=None, intent=False):
    if not os.environ.get('HEYDAN_CALL_PAIR_CMD'):
        raise RuntimeError('Missing HEYDAN_CALL_PAIR_CMD')
    agent = os.environ.get('HEYDAN_CALL_AGENT', '').strip()
    if not agent:
        raise RuntimeError('Missing HEYDAN_CALL_AGENT')
    duration = int(os.environ.get('HEYDAN_CALL_SECONDS', HANGUP_AFTER))
    if duration < 1:
        raise ValueError('Call duration must be positive')
    run_id = str(uuid.uuid4()).upper()
    speech = os.environ.get('HEYDAN_CALL_SAY') or os.environ.get('HEYDAN_E2E_SAY') or f'Hey {agent}. What is two plus two? Zulu.'
    run('say', '-o', BUILD / 'feed.aiff', '-f', '-', stdin=speech)
    wav = BUILD / 'feed.wav'
    run('afconvert', '-f', 'WAVE', '-d', 'LEF32@48000', '-c', '1', BUILD / 'feed.aiff', wav)
    if device:
        domain = ['--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE]
        run('xcrun', 'devicectl', 'device', 'copy', 'to', *domain, '--source', wav, '--destination', 'Library/Caches/feed.wav')
        logfile = OUT / 'logs' / 'phone-app.log'
    else:
        logfile = Path(sim('get_app_container', UDID, BUNDLE, 'data')) / 'Library/Caches/heydan.log'

    def read_log():
        if device:
            copied = run('xcrun', 'devicectl', 'device', 'copy', 'from', *domain, '--source', 'Library/Caches/heydan.log',
                         '--destination', logfile, check=False)
            if copied.returncode:
                return ''
        return logfile.read_text() if logfile.exists() else ''

    def launch(extra):
        env = call_launch_environment(run_id, agent, extra, device)
        if device:
            run('xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing', '--device', device, BUNDLE, env=env)
        else:
            sim('launch', '--terminate-running-process', UDID, BUNDLE, env=env)

    marker = f'test unpair run={run_id} ok=true'
    text = ''
    baseline = len(read_log())
    link = pair_link('HEYDAN_CALL_PAIR_CMD')
    try:
        if intent:
            launch({'HEYDAN_CALL_PAIR_LINK': link, 'HEYDAN_CALL_SEED': '1'})
            deadline = time.monotonic() + LAUNCH_BOUND
            while time.monotonic() < deadline:
                text = read_log()[baseline:]
                if f'test intent ready run={run_id}' in text:
                    break
                if REFUSED in text:
                    raise RuntimeError('Intent test pairing refused')
                time.sleep(1)
            else:
                raise RuntimeError('Intent test pairing timed out')
            ui_check('app-paired-intent', 'ChatChecks/testPairedIntent', call_run=run_id)
            return
        launch({'HEYDAN_CALL_PAIR_LINK': link, 'HEYDAN_HANGUP_AFTER': str(duration),
                'HEYDAN_FEED_WAV': 'feed.wav' if device else str(wav), 'HEYDAN_FEED_AFTER': '12'})
        deadline = time.monotonic() + LAUNCH_BOUND + duration
        while time.monotonic() < deadline:
            text = read_log()[baseline:]
            if marker in text or REFUSED in text:
                break
            time.sleep(1)
        evidence = 'logs/paired-call.log'
        (OUT / evidence).write_text(text)
        paired = f'test pair run={run_id} device=' in text
        result('app-call-pair', 'pass' if paired else 'fail', 'Disposable device paired' if paired else 'Pairing not observed')
        grade_result = grade(text)
        passed = paired and all(grade_result[k] for k in ('connected', 'reply', 'audio', 'clean', 'ended', 'fed'))
        result('sim-call' if not device else 'device-call', 'pass' if passed else 'fail',
               ', '.join(f'{k}={v}' for k, v in grade_result.items()), [evidence])
        result('app-paired-call', 'pass' if grade_paired(text) else 'fail', 'Graded signed hangup, call audio and thread voice marks', [evidence])
    finally:
        if marker not in text:
            launch({'HEYDAN_CALL_CLEANUP': '1'})
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                text = read_log()[baseline:]
                if marker in text:
                    break
                time.sleep(1)
        result('app-call-unpair', 'pass' if marker in text else 'fail',
               'Test pairing cleared' if marker in text else 'Test pairing cleanup unconfirmed')


if __name__ == '__main__':
    BUNDLE = sys.argv[1]
    call_only = sys.argv[2:3] == ['call']
    for directory in (OUT / 'results', OUT / 'logs', BUILD):
        directory.mkdir(parents=True, exist_ok=True)
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, stop)
    try:
        if sys.argv[2:3] == ['device-call']:
            CHECK = 'device-call'
            paired_test_call(device=sys.argv[3])
        else:
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
        report()
        if UDID:
            sim('terminate', UDID, BUNDLE, check=False)
