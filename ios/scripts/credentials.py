"""Save map service credentials locally without contacting Cloudflare."""

import getpass
import os
from pathlib import Path
import re
import sys
import tempfile
import warnings


def configuration(client_id, client_secret):
    # Only these two fields enter the app; reject build-setting interpolation.
    values = [client_id, client_secret]
    if any(not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", value)
           for value in values):
        raise ValueError("The service credential pair is missing or has an unsupported format.")

    return (
        "// Cloudflare Access service credential. Keep this file out of Git.\n"
        f"SUNOH_MAP_ACCESS_CLIENT_ID = {values[0]}\n"
        f"SUNOH_MAP_ACCESS_CLIENT_SECRET = {values[1]}\n"
    )


def save_credentials(client_id, client_secret, destination):
    content = configuration(client_id, client_secret)

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
        client_id = input("CF-Access-Client-Id: ")
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            client_secret = getpass.getpass("CF-Access-Client-Secret (hidden): ")
        save_credentials(client_id, client_secret, destination)
    except (EOFError, KeyboardInterrupt, getpass.GetPassWarning):
        print("Credential setup cancelled. Run this command in an interactive terminal.", file=sys.stderr)
        return 1
    except (OSError, ValueError):
        # Never print credential values or raw errors.
        print("Could not save the service token. Check the credential pair and destination permissions.",
              file=sys.stderr)
        return 1

    print(f"Saved app build credentials: {destination}")
    print("Rebuild and reinstall Sunō to use them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
