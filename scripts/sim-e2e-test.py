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
spec =importlib.util.spec_from_file_location('sim_e2e', Path(__file__).with_name('sim-e2e.py'))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)

# Real app log lines (trimmed), so a changed log line or SDK error description fails here first.
JEV_CALL = '''\
19:48:04.939 N call c=3667770a +0ms claim line=4462b845 mode=auto
19:48:04.950 N audio debug feed: wav frames=133120 after=12.0s
19:48:08.029 N room c=3667770a cid=0e77951f +3089ms connected ms=1265
19:48:08.066 N room c=3667770a cid=0e77951f +3127ms agent audio subscribed sid=TR_AMU6MTWnsqJCwL
19:48:08.083 N call c=3667770a cid=0e77951f +3144ms live
19:48:16.121 N call c=3667770a cid=0e77951f +11182ms review grace ran out: not offered, the call runs hands-free
19:48:20.762 N stream c=3667770a cid=0e77951f +15823ms e2e caption final caller=true
19:48:21.185 I room c=3667770a cid=0e77951f +16245ms agent state=listening thinking=1 updating=- commands=- review=- protocol=6 changed=[thinking]
19:48:24.332 N stream c=3667770a cid=0e77951f +19392ms e2e caption final caller=false
19:49:10.186 N call c=3667770a cid=0e77951f +65246ms finish site=provider(_:perform:) cause=caller cx=- host=- connected=true mic=true live=true streams=[transcription=7]
19:49:10.264 N net cid=0e77951f end reason=hangup status=204 ms=35
'''
PLAIN_CALL = '''\
20:30:50.960 N call c=0a2dc0d8 +0ms claim line=3f8dbb00 mode=auto
20:30:50.961 N audio debug feed: wav frames=139264 after=12.0s
20:30:54.275 N room c=0a2dc0d8 cid=cb682391 +3315ms connected ms=292
20:30:54.843 N room c=0a2dc0d8 cid=cb682391 +3883ms agent audio subscribed sid=TR_AMNEQttAfKcAHw
20:30:54.864 N call c=0a2dc0d8 cid=cb682391 +3903ms live
20:30:54.870 N call c=0a2dc0d8 cid=cb682391 +3910ms review offered
20:31:07.682 I room c=0a2dc0d8 cid=cb682391 +16722ms agent state=listening thinking=1 updating=- commands=3 review=1 protocol=6
20:31:07.784 N stream c=0a2dc0d8 cid=cb682391 +16824ms e2e caption final caller=true
20:31:08.187 N stream c=0a2dc0d8 cid=cb682391 +17227ms e2e reply turn=true notice=false unspoken=false
20:31:09.099 N stream c=0a2dc0d8 cid=cb682391 +18138ms e2e caption final caller=false
20:31:56.087 N call c=0a2dc0d8 cid=cb682391 +65126ms finish site=provider(_:perform:) cause=caller cx=- host=- connected=true mic=true live=true streams=[transcription=6,reply=1,review=3,turn=3]
20:31:57.087 N net cid=cb682391 end reason=hangup status=204 ms=956
'''
CONNECT_TIMEOUT = '''\
15:06:38.823 N room c=c9f5d656 cid=d4098288 +11622ms state .connecting -> .disconnected
15:06:38.824 E room c=c9f5d656 cid=d4098288 +11624ms connect failed LiveKitError(Timed out) ms=10130
15:06:38.830 E call c=c9f5d656 cid=d4098288 +11630ms setup failed CallFailure(roomConnect)
15:06:38.835 N call c=c9f5d656 cid=d4098288 +11634ms finish site=connect(_:) cause=failure cx=1 host=- connected=false mic=false live=false streams=[]
15:06:38.894 N net cid=d4098288 end reason=hangup status=204 ms=13
'''
REFUSED = '19:48:04.938 E call debug autocall refused: supplied line invalid or not selected\n'
PROOF = ('connected', 'reply', 'audio', 'clean', 'ended', 'fed')


class Grade(unittest.TestCase):
    def test_jev_call_passes(self):
        grade = harness.grade(JEV_CALL)
        self.assertEqual(grade['mode'], 'jev')
        self.assertTrue(all(grade[key] for key in PROOF), grade)

    def test_plain_call_passes(self):
        grade = harness.grade(PLAIN_CALL)
        self.assertEqual(grade['mode'], 'plain')
        self.assertTrue(all(grade[key] for key in PROOF), grade)

    def test_plain_call_needs_its_reply_event(self):
        without_reply = ''.join(line for line in PLAIN_CALL.splitlines(True) if 'e2e reply' not in line)
        self.assertFalse(harness.grade(without_reply)['reply'])
        self.assertFalse(harness.grade(PLAIN_CALL.replace('notice=false', 'notice=true'))['reply'])

    def test_jev_call_needs_the_agent_caption(self):
        self.assertFalse(harness.grade(JEV_CALL.replace('caller=false', 'caller=true'))['reply'])

    def test_connect_timeout_is_retryable(self):
        grade = harness.grade(CONNECT_TIMEOUT)
        self.assertTrue(grade['connect_timeout'] and grade['ended'])
        self.assertFalse(harness.grade(JEV_CALL)['connect_timeout'])

    def test_paired_call_requires_both_thread_marks_and_paired_end(self):
        paired = JEV_CALL.replace('status=204 ms=35', 'status=204 ms=35 paired=true')
        marks = '\ncheck thread voice=caller id=msg_a\ncheck thread voice=spoken id=msg_b\n'
        self.assertTrue(harness.grade_paired(paired + marks))
        self.assertFalse(harness.grade_paired(paired + marks.replace('voice=spoken', 'voice=unknown')))
        self.assertFalse(harness.grade_paired(paired + marks.replace('voice=caller', 'voice=unknown')))
        self.assertFalse(harness.grade_paired(JEV_CALL + marks))

    def test_refused_autocall(self):
        self.assertTrue(harness.grade(REFUSED)['refused'])
        self.assertFalse(harness.grade(JEV_CALL)['refused'])


class ChatResults(unittest.TestCase):
    def test_missing_bundle_reports_each_check_without_starting_simulator(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / 'results').mkdir()
            with patch.object(harness, 'OUT', output), patch.object(harness, 'BUNDLE', 'com.example.HeyDan', create=True), \
                 patch.object(harness, 'RECORDS', {}), patch.dict(os.environ, {}, clear=True), \
                 patch.object(harness, 'sim') as sim:
                with self.assertRaisesRegex(RuntimeError, 'Local.xcconfig'):
                    harness.main()
                sim.assert_not_called()
                for name in harness.APP_CHECKS:
                    self.assertEqual(harness.RECORDS[name]['status'], 'skip')
                harness.report()
                self.assertTrue((output / 'report.md').exists())
                self.assertIn('No local stack is running', (output / 'report.md').read_text())

    def test_real_bundle_required(self):
        self.assertTrue(harness.bundle_ready('com.tenequm.HeyDan'))
        self.assertFalse(harness.bundle_ready('com.example.HeyDan'))
        self.assertFalse(harness.bundle_ready(''))


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
