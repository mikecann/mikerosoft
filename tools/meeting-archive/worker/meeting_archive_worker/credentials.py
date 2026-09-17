"""Load the unattended worker's approved credentials without logging values."""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import sys
import syslog
from collections.abc import MutableMapping

DEFAULT_PATH = Path("/Volumes/CannMedia/MeetingArchive/runtime/secrets/credentials.json")
ACCOUNTS = {"huggingFaceToken": "HF_TOKEN", "notionToken": "MEETING_ARCHIVE_NOTION_TOKEN"}


class CredentialError(RuntimeError):
    pass


def load_credentials(path: Path = DEFAULT_PATH, environment: MutableMapping[str, str] | None = None) -> None:
    environment = os.environ if environment is None else environment
    descriptor = None
    try:
        parent = path.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or parent.st_mode & 0o077:
            raise CredentialError("Credential directory must be a real owner-only directory.")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise CredentialError("Credential file must be a regular owner-only file.")
        if info.st_size > 16384:
            raise CredentialError("Credential file exceeds the expected size limit.")
        raw = os.read(descriptor, 16385)
        if len(raw) > 16384:
            raise CredentialError("Credential file exceeds the expected size limit.")
        values = json.loads(raw)
        if not isinstance(values, dict) or set(values) != set(ACCOUNTS) or not all(isinstance(value, str) and value.strip() for value in values.values()):
            raise CredentialError("Credential file must contain the two approved nonempty accounts.")
    except CredentialError:
        raise
    except (OSError, ValueError, UnicodeError):
        # Never include JSON parser excerpts, file contents, or subprocess
        # output in a diagnostic. They can contain credential values.
        raise CredentialError("Credential file is unavailable, unsafe, or invalid JSON.") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)
    for account, variable in ACCOUNTS.items():
        if not environment.get(variable):
            environment[variable] = values[account]


def main() -> int:
    checking = sys.argv[1:] == ["--check"]
    try:
        load_credentials()
    except CredentialError as error:
        syslog.syslog(syslog.LOG_ERR, f"Meeting Archive: {error}")
        if checking:
            print(str(error), file=sys.stderr)
            return 1
        # Keep the durable service alive. Missing credentials become visible
        # processing/publication retry errors instead of losing queued media.
    if checking:
        print("Approved worker credentials loaded with verified private permissions.")
        return 0
    from .service import main as service_main
    return service_main()


if __name__ == "__main__":
    raise SystemExit(main())
