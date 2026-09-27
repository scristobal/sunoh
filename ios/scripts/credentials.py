"""Save the public Mapbox runtime token in the ignored app build configuration."""

import getpass
import os
from pathlib import Path
import re
import sys
import tempfile
import warnings


def configuration(public_token):
    # Reject secret tokens and build-setting interpolation before writing anything.
    if not isinstance(public_token, str) or not re.fullmatch(r"pk\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", public_token):
        raise ValueError("A public Mapbox token beginning with pk. is required.")

    return (
        "// Public Mapbox runtime token. Keep this file out of Git.\n"
        f"SUNOH_MAPBOX_ACCESS_TOKEN = {public_token}\n"
    )


def save_credentials(public_token, destination):
    content = configuration(public_token)
    try:
        existing = destination.read_text(encoding="utf-8")
    except FileNotFoundError:
        existing = ""
    # Keep the style override without copying obsolete service credentials.
    for line in existing.splitlines():
        if re.match(r"^[ \t]*SUNOH_MAP_STYLE_URL[ \t]*=", line):
            content += line + "\n"

    # Replace the configuration only after the complete private file is written.
    descriptor, staged = tempfile.mkstemp(dir=destination.parent, prefix=".maps-")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary:
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(staged, destination)
    finally:
        Path(staged).unlink(missing_ok=True)


def main():
    destination = Path(__file__).resolve().parent.parent / "Configuration/Maps.local.xcconfig"

    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            public_token = getpass.getpass("Mapbox public access token, pk. (hidden): ")
        save_credentials(public_token, destination)
    except (EOFError, KeyboardInterrupt, getpass.GetPassWarning):
        print("Token setup cancelled. Run this command in an interactive terminal.", file=sys.stderr)
        return 1
    except (OSError, ValueError):
        # Never print token values or raw errors.
        print("Could not save the token. Use a public pk. token and check destination permissions.",
              file=sys.stderr)
        return 1

    print(f"Saved the public Mapbox token: {destination}")
    print("Rebuild and reinstall Sunō to use it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
