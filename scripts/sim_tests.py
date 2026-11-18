import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


TEST_FLAGS = ['-collect-test-diagnostics', 'never', '-enableCodeCoverage', 'NO',
              '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
              '-default-test-execution-time-allowance', '180']


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
    subprocess.run(['timeout', '900', 'xcodebuild', 'build-for-testing', '-project', 'HeyDan.xcodeproj',
                    '-scheme', 'HeyDanSimulatorTests', '-destination', destination, '-derivedDataPath', build,
                    '-disableAutomaticPackageResolution', '-skipPackageUpdates', '-enableCodeCoverage', 'NO',
                    # Nothing reads a command-line build's index; Xcode indexes in its own DerivedData.
                    'COMPILER_INDEX_STORE_ENABLE=NO', '-quiet'], check=True, env=env)
    manifest, = products.glob(pattern)
    stamp.write_text(key)
    return manifest


def ui_selector(check):
    if check.startswith('HeyDanChecks/Chat') or check.startswith('HeyDanChecks/HeyDanChecks'):
        return check
    if '/' in check or check.endswith('Checks'):
        return 'HeyDanChecks/' + check
    return 'HeyDanChecks/HeyDanChecks/test' + check


def main(mode, name, folder, bundle, check=None):
    env = {k: v for k, v in os.environ.items() if k in
           ('PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL', 'USER', 'LOGNAME')}
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
    udid = next((d['udid'] for runtime in devices['devices'].values() for d in runtime if d['name'] == name), None)
    if not udid:
        raise RuntimeError(f'No Simulator named {name}')
    build = Path(folder).resolve()
    build.mkdir(parents=True, exist_ok=True)
    with (build / 'HeyDanSimulatorTests.lock').open('a') as lock, tempfile.TemporaryDirectory() as results:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sim = ['xcrun', 'simctl']
        subprocess.run([*sim, 'bootstatus', udid, '-b'], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([*sim, 'spawn', udid, 'launchctl', 'kickstart', '-k',
                        f'user/{os.getuid()}/com.apple.dasd'], check=True)
        destination = f'id={udid}'
        manifest = test_products(build, destination, env)
        runner = env.copy()

        def test(selector):
            result = Path(results) / (selector.replace('/', '-') + '.xcresult')
            proc = subprocess.run(['timeout', '--foreground', '--kill-after=10', '600', 'xcodebuild',
                                   'test-without-building', '-xctestrun', manifest, '-destination', destination,
                                   *TEST_FLAGS, '-resultBundlePath', result, '-only-testing:' + selector],
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
            if not summary['totalTestCount']:
                raise RuntimeError(f'No tests ran for {selector}')

        subprocess.run([*sim, 'install', udid, build / 'Build/Products/Debug-iphonesimulator/HeyDan.app'], check=True)
        selector = 'HeyDanTests' if mode == 'app-test' else ui_selector(check)
        if 'Push' in selector and bundle == 'com.example.HeyDan':
            raise RuntimeError('Simulator push checks need HEYDAN_BUNDLE_ID in Local.xcconfig')
        if mode == 'sim-checks':
            subprocess.run([*sim, 'privacy', udid, 'grant', 'microphone', bundle], check=True)
            if selector.startswith('HeyDanChecks/HeyDanChecks/test'):
                link = subprocess.check_output(['just', '_test-link'], text=True).strip()
                subprocess.run([*sim, 'launch', '--terminate-running-process', udid, bundle], check=True,
                               env={**env, 'SIMCTL_CHILD_HEYDAN_CALL_LINK': link}, stdout=subprocess.DEVNULL)
                time.sleep(3)
                subprocess.run([*sim, 'terminate', udid, bundle], check=True)
            out = Path('build/checks').resolve()
            out.mkdir(parents=True, exist_ok=True)
            withheld = {'HEYDAN_CALL_LINK', 'HEYDAN_E2E_CALL_LINK', 'HEYDAN_PAIR_LINK', 'HEYDAN_PAIR_CMD'}
            runner.update({'TEST_RUNNER_' + k: v for k, v in os.environ.items()
                           if k.startswith('HEYDAN_') and k not in withheld})
            runner['TEST_RUNNER_HEYDAN_CHECKS_OUT'] = str(out)
        test(selector)


if __name__ == '__main__':
    try:
        main(*sys.argv[1:])
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
