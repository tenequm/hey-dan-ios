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
                folder = stage / mode
                folder.mkdir()
                subprocess.run([*appearance, mode], check=True)
                subprocess.run(["xcrun", "simctl", "spawn", device, "launchctl", "kickstart", "-k",
                                f"user/{os.getuid()}/com.apple.dasd"], check=True)
                subprocess.run(["timeout", "--foreground", "--kill-after=10", "1200", "xcodebuild",
                                "test-without-building", *build, "-parallel-testing-enabled", "NO",
                                "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "300",
                                "-resultBundlePath", f"{temp}/{mode}.xcresult",
                                *["-only-testing:HeyDanChecks/" + test for test in selectors]],
                               check=True, env=env | {"TEST_RUNNER_HEYDAN_CHECKS_OUT": str(folder),
                                                      "TEST_RUNNER_HEYDAN_SCREENS": "1",
                                                      "TEST_RUNNER_HEYDAN_PREVIEW_LINES": "Taylor"})
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
        if destination.exists():
            destination.rename(Path(temp) / "previous")
        stage.rename(destination)
    print(f"{len(images)} screens in each appearance: {destination}/index.md")


if __name__ == "__main__":
    main(*sys.argv[1:])
