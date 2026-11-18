"""Capture a Dark fixture gallery from the current revision's test build."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from time import monotonic


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def capture_build(device, derived_data, revision, env):
    cache = derived_data / "screens"
    products = cache / "Build/Products"
    stamp = cache / "capture-build.json"
    local = Path("Local.xcconfig")
    key = [revision, device, output("xcrun", "--find", "xcodebuild"), output("xcodebuild", "-version"),
           hashlib.sha256(local.read_bytes()).hexdigest() if local.exists() else None]
    clean = not output("git", "status", "--porcelain")
    runners = list(products.glob("HeyDanChecks_*.xctestrun"))
    binaries = [products / "Debug-iphonesimulator/HeyDan.app/HeyDan",
                products / "Debug-iphonesimulator/HeyDanChecks-Runner.app/PlugIns/HeyDanChecks.xctest/HeyDanChecks"]
    if (clean and stamp.is_file() and stamp.read_text() == json.dumps(key)
            and len(runners) == 1 and all(path.is_file() for path in binaries)):
        return runners[0], True

    stamp.unlink(missing_ok=True)
    subprocess.run(["xcodegen", "generate"], check=True, env=env)
    for runner in runners:
        runner.unlink()
    subprocess.run(["xcodebuild", "build-for-testing", "-project", "HeyDan.xcodeproj", "-scheme", "HeyDanChecks",
                    "-destination", f"id={device}", "-derivedDataPath", cache,
                    "-clonedSourcePackagesDirPath", derived_data / "SourcePackages",
                    "-disableAutomaticPackageResolution", "-skipPackageUpdates",
                    "HEYDAN_BUNDLE_ID=com.example.HeyDan.screens", "-quiet"], check=True, env=env)
    runner, = products.glob("HeyDanChecks_*.xctestrun")
    if clean and not output("git", "status", "--porcelain") and output("git", "rev-parse", "HEAD") == revision:
        stamp.write_text(json.dumps(key))
    return runner, False


def main(simulator, derived_data, theme="dark"):
    if theme != "dark":
        sys.exit(f"Unsupported theme {theme!r}. Available theme: dark")
    root = Path(".local/screens").resolve()
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".capture.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        capture(simulator, Path(derived_data).resolve(), root, theme)


def capture(simulator, derived_data, root, theme):
    devices = json.loads(output("xcrun", "simctl", "list", "devices", "available", "-j"))
    matches = [d for runtime in devices["devices"].values() for d in runtime if d["name"] == simulator]
    if len(matches) != 1:
        sys.exit(f"Expected one available Simulator named {simulator}, found {len(matches)}")
    device = matches[0]["udid"]
    revision = output("git", "rev-parse", "HEAD")
    short = output("git", "rev-parse", "--short", revision)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("TEST_RUNNER_HEYDAN_", "SIMCTL_CHILD_HEYDAN_"))}
    start = monotonic()
    runner, reused = capture_build(device, derived_data, revision, env)
    build_seconds = monotonic() - start
    start = monotonic()
    subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
    appearance = ["xcrun", "simctl", "ui", device, "appearance"]
    original = output(*appearance).split()[-1].lower()
    if original not in ("light", "dark"):
        sys.exit("Could not read Simulator appearance")

    with TemporaryDirectory(prefix=".capture-", dir=root) as temp:
        stage = Path(temp) / short
        folder = stage / theme
        folder.mkdir(parents=True)
        bundle = Path(temp) / "screens.xcresult"
        try:
            subprocess.run([*appearance, theme], check=True)
            subprocess.run(["xcrun", "simctl", "spawn", device, "launchctl", "kickstart", "-k",
                            f"user/{os.getuid()}/com.apple.dasd"], check=True)
            result = subprocess.run([
                "timeout", "--foreground", "--kill-after=10", "1800", "xcodebuild", "test-without-building",
                "-xctestrun", runner, "-destination", f"id={device}", "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "600",
                "-resultBundlePath", bundle, "-quiet", "-only-testing:HeyDanChecks/ScreenCaptureChecks",
                "-only-testing:HeyDanChecks/HeyDanChecks/testCaptureVoiceScreens",
            ], env=env | {"TEST_RUNNER_HEYDAN_CHECKS_OUT": str(folder), "TEST_RUNNER_HEYDAN_SCREENS": "1"})
            if not (bundle / "Info.plist").is_file():
                result.check_returncode()
                sys.exit("Missing test results")
            summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle))
            for failure in summary["testFailures"]:
                print(f"{failure['testIdentifierString']}: {failure['failureText']}", file=sys.stderr)
            print(f"{theme}: {summary['passedTests']} passed, {summary['failedTests']} failed, "
                  f"{summary['skippedTests']} skipped", flush=True)
            result.check_returncode()
            if summary["skippedTests"] or not summary["passedTests"]:
                sys.exit("Incomplete screen checks")
        finally:
            subprocess.run([*appearance, original], check=True)
            print(f"Build: {build_seconds:.1f}s ({'reused' if reused else 'built'}); "
                  f"capture: {monotonic() - start:.1f}s", flush=True)

        images = sorted(p for p in folder.glob("*.png") if p.stat().st_size)
        if not images:
            sys.exit("No screens captured")
        rows = [f"- [{p.stem}]({theme}/{p.name})" for p in images]
        (stage / "index.md").write_text("\n".join([f"# Hey Dan screens at {short} ({theme})", "", *rows, ""]))
        previous = Path(temp) / "previous"
        destination = root / short
        if destination.exists():
            destination.rename(previous)
        try:
            stage.rename(destination)
        except OSError:
            if previous.exists() and not destination.exists():
                previous.rename(destination)
            raise
    print(f"{len(images)} screens: {destination}/index.md")


if __name__ == "__main__":
    main(*sys.argv[1:])
