#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import sim_tests
spec =importlib.util.spec_from_file_location('sim_e2e', Path(__file__).with_name('sim-e2e.py'))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)

class SimulatorSelectionTests(unittest.TestCase):

    def test_call_launch_forwards_drills_only_to_the_call(self):
        hooks = {'HEYDAN_STEPS': '8:mute,9:unmute', 'HEYDAN_PAIR_CMD': 'unused', 'HEYDAN_PAIR_LINK': 'unused',
                 'HEYDAN_CALL_RUN': 'wrong', 'HEYDAN_CALL_PAIR_CMD': 'unused'}
        with patch.dict(os.environ, hooks):
            for device, prefix in [(False, 'SIMCTL_CHILD_'), (True, 'DEVICECTL_CHILD_')]:
                launched = harness.call_launch_environment('run', 'Test Agent', {}, device)
                self.assertEqual(launched[prefix + 'HEYDAN_STEPS'], hooks['HEYDAN_STEPS'])
                self.assertEqual(launched[prefix + 'HEYDAN_CALL_RUN'], 'run')
                self.assertEqual(launched[prefix + 'HEYDAN_CALL_AGENT'], 'Test Agent')
                self.assertFalse(any(key.endswith(('_CMD', '_LINK')) for key in launched))
                cleanup = harness.call_launch_environment('run', 'Test Agent', {'HEYDAN_CALL_CLEANUP': '1'}, device)
                self.assertNotIn(prefix + 'HEYDAN_STEPS', cleanup)

    def test_deadline_counts_only_enabled_tests_in_the_selection(self):
        inventory = ("Plan HeyDanSimulatorTests\n"
                     "\tHeyDanChecks/ChatCallChecks/testCover()\n"
                     "\tHeyDanChecks/ChatCallChecks/testOther() (disabled)\n"
                     "\tHeyDanChecks/ChatChecks/testHistory() (disabled)\n")
        self.assertEqual(sim_tests.selected_tests(inventory, 'HeyDanChecks/ChatCallChecks'), 1)
        self.assertEqual(sim_tests.selected_tests(inventory, 'HeyDanChecks/ChatChecks'), 0)

    def test_result_bundle_retained_only_for_an_opted_in_failure(self):
        for keep, fail in ((False, True), (True, False), (True, True)):
            with self.subTest(keep=keep, fail=fail), tempfile.TemporaryDirectory() as build:
                try:
                    with sim_tests.test_results(Path(build), keep) as results:
                        (Path(results) / 'test.xcresult').mkdir()
                        if fail:
                            raise RuntimeError('test failed')
                except RuntimeError:
                    self.assertTrue(fail)
                self.assertEqual(bool(list(Path(build).glob('failed-tests-*/*.xcresult'))), keep and fail)


# Real app log lines (trimmed), so a changed log line or SDK error description fails here first.
JEV_CALL = '''\
19:48:04.939 N call c=3667770a +0ms claim paired=true
19:48:04.950 N audio debug feed: wav frames=133120 after=12.0s
19:48:08.029 N room c=3667770a cid=0e77951f +3089ms connected ms=1265
19:48:08.066 N room c=3667770a cid=0e77951f +3127ms agent audio subscribed sid=TR_AMU6MTWnsqJCwL
19:48:08.083 N call c=3667770a cid=0e77951f +3144ms live
19:48:20.762 N stream c=3667770a cid=0e77951f +15823ms e2e caption final caller=true
19:48:21.185 I room c=3667770a cid=0e77951f +16245ms agent state=listening thinking=1 updating=- commands=- review=- protocol=6 changed=[thinking]
19:48:24.332 N stream c=3667770a cid=0e77951f +19392ms e2e caption final caller=false
19:49:10.186 N call c=3667770a cid=0e77951f +65246ms finish site=provider(_:perform:) cause=caller cx=- host=- connected=true mic=true live=true streams=[transcription=7]
19:49:10.264 N net cid=0e77951f end reason=hangup acknowledged ms=35
'''
JEV_APP_CALL = JEV_CALL.replace('commands=- review=-', 'commands=3').replace('transcription=7]', 'review=1,transcription=7]')
PLAIN_CALL = '''\
20:30:50.960 N call c=0a2dc0d8 +0ms claim paired=true
20:30:50.961 N audio debug feed: wav frames=139264 after=12.0s
20:30:54.275 N room c=0a2dc0d8 cid=cb682391 +3315ms connected ms=292
20:30:54.843 N room c=0a2dc0d8 cid=cb682391 +3883ms agent audio subscribed sid=TR_AMNEQttAfKcAHw
20:30:54.864 N call c=0a2dc0d8 cid=cb682391 +3903ms live
20:31:07.682 I room c=0a2dc0d8 cid=cb682391 +16722ms agent state=listening thinking=1 updating=- commands=3 review=1 protocol=6
20:31:07.784 N stream c=0a2dc0d8 cid=cb682391 +16824ms e2e caption final caller=true
20:31:08.187 N stream c=0a2dc0d8 cid=cb682391 +17227ms e2e reply turn=true notice=false unspoken=false
20:31:09.099 N stream c=0a2dc0d8 cid=cb682391 +18138ms e2e caption final caller=false
20:31:56.087 N call c=0a2dc0d8 cid=cb682391 +65126ms finish site=provider(_:perform:) cause=caller cx=- host=- connected=true mic=true live=true streams=[transcription=6,reply=1,review=3,turn=3]
20:31:57.087 N net cid=cb682391 end reason=hangup acknowledged ms=956
'''
CONNECT_TIMEOUT = '''\
15:06:38.823 N room c=c9f5d656 cid=d4098288 +11622ms state .connecting -> .disconnected
15:06:38.824 E room c=c9f5d656 cid=d4098288 +11624ms connect failed LiveKitError(Timed out) ms=10130
15:06:38.830 E call c=c9f5d656 cid=d4098288 +11630ms setup failed CallFailure(roomConnect)
15:06:38.835 N call c=c9f5d656 cid=d4098288 +11634ms finish site=connect(_:) cause=failure cx=1 host=- connected=false mic=false live=false streams=[]
15:06:38.894 N net cid=d4098288 end reason=hangup acknowledged ms=13
'''
REFUSED = '19:48:04.938 E call debug autocall refused: invalid test pairing\n'
PROOF = ('connected', 'reply', 'audio', 'clean', 'ended', 'fed')


class Grade(unittest.TestCase):
    def test_jev_call_passes(self):
        for call in (JEV_CALL, JEV_APP_CALL):
            with self.subTest(app_settings=call == JEV_APP_CALL):
                grade = harness.grade(call)
                self.assertEqual(grade['mode'], 'jev')
                self.assertTrue(all(grade[key] for key in PROOF), grade)

    def test_plain_call_passes(self):
        grade = harness.grade(PLAIN_CALL)
        self.assertEqual(grade['mode'], 'plain')
        self.assertTrue(all(grade[key] for key in PROOF), grade)

    def test_plain_call_needs_its_reply_event(self):
        without_reply = ''.join(line for line in PLAIN_CALL.splitlines(True) if 'e2e reply' not in line)
        self.assertEqual(harness.grade(without_reply)['mode'], 'plain')
        self.assertFalse(harness.grade(without_reply)['reply'])
        announced = 'command words announced send=1 discard=1\n' + JEV_APP_CALL
        self.assertEqual(harness.grade(announced)['mode'], 'plain')
        self.assertFalse(harness.grade(announced)['reply'])
        self.assertFalse(harness.grade('agent state=listening commands=- pending\n' + without_reply)['reply'])
        self.assertFalse(harness.grade(PLAIN_CALL.replace('notice=false', 'notice=true'))['reply'])

    def test_jev_call_needs_the_agent_caption(self):
        self.assertFalse(harness.grade(JEV_CALL.replace('caller=false', 'caller=true'))['reply'])

    def test_connect_timeout_is_retryable(self):
        grade = harness.grade(CONNECT_TIMEOUT)
        self.assertTrue(grade['connect_timeout'] and grade['ended'])
        self.assertFalse(harness.grade(JEV_CALL)['connect_timeout'])

    def test_paired_call_requires_mode_specific_marks_and_paired_end(self):
        caller = '\ncheck thread voice=caller id=msg_a\n'
        spoken = '\ncheck thread voice=spoken id=msg_b\n'
        for original in (JEV_CALL, JEV_APP_CALL, PLAIN_CALL):
            paired = original.replace('end reason=hangup acknowledged', 'end reason=hangup acknowledged paired=true')
            with self.subTest(mode=harness.grade(original)['mode']):
                self.assertTrue(harness.grade_paired(paired + caller + spoken))
                self.assertEqual(harness.grade_paired(paired + caller), original != PLAIN_CALL)
                self.assertFalse(harness.grade_paired(paired + spoken))
                self.assertFalse(harness.grade_paired(original + caller + spoken))

    def test_refused_autocall(self):
        self.assertTrue(harness.grade(REFUSED)['refused'])
        self.assertFalse(harness.grade(JEV_CALL)['refused'])


class ChatResults(unittest.TestCase):
    def test_placeholder_bundle_skips_only_the_push_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / 'results').mkdir()
            with patch.object(harness, 'OUT', output), patch.object(harness, 'BUNDLE', 'com.example.HeyDan', create=True), \
                 patch.object(harness, 'RECORDS', {}), patch.dict(os.environ, {}, clear=True), \
                 patch.object(harness, 'ui_check') as ui_check:
                harness.chat_checks()
                ui_check.assert_called_once_with('app-fixture-unread', 'ChatChecks/testFixtureUnreadRelaunch')
                self.assertEqual(harness.RECORDS['app-push-communication']['status'], 'skip')
                self.assertIn('Local.xcconfig', harness.RECORDS['app-push-communication']['detail'])

@unittest.skipUnless(shutil.which('timeout'), 'GNU timeout is not installed')
class Run(unittest.TestCase):
    def test_stderr_stays_out_of_parsed_output(self):
        self.assertEqual(harness.run('sh', '-c', 'echo out; echo err >&2').stdout, 'out\n')

    def test_signal_ends_the_whole_command_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / 'grandchild.pid'

            def interrupt():
                # Blocked here, the signal lands on the main thread, as it does in the single-threaded harness.
                signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
                while not (pidfile.exists() and pidfile.read_text().strip()):
                    time.sleep(0.05)
                time.sleep(0.2)
                os.kill(os.getpid(), signal.SIGTERM)

            previous = signal.signal(signal.SIGTERM, harness.stop)
            threading.Thread(target=interrupt, daemon=True).start()
            try:
                with self.assertRaises(harness.Stopped):
                    harness.run('sh', '-c', f'sleep 300 & echo $! > {pidfile}; wait')
            finally:
                signal.signal(signal.SIGTERM, previous)
                harness.STOPPED_BY = None
            grandchild = int(pidfile.read_text())
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(grandchild, 0)
                except ProcessLookupError:
                    return
                time.sleep(0.05)
            os.kill(grandchild, signal.SIGKILL)
            self.fail('the command started by the wrapped process outlived the signal')


if __name__ == '__main__':
    unittest.main()
