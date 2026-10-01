#!/usr/bin/env python3
"""Launch a command fully detached from this terminal and session.

Closing VS Code, quitting the terminal, or losing the SSH session must NOT
kill a multi-hour training run. The child is started with
`start_new_session=True` (setsid), so it gets its own session and process
group with no controlling terminal — a process-group kill aimed at the shell
cannot reach it, and it is reparented to launchd the moment this script exits.

Usage:
    python detach.py <logfile> <command> [args...]

Example:
    python detach.py post_train.log .venv/bin/python post_train.py --train
"""
from __future__ import annotations

import os
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    logfile = os.path.abspath(sys.argv[1])
    command = sys.argv[2:]

    os.makedirs(os.path.dirname(logfile), exist_ok=True)
    log = open(logfile, "ab", buffering=0)

    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        cwd=os.getcwd(),
        start_new_session=True,
        close_fds=True,
    )

    print(f"detached  pid {process.pid}")
    print(f"log       {logfile}")
    print(f"command   {' '.join(command)}")
    print()
    print(f"  tail -f {logfile}")
    print(f"  kill {process.pid}          # stop it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
