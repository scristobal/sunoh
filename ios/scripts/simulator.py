import json
import os
from pathlib import Path
import subprocess
import sys


def open_viewer():
    # Claude desktop shows the simulator in its own panel, so a second viewer window is unwanted there.
    if os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "claude-desktop":
        print("Skipping the device viewer. Use the integrated simulator in Claude desktop.")
        return
    simctl = Path(subprocess.check_output(["xcrun", "--find", "simctl"], text=True).strip())
    developer = simctl.parents[2]
    viewers = [
        developer.parent / "Applications/DeviceHub.app",
        developer / "Applications/Simulator.app",
    ]
    for viewer in viewers:
        if viewer.is_dir():
            subprocess.run(["open", str(viewer)], check=True)
            return
    sys.exit("The selected Xcode has no device viewer. Open Xcode and complete its installation.")


if sys.argv[1:] == ["--open"]:
    open_viewer()
elif sys.argv[1:]:
    sys.exit("Usage: simulator.py [--open]")
else:
    devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime
               if d.get("state") == "Booted" and "iPhone" in d.get("deviceTypeIdentifier", "")]
    print(devices[0]["udid"] if devices else "")
