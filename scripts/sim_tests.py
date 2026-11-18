from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


TEST_SECONDS = 180
TEST_FLAGS = ['-collect-test-diagnostics', 'never', '-enableCodeCoverage', 'NO',
              '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
              '-default-test-execution-time-allowance', str(TEST_SECONDS),
              '-maximum-test-execution-time-allowance', str(TEST_SECONDS)]


def build_key():
    digest = hashlib.sha256()
    for command in (['git', 'rev-parse', 'HEAD'], ['git', 'diff', '--binary', 'HEAD'],
                    ['xcrun', '--show-sdk-build-version', '--sdk', 'iphonesimulator']):
        digest.update(subprocess.check_output(command))
    untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'])
    for name in sorted(filter(None, [b'Local.xcconfig', *untracked.split(b'\0')])):
        path = Path(os.fsdecode(name))
        if path.is_file():
            digest.update(name + b'\0' + hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def test_products(build, destination, env):
    products = build / 'Build/Products'
    stamp = build / 'HeyDanSimulatorTests.key'
    key = build_key()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
    pattern = f'HeyDanSimulatorTests_iphonesimulator{sdk}-*.xctestrun'
    manifests = list(products.glob(pattern))
    apps = products / 'Debug-iphonesimulator'
    executables = [apps / 'HeyDan.app/HeyDan', apps / 'HeyDan.app/PlugIns/HeyDanTests.xctest/HeyDanTests',
                   apps / 'HeyDanChecks-Runner.app/PlugIns/HeyDanChecks.xctest/HeyDanChecks']
    if (stamp.is_file() and stamp.read_text() == key and len(manifests) == 1
            and all(p.is_file() and p.stat().st_mtime_ns <= stamp.stat().st_mtime_ns
                    for p in [*executables, *manifests])):
        print('Reusing Simulator test products', flush=True)
        return manifests[0]

    stamp.unlink(missing_ok=True)
    subprocess.run(['xcodegen', 'generate', *(['--use-cache'] if Path('HeyDan.xcodeproj').is_dir() else [])], check=True)
    build_env = env.copy()
    if 'XCODE_XCCONFIG_FILE' in os.environ:
        build_env['XCODE_XCCONFIG_FILE'] = os.environ['XCODE_XCCONFIG_FILE']
    subprocess.run(['timeout', '900', 'xcodebuild', 'build-for-testing', '-project', 'HeyDan.xcodeproj',
                    '-scheme', 'HeyDanSimulatorTests', '-destination', destination, '-derivedDataPath', build,
                    '-disableAutomaticPackageResolution', '-skipPackageUpdates', '-enableCodeCoverage', 'NO',
                    # Nothing reads a command-line build's index; Xcode indexes in its own DerivedData.
                    'COMPILER_INDEX_STORE_ENABLE=NO', '-quiet'], check=True, env=build_env)
    manifest, = products.glob(pattern)
    stamp.write_text(key)
    return manifest


def ui_selector(check):
    if check.startswith('HeyDanChecks/Chat') or check.startswith('HeyDanChecks/HeyDanChecks'):
        return check
    if '/' in check or check.endswith('Checks'):
        return 'HeyDanChecks/' + check
    return 'HeyDanChecks/HeyDanChecks/test' + check


def selected_tests(inventory, selector):
    # Xcode's flat list includes the plan heading and every excluded test marked "(disabled)".
    return sum(line.strip().startswith(selector + '/') and not line.rstrip().endswith(' (disabled)')
               for line in inventory.splitlines())


def needs_call_link(selector):
    return selector.split('/')[:2] == ['HeyDanChecks', 'HeyDanChecks']


@contextmanager
def test_results(build, keep_failed):
    with tempfile.TemporaryDirectory() as results:
        try:
            yield results
        except Exception:
            bundles = list(Path(results).glob('*.xcresult'))
            if keep_failed and bundles:
                directory = Path(tempfile.mkdtemp(prefix='failed-tests-', dir=build))
                for bundle in bundles:
                    shutil.move(bundle, directory / bundle.name)
                print(f'Failed result bundle retained locally in {directory}', file=sys.stderr)
            raise


def main(mode, name, folder, bundle, check=None, capture_dir=None):
    env = {k: v for k, v in os.environ.items() if k in
           ('PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL', 'USER', 'LOGNAME')}
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
    udid = next((d['udid'] for runtime in devices['devices'].values() for d in runtime if d['name'] == name), None)
    if not udid:
        raise RuntimeError(f'No Simulator named {name}')
    build = Path(folder).resolve()
    build.mkdir(parents=True, exist_ok=True)
    with (build / 'HeyDanSimulatorTests.lock').open('a') as lock, test_results(
            build, os.environ.get('HEYDAN_KEEP_FAILED_RESULTS') == '1') as results:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sim = ['xcrun', 'simctl']
        destination = f'id={udid}'
        started = time.monotonic()
        # Build before booting: beside a booted Simulator the build takes two to three times as long on CI.
        manifest = test_products(build, destination, env)
        build_seconds = time.monotonic() - started
        subprocess.run([*sim, 'bootstatus', udid, '-b'], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([*sim, 'spawn', udid, 'launchctl', 'kickstart', '-k',
                        f'user/{os.getuid()}/com.apple.dasd'], check=True)
        started = time.monotonic()
        runner = env.copy()

        def test(selector):
            result = Path(results) / (selector.replace('/', '-') + '.xcresult')
            command = ['xcodebuild', 'test-without-building', '-xctestrun', manifest, '-destination', destination,
                       *TEST_FLAGS, '-only-testing:' + selector,
                       # CI names what a Simulator that never ran the app cannot pass.
                       *('-skip-testing:' + skip for skip in os.environ.get('HEYDAN_SKIP_TESTS', '').split())]
            count = 1
            if selector.count('/') < 2:
                inventory = Path(results) / 'tests.txt'
                subprocess.run(['timeout', '180', *command, '-enumerate-tests', '-test-enumeration-style', 'flat',
                                '-test-enumeration-format', 'text', '-test-enumeration-output-path', inventory],
                               check=True, env=runner, stdout=subprocess.DEVNULL)
                count = max(1, selected_tests(inventory.read_text(), selector))
            # XCTest enforces each method's limit. The process watchdog also allows for Simulator startup and teardown.
            deadline = str(240 + TEST_SECONDS * count)
            proc = subprocess.run(['timeout', '--foreground', '--kill-after=10', deadline, *command,
                                   '-resultBundlePath', result],
                                  env=runner, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            # XCTest activity trees and assertion values can contain chat text or pairing links.
            for line in proc.stdout.splitlines():
                if re.match(r"^(check:|Test Case '.*' (passed|failed|skipped)|\s*Executed \d+ tests?|.*Test run with \d+ tests|\*\* TEST)", line):
                    print(line)
                elif 'error:' in line:
                    print(re.search(r'[^ /]+\.swift:\d+: error:', line)[0] if re.search(r'[^ /]+\.swift:\d+: error:', line)
                          else 'xcodebuild reported an error')
            proc.check_returncode()
            summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results',
                                                          'summary', '--path', result]))
            if mode == 'screens' and (summary['skippedTests'] or not summary['passedTests']):
                raise RuntimeError('Incomplete screen checks')
            if not summary['totalTestCount']:
                raise RuntimeError(f'No tests ran for {selector}')
            # A skipped test counts in the total and exits 0: a run in which nothing passed proves nothing.
            if not summary.get('passedTests'):
                raise RuntimeError(f'No test passed for {selector} ({summary.get("skippedTests", 0)} skipped)')

        subprocess.run([*sim, 'install', udid, build / 'Build/Products/Debug-iphonesimulator/HeyDan.app'], check=True)
        selector = 'HeyDanTests' if mode == 'app-test' else ui_selector(check)
        if 'Push' in selector and bundle == 'com.example.HeyDan':
            raise RuntimeError('Simulator push checks need HEYDAN_BUNDLE_ID in Local.xcconfig')
        if mode == 'sim-checks':
            subprocess.run([*sim, 'privacy', udid, 'grant', 'microphone', bundle], check=True)
            if needs_call_link(selector):
                link = subprocess.check_output(['just', '_test-link'], text=True).strip()
                subprocess.run([*sim, 'launch', '--terminate-running-process', udid, bundle], check=True,
                               env={**env, 'SIMCTL_CHILD_HEYDAN_CALL_LINK': link}, stdout=subprocess.DEVNULL)
                time.sleep(3)
                subprocess.run([*sim, 'terminate', udid, bundle], check=True)
            out = Path('build/checks').resolve()
            out.mkdir(parents=True, exist_ok=True)
            # Links and the stack's commands can carry secrets, and a result bundle records the runner's environment.
            withheld = {'HEYDAN_CALL_LINK', 'HEYDAN_E2E_CALL_LINK', 'HEYDAN_PAIR_LINK'}
            runner.update({'TEST_RUNNER_' + k: v for k, v in os.environ.items()
                           if k.startswith('HEYDAN_') and k not in withheld and not k.endswith('_CMD')})
            runner['TEST_RUNNER_HEYDAN_CHECKS_OUT'] = str(out)
        if mode == 'screens' or selector.startswith('HeyDanChecks/ScreenCaptureChecks'):
            runner['TEST_RUNNER_HEYDAN_SCREENS'] = '1'
            if capture_dir:
                runner['TEST_RUNNER_HEYDAN_CHECKS_OUT'] = str(capture_dir)
            if mode == 'screens' or selector.endswith(('/testPairing', '/testVoiceLines', '/ScreenCaptureChecks')):
                subprocess.run([*sim, 'keychain', udid, 'reset'], check=True)
            appearance = [*sim, 'ui', udid, 'appearance']
            original = subprocess.check_output(appearance, text=True).strip().split()[-1].lower()
            try:
                subprocess.run([*appearance, 'dark'], check=True)
                test(selector)
            finally:
                subprocess.run([*appearance, original], check=True)
                print(f'Build: {build_seconds:.1f}s; capture: {time.monotonic() - started:.1f}s', flush=True)
        else:
            test(selector)


if __name__ == '__main__':
    try:
        main(*sys.argv[1:])
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
