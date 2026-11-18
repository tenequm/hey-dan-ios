"""Capture the Dark fixture gallery with the shared Simulator test products."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

import sim_tests

STATUS_BAR = ["--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
              "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
              "--batteryState", "charged", "--batteryLevel", "100"]


def gallery(args, stage, revision):
    folder = stage / "dark"
    folder.mkdir(parents=True)
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    udid = next((d["udid"] for runtime in devices["devices"].values() for d in runtime if d["name"] == args.simulator), None)
    if not udid:
        raise RuntimeError(f"No Simulator named {args.simulator}")
    # simctl overrides the status bar only on a booted Simulator, so this boots it before sim_tests builds.
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["xcrun", "simctl", "status_bar", udid, "override", *STATUS_BAR], check=True)
    try:
        sim_tests.main("screens", args.simulator, args.build, args.bundle, "ScreenCaptureChecks", folder)
    finally:
        subprocess.run(["xcrun", "simctl", "status_bar", udid, "clear"], check=True)
    images = sorted(p for p in folder.glob("*.png") if p.stat().st_size)
    if not images:
        raise RuntimeError("No screen captures")
    pairs = {}
    if args.design:
        designs = sorted(args.design.glob("*.png"))
        if not designs:
            raise RuntimeError(f"No design PNGs in {args.design}")
        pairs_dir = stage / "side-by-side"
        pairs_dir.mkdir()
        for design in designs:
            capture = folder / design.name
            if capture not in images:
                raise RuntimeError(f"Missing capture for {design.name}")
            pair = pairs_dir / design.name
            with design.open("rb") as png:
                png.seek(16)
                width = int.from_bytes(png.read(4), "big")
            subprocess.run(["magick", design, "(", capture, "-resize", f"{width}x", ")",
                            "-background", "#151515", "-gravity", "north", "+append", pair], check=True)
            pairs[capture] = pair
    rows = [f"# Hey Dan screens at {revision}", "", "Dark appearance. Comparisons show the design on the left and the Simulator on the right.", ""]
    for capture in images:
        row = f"- [{capture.stem}](dark/{capture.name})"
        if pair := pairs.get(capture):
            row += f" - [comparison](side-by-side/{pair.name})"
        rows.append(row)
    (stage / "index.md").write_text("\n".join(rows) + "\n")
    return len(images), len(pairs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("simulator", "build", "bundle"):
        parser.add_argument(name)
    parser.add_argument("theme", nargs="?", choices=["dark"], default="dark")
    parser.add_argument("--design", type=Path)
    args = parser.parse_args()
    revision = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
    root = Path(".local/screens").resolve()
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".capture.lock").open("a") as lock, TemporaryDirectory(dir=root) as work:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stage = Path(work) / revision
        count, pairs = gallery(args, stage, revision)
        destination = root / revision
        previous = Path(work) / "previous"
        if destination.exists():
            destination.rename(previous)
        try:
            stage.rename(destination)
        except OSError:
            if previous.exists():
                previous.rename(destination)
            raise
        print(f"{count} captures, {pairs} comparisons: {destination}/index.md")


if __name__ == "__main__":
    main()
