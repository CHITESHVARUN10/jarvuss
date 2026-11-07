#!/usr/bin/env python3
"""Matched isolated Python/native voice HTTP benchmark with synthetic profiles.
No user data, microphone, live Spotify or database requests. Python remains a
development reference, not a bundled runtime dependency.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import random
import re
import secrets
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


class Helper:
    def __init__(self, kind, directory, python, native_binary, reference):
        self.directory = directory
        backend = directory / "backend"
        data = directory / "data"
        backend.mkdir(parents=True)
        data.mkdir()
        import numpy as np
        profiles = [r["reference"] for r in reference["records"] if r["fixture"].endswith("-normal.wav")]
        np.save(data / "embeddings.npy", np.asarray(profiles, dtype=np.float32), allow_pickle=False)
        native = directory / "native"
        native.symlink_to(ROOT / ".build/native-runtime", target_is_directory=True)
        env = {"PATH": os.environ["PATH"], "HOME": str(Path.home()),
               "JARVIS_DATA_DIR": str(data), "JARVIS_BACKEND_PORT": "0",
               "JARVIS_CREDENTIAL_OWNER_PID": str(os.getpid()), "PYTHONDONTWRITEBYTECODE": "1"}
        self.token = secrets.token_urlsafe(32)
        if kind == "python":
            for path in (ROOT / "backend").glob("*.py"):
                shutil.copy2(path, backend / path.name)
            env.update(JARVIS_VOICE_ONLY="1", JARVIS_HELPER_AUTH_TOKEN=self.token)
            command = [str(python), "-m", "uvicorn", "voice_auth_service:app", "--app-dir", str(backend),
                       "--host", "127.0.0.1", "--port", "0", "--no-access-log"]
        else:
            command = [str(native_binary), "--backend-dir", str(backend)]
        self.log = (directory / "helper.log").open("w+")
        start = time.perf_counter()
        self.process = subprocess.Popen(command, env=env, stdout=self.log, stderr=self.log)
        try:
            while time.perf_counter() - start < 20:
                text = (directory / "helper.log").read_text()
                match = re.search(r"ready port=(\d+)", text) if kind == "native" else re.search(r"127\.0\.0\.1:(\d+)", text)
                if match:
                    self.port = int(match[1])
                    if kind == "native":
                        self.token = (data / "backend_auth.token").read_text()
                    self.ready_ms = (time.perf_counter() - start) * 1000
                    break
                if self.process.poll() is not None:
                    raise RuntimeError(f"{kind} benchmark helper exited")
                time.sleep(0.005)
            else:
                raise RuntimeError("Benchmark helper startup timed out")
        except BaseException:
            self.stop()
            raise

    def verify(self, path):
        boundary = "JarvisSyntheticBenchmarkAudio"
        body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="sample.wav"\r\n'
                'Content-Type: audio/wav\r\n\r\n').encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        start = time.perf_counter()
        connection.request("POST", "/verify", body,
                           {"X-Jarvis-Token": self.token, "Content-Type": "multipart/form-data; boundary=" + boundary})
        response = connection.getresponse()
        data = response.read()
        elapsed = (time.perf_counter() - start) * 1000
        connection.close()
        if response.status != 200:
            raise RuntimeError("Synthetic verification failed: " + data.decode())
        return json.loads(data), elapsed

    def rss(self):
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(self.process.pid)]).strip()) * 1024

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", type=Path, default=ROOT / ".build/native-tools/venv/bin/python")
    parser.add_argument("--native-binary", type=Path, default=ROOT / ".build/Jarvis.app/Contents/MacOS/JarvisBackend")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    reference = json.loads((ROOT / ".build/native-voice/parity-formats.json").read_text())
    fixtures = [ROOT / ".build/native-voice/variants" / row["fixture"] for row in reference["records"]]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jarvis-native-benchmark-") as directory:
        helpers = {}
        records = []
        try:
            for kind in ("python", "native"):
                helpers[kind] = Helper(kind, Path(directory) / kind, args.python, args.native_binary, reference)
            cold = {kind: helper.verify(fixtures[0])[1] for kind, helper in helpers.items()}
            for helper in helpers.values():
                for fixture in fixtures:
                    helper.verify(fixture)
            rss = {kind: [] for kind in helpers}
            for repeat in range(7):
                rng = random.Random(20261107 + repeat)
                cases = fixtures.copy()
                rng.shuffle(cases)
                for i, fixture in enumerate(cases):
                    order = ("python", "native") if (repeat+i) % 2 == 0 else ("native", "python")
                    results, timings = {}, {}
                    for kind in order:
                        results[kind], timings[kind] = helpers[kind].verify(fixture)
                    fields = ("confidence", "samples_compared")
                    changed = [field for field in fields if results["python"][field] != results["native"][field]]
                    for threshold in (0.65, 0.70, 0.75, 0.80, 0.85, 0.90):
                        if (results["python"]["similarity"] >= threshold) != (results["native"]["similarity"] >= threshold):
                            changed.append(f"threshold_{threshold}")
                    records.append(dict(fixture=fixture.name, round=repeat, results=results, timings=timings, changed=changed))
                for kind, helper in helpers.items():
                    rss[kind].append(helper.rss())
            summary = {kind: dict(ready_ms=helpers[kind].ready_ms, first_voice_request_ms=cold[kind],
                                  warm_median_ms=statistics.median(r["timings"][kind] for r in records),
                                  rss_median_bytes=statistics.median(rss[kind]), rss_samples_bytes=rss[kind])
                       for kind in helpers}
        finally:
            for helper in helpers.values():
                helper.stop()
    def inventory(path):
        return sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())
    report = dict(measured_requests_per_runtime=len(records), changed_decisions=sum(bool(r["changed"]) for r in records),
                  exact_responses=sum(r["results"]["python"] == r["results"]["native"] for r in records),
                  summary=summary, installed_app_bytes=inventory(Path("/Applications/Jarvis.app")),
                  candidate_app_bytes=inventory(ROOT / ".build/Jarvis.app"),
                  native_binary_sha256=hashlib.sha256(args.native_binary.read_bytes()).hexdigest(),
                  method="Two isolated helpers; same synthetic profiles/audio, CPU, seven shuffled alternating rounds; no voice capture or actions.",
                  limits="One process launch per runtime; cold timings are observations, not repeatable startup guarantees. RSS is helper-only and includes shared pages; not total app RAM. No human biometric accuracy claim.",
                  records=records)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k:v for k,v in report.items() if k != "records"}, indent=2))
    return bool(report["changed_decisions"])


if __name__ == "__main__":
    raise SystemExit(main())
