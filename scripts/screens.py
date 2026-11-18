"""Build the capture bundle once and publish a matched Dark/Light gallery."""
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main(simulator, derived_data):
    devices = json.loads(output("xcrun", "simctl", "list", "devices", "available", "-j"))
    matches = [d for runtime in devices["devices"].values() for d in runtime if d["name"] == simulator]
    if len(matches) != 1:
        sys.exit(f"Expected one available Simulator named {simulator}, found {len(matches)}")
    device = matches[0]["udid"]
    subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
    appearance = ["xcrun", "simctl", "ui", device, "appearance"]
    original = output(*appearance).split()[-1].lower()
    if original not in ("light", "dark"):
        sys.exit("Could not read Simulator appearance")

    revision = output("git", "rev-parse", "--short", "HEAD")
    root = Path(".local/screens").resolve()
    root.mkdir(parents=True, exist_ok=True)
    destination = root / revision
    # A separate bundle keeps the capture app away from saved pairings and voice lines.
    build = ["-project", "HeyDan.xcodeproj", "-scheme", "HeyDanChecks", "-destination", f"id={device}",
             "-derivedDataPath", derived_data, "-disableAutomaticPackageResolution", "-skipPackageUpdates",
             "HEYDAN_BUNDLE_ID=com.example.HeyDan.screens", "-quiet"]
    selectors = ["ScreenCaptureChecks"] + ["HeyDanChecks/test" + test for test in (
        "CallOptions", "VoicePickerSaved", "VoicePickerLive", "VoicePickerFailures", "VoicePickerFailuresCatalog",
        "VoicePickerNames", "VoicePickerLostSave", "VoicePickerGender")]
    env = {k: v for k, v in os.environ.items() if not k.startswith(("TEST_RUNNER_HEYDAN_", "SIMCTL_CHILD_HEYDAN_"))}

    with TemporaryDirectory(prefix=".capture-", dir=root) as temp:
        stage = Path(temp) / revision
        stage.mkdir()
        subprocess.run(["xcodebuild", "build-for-testing", *build], check=True, env=env)
        try:
            for mode in ("dark", "light"):
                print(f"Capturing {mode} appearance on {simulator}", flush=True)
                folder = stage / mode
                folder.mkdir()
                subprocess.run([*appearance, mode], check=True)
                subprocess.run(["xcrun", "simctl", "spawn", device, "launchctl", "kickstart", "-k",
                                f"user/{os.getuid()}/com.apple.dasd"], check=True)
                bundle = Path(temp) / f"{mode}.xcresult"
                runner = env | {
                    "TEST_RUNNER_HEYDAN_CHECKS_OUT": str(folder),
                    "TEST_RUNNER_HEYDAN_SCREENS": "1",
                    "TEST_RUNNER_HEYDAN_PREVIEW_LINES": "Taylor",
                }
                result = subprocess.run([
                    "timeout", "--foreground", "--kill-after=10", "1800", "xcodebuild", "test-without-building",
                    *build, "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
                    "-default-test-execution-time-allowance", "600", "-resultBundlePath", str(bundle),
                    *["-only-testing:HeyDanChecks/" + test for test in selectors],
                ], env=runner)
                if not (bundle / "Info.plist").exists():
                    result.check_returncode()
                    sys.exit(f"Missing test results for {mode}")
                summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary",
                                            "--path", str(bundle)))
                for failure in summary["testFailures"]:
                    print(f"{failure['testIdentifierString']}: {failure['failureText']}", file=sys.stderr)
                print(f"{mode}: {summary['passedTests']} passed, {summary['failedTests']} failed, "
                      f"{summary['skippedTests']} skipped", flush=True)
                result.check_returncode()
                if summary["skippedTests"] or not summary["passedTests"]:
                    sys.exit("Incomplete screen checks")
        finally:
            subprocess.run([*appearance, original], check=True)

        def names(mode):
            return sorted(p.name for p in (stage / mode).glob("*.png") if p.stat().st_size)

        images = names("dark")
        if not images or images != names("light"):
            sys.exit("Capture sets are empty or differ between appearances")
        rows = [f"| {Path(name).stem} | [Dark](dark/{name}) | [Light](light/{name}) |" for name in images]
        (stage / "index.md").write_text("\n".join([
            f"# Hey Dan screens at {revision}", "", "Captured in each Simulator appearance. Views can override the system appearance.",
            "", "| Screen | Dark | Light |", "| --- | --- | --- |", *rows, "",
        ]))
        previous = Path(temp) / "previous"
        if destination.exists():
            destination.rename(previous)
        try:
            stage.rename(destination)
        except OSError:
            if previous.exists() and not destination.exists():
                previous.rename(destination)
            raise
    print(f"{len(images)} screens in each appearance: {destination}/index.md")


if __name__ == "__main__":
    main(*sys.argv[1:])
