"""Resolve the explicitly selected, already available pipeline data directory."""

import os
from pathlib import Path


def data_root(value=None):
    value = value or os.environ.get("DATA_ROOT")
    if not value:
        raise SystemExit("Set DATA_ROOT, pass --data-root, or run through Just")
    root = Path(value).expanduser().resolve()
    if not root.is_dir():
        raise SystemExit(f"DATA_ROOT is unavailable: {root}. Mount the disk or create the intended root first.")
    return root


if __name__ == "__main__":
    print(data_root())
