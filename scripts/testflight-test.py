import importlib.util
import io
from contextlib import redirect_stderr
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("testflight", Path(__file__).with_name("testflight-wait.py"))
testflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(testflight)


class VersionGuardTests(unittest.TestCase):
    bundle = "com.example.HeyDan.beta"
    app = {"data": {"attributes": {"bundleId": bundle}}}

    def check(self, current, latest, mode="upload"):
        response = {"data": []}
        if latest:
            response = {"data": [{"attributes": {"version": "123"}}],
                        "included": [{"type": "preReleaseVersions", "attributes": {"version": latest}}]}
        with patch.object(testflight, "APP", "beta-record"), patch.object(testflight, "get", side_effect=[self.app, response]) as get:
            testflight.check_version(current, mode, self.bundle)
            self.assertEqual(get.call_args_list[0].args, ("/apps/beta-record",))
            self.assertEqual(get.call_args.kwargs["filter[app]"], "beta-record")
            self.assertEqual(get.call_args.kwargs["sort"], "-uploadedDate")
            self.assertEqual(get.call_args.kwargs["include"], "preReleaseVersion")

    def test_duplicate_refuses_upload_and_suggests_next_patch(self):
        with self.assertRaisesRegex(SystemExit, r"1\.2\.9.*1\.2\.10.*upload same-version"):
            self.check("1.2.9", "1.2.9")

    def test_dry_and_explicit_override_allow_duplicate(self):
        for mode in ("dry", "same-version"):
            with self.subTest(mode=mode), redirect_stderr(io.StringIO()) as output:
                self.check("1.2.9", "1.2.9", mode)
                self.assertIn("1.2.9", output.getvalue())

    def test_new_version_and_first_build_can_upload(self):
        self.check("1.3.0", "1.2.9")
        self.check("1.3.0", None)

    def test_wrong_app_record_refuses_even_with_override(self):
        with patch.object(testflight, "get", return_value=self.app) as get:
            with self.assertRaisesRegex(SystemExit, "archived bundle ID"):
                testflight.check_version("1.2.9", "same-version", "com.example.HeyDan")
            get.assert_called_once()

    def test_missing_marketing_version_refuses_upload_even_with_override(self):
        with patch.object(testflight, "get", side_effect=[self.app, {"data": [{}]}]):
            with self.assertRaisesRegex(SystemExit, "marketing version"):
                testflight.check_version("1.2.9", "same-version", self.bundle)


if __name__ == "__main__":
    unittest.main()
