#!/usr/bin/env python3
"""Run stats integration tests against a disposable PostgreSQL Unix socket.

TCP is disabled. This never connects to the user's database.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> int:
    candidates = [Path("/opt/homebrew/opt/postgresql@18/bin"), Path("/usr/local/opt/postgresql@18/bin")]
    found = shutil.which("initdb")
    if found:
        candidates.insert(0, Path(found).parent)
    binaries = next((path for path in candidates if (path / "pg_ctl").is_file() and (path / "initdb").is_file()), None)
    if binaries is None:
        raise SystemExit("Install PostgreSQL 18 before running this integration test.")
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="jarvis-pg-") as directory:
        temporary = Path(directory)
        data, socket = temporary / "data", temporary / "socket"
        socket.mkdir()
        subprocess.run([str(binaries / "initdb"), "-D", str(data), "-A", "trust", "-U", "jarvis_test", "--no-locale"],
                       check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(binaries / "pg_ctl"), "-D", str(data), "-l", str(temporary / "postgres.log"),
                        "-o", f"-k {socket} -h '' -p 5432", "-w", "start"], check=True)
        try:
            environment = {**os.environ, "JARVIS_TEST_PGHOST": str(socket)}
            result = subprocess.run(["swift", "test", "--filter", "DatabaseIntegrationTests"], cwd=root, env=environment)
            return result.returncode
        finally:
            subprocess.run([str(binaries / "pg_ctl"), "-D", str(data), "-m", "immediate", "-w", "stop"], check=True)


if __name__ == "__main__":
    raise SystemExit(main())
