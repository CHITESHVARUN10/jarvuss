#!/usr/bin/env python3
"""Controlled runtime benchmark for the bundled Jarvis app.

Measures bundle/model sizes, app RSS in idle and intent-loaded states, and
intent/plan latency through the authenticated local test runner. It never runs
Execute mode, so no app/file/media actions are performed compared with normal
user commands. Voice and Whisper measurements are opt-in flags and use only
synthetic TTS audio or the existing synthetic voice fixtures.

Examples:
  scripts/benchmark_runtime.py --label baseline --output logs/bench-baseline.json
  scripts/benchmark_runtime.py --label post --output logs/bench-post.json --whisper --ollama
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / ".build/Jarvis.app"
INTENT_COMMANDS = [
    "open chrome",
    "set volume to 40",
    "play blinding lights",
    "shuffle my liked songs",
    "open chatgpt in brave",
    "find my pdf files from last week",
    "open my portfolio project in vs code",
    "what is the battery level",
    "open spotify and play blinding lights",
    "how many files are in downloads",
    "search youtube for lofi beats",
    "close chrome and open finder",
]


def inventory(path: Path) -> dict:
    total = 0
    files = 0
    for item in path.rglob("*"):
        if item.is_file() and not item.is_symlink():
            total += item.stat().st_size
            files += 1
    return {"bytes": total, "mib": round(total / (1024 * 1024), 1), "files": files}


def median(values):
    return statistics.median(values) if values else None


def rss_bytes(pid: int) -> int | None:
    try:
        value = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip()
        return int(value) * 1024 if value else None
    except (subprocess.CalledProcessError, ValueError):
        return None


def footprint_bytes(pid: int) -> int | None:
    try:
        output = subprocess.check_output(["footprint", "-p", str(pid)],
                                         text=True, stderr=subprocess.STDOUT, timeout=20)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    match = re.search(r"Footprint:\s+([\d.]+)\s*(KB|MB|GB)", output)
    if not match:
        return None
    value = float(match.group(1))
    return int(value * {"KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}[match.group(2)])


def sample_rss(pid: int, count: int = 7, interval: float = 0.25) -> dict:
    samples = []
    for _ in range(count):
        value = rss_bytes(pid)
        if value:
            samples.append(value)
        time.sleep(interval)
    footprints = [value for value in (footprint_bytes(pid), footprint_bytes(pid)) if value]
    return {
        "samples_bytes": samples,
        "median_bytes": int(median(samples)) if samples else None,
        "max_bytes": max(samples) if samples else None,
        "footprint_bytes": int(median(footprints)) if footprints else None,
    }


def children_rss(pid: int) -> list[dict]:
    try:
        output = subprocess.check_output(["pgrep", "-P", str(pid)], text=True).split()
    except subprocess.CalledProcessError:
        return []
    result = []
    for child in output:
        value = rss_bytes(int(child))
        if value:
            command = subprocess.check_output(
                ["ps", "-o", "command=", "-p", child], text=True
            ).strip()
            result.append({"pid": int(child), "rss_bytes": value, "command": command[:220]})
    return result


class Runner:
    def __init__(self, session: Path):
        value = json.loads(session.read_text())
        self.port = int(value["port"])
        self.token = str(value["token"])

    def request(self, path: str, body=None, timeout: float = 120):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        headers = {"X-Jarvis-Test-Token": self.token, "Host": f"127.0.0.1:{self.port}"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        connection.request("POST" if body is not None else "GET", path, body=data, headers=headers)
        response = connection.getresponse()
        payload = response.read()
        connection.close()
        if response.status >= 300:
            raise RuntimeError(f"{path}: HTTP {response.status}: {payload[:300]!r}")
        return json.loads(payload)

    def run(self, command: str, mode: str, timeout: float = 120) -> dict:
        accepted = self.request("/api/run", {"command": command, "mode": mode})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            runs = self.request("/api/runs")
            run = next((item for item in runs if item["id"] == accepted["id"]), None)
            if run and run.get("state") == "finished":
                return run
            time.sleep(0.05)
        raise RuntimeError("runner request timed out")


class LaunchedApp:
    """Minimal Popen-compatible wrapper for an app started by LaunchServices."""

    def __init__(self, pid: int):
        self.pid = pid

    def poll(self):
        try:
            os.kill(self.pid, 0)
            return None
        except ProcessLookupError:
            return 0

    def terminate(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    def wait(self, timeout=None):
        deadline = time.monotonic() + (timeout if timeout is not None else 10)
        while self.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)


class _NullHandle:
    def close(self):
        pass


def launch_app(app: Path, data_dir: Path, log: Path, mode: str = "direct", intent_cache: str = "off"):
    session = data_dir / "testing/session.json"
    session.unlink(missing_ok=True)
    if mode == "open":
        subprocess.run(["open", "-n", "--env", f"JARVIS_DATA_DIR={data_dir}",
                        "--env", "JARVIS_RUST_PIPELINE=1", "--env",
                        f"JARVIS_INTENT_CACHE={'1' if intent_cache == 'on' else '0'}",
                        str(app), "--args", "--test-mode"], check=True)
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if session.exists():
                try:
                    value = json.loads(session.read_text())
                    pid = int(value["pid"])
                    return LaunchedApp(pid), session, _NullHandle()
                except (ValueError, KeyError, TypeError):
                    pass
            time.sleep(0.1)
        raise RuntimeError("app did not expose its test session")

    executable = app / "Contents/MacOS/Jarvis"
    env = dict(os.environ, JARVIS_DATA_DIR=str(data_dir), JARVIS_RUST_PIPELINE="1",
               JARVIS_INTENT_CACHE="1" if intent_cache == "on" else "0")
    handle = log.open("w")
    process = subprocess.Popen([str(executable), "--test-mode"], env=env,
                               stdout=handle, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if session.exists():
            try:
                if json.loads(session.read_text()).get("pid") == process.pid:
                    return process, session, handle
            except (ValueError, KeyError):
                pass
        if process.poll() is not None:
            handle.close()
            raise RuntimeError(f"app exited during startup; see {log}")
        time.sleep(0.1)
    process.terminate()
    handle.close()
    raise RuntimeError("app did not expose its test session")


def stop_app(process: subprocess.Popen, handle):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    handle.close()


def measure_runner(runner: Runner, pid: int, iterations: int) -> dict:
    # Warm every path before timing; also loads the native intent model.
    runner.run(INTENT_COMMANDS[0], "intent")
    runner.run(INTENT_COMMANDS[0], "plan")
    time.sleep(0.5)

    intent = []
    for repeat in range(iterations):
        for command in INTENT_COMMANDS:
            run = runner.run(command, "intent")
            events = run.get("events", [])
            model_ms = None
            for event in events:
                match = re.search(r"model latency (\d+) ms", event.get("message", ""))
                if match:
                    model_ms = int(match.group(1))
            intent.append({
                "command": command,
                "round": repeat,
                "elapsed_ms": run.get("elapsedMs"),
                "model_ms": model_ms,
                "outcome": run.get("outcome"),
                "plan": run.get("plan"),
            })
    intent_rss = sample_rss(pid)

    plan = []
    for repeat in range(iterations):
        for command in INTENT_COMMANDS:
            run = runner.run(command, "plan")
            plan.append({
                "command": command,
                "round": repeat,
                "elapsed_ms": run.get("elapsedMs"),
                "outcome": run.get("outcome"),
                "steps": len(run.get("plan") or []),
                "plan": run.get("plan"),
            })

    return {
        "intent": intent,
        "plan": plan,
        "summary": {
            "intent_warm_median_ms": median([r["elapsed_ms"] for r in intent[1:]]),
            "intent_model_median_ms": median([r["model_ms"] for r in intent if r["model_ms"] is not None]),
            "plan_warm_median_ms": median([r["elapsed_ms"] for r in plan[1:]]),
            "intent_runs": len(intent),
            "plan_runs": len(plan),
        },
        "rss_after_intent": intent_rss,
    }


def measure_whisper() -> dict:
    model = Path.home() / "Library/Application Support/AgentTalk/models/ggml-large-v3-turbo.bin"
    if not model.exists():
        return {"available": False, "reason": "Whisper model missing"}
    audio = Path(tempfile.mkdtemp(prefix="jarvis-bench-whisper-"))
    aiff, wav = audio / "probe.aiff", audio / "probe.wav"
    subprocess.run(["say", "-v", "Samantha", "-o", str(aiff),
                    "Jarvis open Chrome and set the volume to forty percent."], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                    str(aiff), str(wav)], check=True)
    with wave.open(str(wav), "rb") as audio_file:
        audio_seconds = audio_file.getnframes() / audio_file.getframerate()
    executable = ROOT / "stt-core/target/release/examples/transcribe_file"
    subprocess.run(["cargo", "build", "--release", "--example", "transcribe_file",
                    "--manifest-path", str(ROOT / "stt-core/Cargo.toml")], check=True)
    start = time.perf_counter()
    measured = subprocess.run(["/usr/bin/time", "-l", str(executable), str(wav)],
                              text=True, capture_output=True, timeout=600)
    wall = (time.perf_counter() - start) * 1000
    maximum = re.search(r"(\d+)\s+maximum resident set size", measured.stderr)
    peak = re.search(r"(\d+)\s+peak memory footprint", measured.stderr)
    values = {}
    for line in measured.stdout.splitlines():
        if ":" in line and line.split(":", 1)[0] in ("LOAD_MS", "TRANSCRIBE_MS", "TRANSCRIPT"):
            key, value = line.split(":", 1)
            values[key] = value.strip()
    result = {
        "available": measured.returncode == 0,
        "model_bytes": model.stat().st_size,
        "wall_ms": round(wall, 1),
        "load_ms": int(values["LOAD_MS"]) if "LOAD_MS" in values else None,
        "transcribe_ms": int(values["TRANSCRIBE_MS"]) if "TRANSCRIBE_MS" in values else None,
        "audio_seconds": round(audio_seconds, 3),
        "max_rss_bytes": int(maximum.group(1)) if maximum else None,
        "peak_footprint_bytes": int(peak.group(1)) if peak else None,
        "transcript": values.get("TRANSCRIPT", "").strip("'"),
        "stdout": measured.stdout[-500:],
        "stderr": measured.stderr[-300:],
    }
    shutil.rmtree(audio, ignore_errors=True)
    return result


def ollama_loaded_models() -> list[str]:
    try:
        lines = subprocess.check_output(["ollama", "ps"], text=True).splitlines()
    except subprocess.CalledProcessError:
        return []
    names = []
    for line in lines[1:]:
        fields = line.split()
        if fields:
            names.append(fields[0])
    return names


def ollama_processes() -> list[dict]:
    result = []
    try:
        lines = subprocess.check_output(["ps", "-axo", "pid=,rss=,command="], text=True).splitlines()
    except subprocess.CalledProcessError:
        return result
    for line in lines:
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        pid, rss, command = int(parts[0]), int(parts[1]) * 1024, parts[2]
        if "llama-server" in command or "ollama serve" in command:
            result.append({"pid": pid, "rss_bytes": rss, "command": command[:260]})
    return result


def ollama_generate(model: str, warmup: int, rounds: int) -> dict:
    for loaded in ollama_loaded_models():
        subprocess.run(["ollama", "stop", loaded], capture_output=True)
    time.sleep(0.5)

    def call():
        payload = json.dumps({
            "model": model,
            "prompt": "Reply with exactly: ok",
            "stream": False,
            "keep_alive": "2m",
            "options": {"num_predict": 8},
        }).encode()
        request = urllib.request.Request(
            "http://127.0.0.1:11434/api/generate", data=payload,
            headers={"Content-Type": "application/json"})
        start = time.perf_counter()
        with urllib.request.urlopen(request, timeout=180) as response:
            body = json.load(response)
        return (time.perf_counter() - start) * 1000, body

    subprocess.run(["ollama", "stop", model], capture_output=True)
    cold_ms, cold_body = call()
    for _ in range(warmup):
        call()
    warm = []
    for _ in range(rounds):
        elapsed, _ = call()
        warm.append(elapsed)
    time.sleep(0.5)
    runners = ollama_processes()
    model_bytes = None
    try:
        for line in subprocess.check_output(["ollama", "list"], text=True).splitlines()[1:]:
            fields = line.split()
            if fields and fields[0] == model:
                match = re.search(r"([\d.]+)\s*(KB|MB|GB|TB)", line)
                if match:
                    model_bytes = int(float(match.group(1)) *
                                      {"KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3,
                                       "TB": 1024 ** 4}[match.group(2)])
    except subprocess.CalledProcessError:
        pass
    return {
        "model": model,
        "model_bytes": model_bytes,
        "cold_ms": round(cold_ms, 1),
        "warm_median_ms": round(median(warm), 1) if warm else None,
        "warm_samples_ms": [round(value, 1) for value in warm],
        "cold_response": cold_body.get("response"),
        "processes": runners,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=APP)
    parser.add_argument("--label", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--launch-mode", choices=["direct", "open"], default="direct")
    parser.add_argument("--intent-cache", choices=["off", "on"], default="off")
    parser.add_argument("--whisper", action="store_true")
    parser.add_argument("--ollama", action="store_true")
    parser.add_argument("--ollama-models", default="qwen2.5:1.5b-instruct")
    parser.add_argument("--keep-data", action="store_true")
    args = parser.parse_args()

    data_dir = Path(tempfile.mkdtemp(prefix=f"jarvis-bench-{args.label}-"))
    log = data_dir / "app.log"
    process = None
    handle = None
    report = {
        "intent_cache": args.intent_cache,
        "label": args.label,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "app": str(args.app),
        "host": {
            "model": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
            "ncpu": int(subprocess.check_output(["sysctl", "-n", "hw.ncpu"], text=True)),
            "memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
            "os": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
        },
        "source_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "bundle": {
            "total": inventory(args.app),
            "macos": inventory(args.app / "Contents/MacOS"),
            "resources": inventory(args.app / "Contents/Resources"),
            "intent_model": inventory(args.app / "Contents/Resources/backend/models/intent-t5-small"),
            "native_voice": inventory(args.app / "Contents/Resources/native/voice"),
        },
        "model_files": {
            "whisper": (Path.home() / "Library/Application Support/AgentTalk/models/ggml-large-v3-turbo.bin").stat().st_size,
            "intent_encoder": (args.app / "Contents/Resources/backend/models/intent-t5-small/encoder_model_quantized.onnx").stat().st_size,
            "intent_decoder": (args.app / "Contents/Resources/backend/models/intent-t5-small/decoder_model_merged_quantized.onnx").stat().st_size,
            "voice_encoder": (args.app / "Contents/Resources/native/voice/speaker_encoder.onnx").stat().st_size,
        },
    }
    try:
        process, session, handle = launch_app(args.app, data_dir, log, args.launch_mode, args.intent_cache)
        time.sleep(4)
        report["rss_idle"] = {"app": sample_rss(process.pid), "children": children_rss(process.pid)}
        runner = Runner(session)
        report["runner"] = measure_runner(runner, process.pid, args.iterations)
        report["rss_loaded"] = {"app": sample_rss(process.pid), "children": children_rss(process.pid)}
        report["test_state"] = runner.request("/api/state")
    finally:
        if process is not None:
            stop_app(process, handle)
        if not args.keep_data:
            shutil.rmtree(data_dir, ignore_errors=True)

    if args.whisper:
        report["whisper"] = measure_whisper()
    if args.ollama:
        report["ollama"] = []
        for model in [value.strip() for value in args.ollama_models.split(",") if value.strip()]:
            report["ollama"].append(ollama_generate(model, warmup=2, rounds=5))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    summary = {
        "label": report["label"],
        "bundle_mib": report["bundle"]["total"]["mib"],
        "idle_app_mib": round((report["rss_idle"]["app"]["median_bytes"] or 0) / 1048576, 1),
        "idle_app_footprint_mib": round((report["rss_idle"]["app"].get("footprint_bytes") or 0) / 1048576, 1),
        "loaded_app_mib": round((report["rss_loaded"]["app"]["median_bytes"] or 0) / 1048576, 1),
        "loaded_app_footprint_mib": round((report["rss_loaded"]["app"].get("footprint_bytes") or 0) / 1048576, 1),
        "intent_median_ms": report["runner"]["summary"]["intent_warm_median_ms"],
        "model_median_ms": report["runner"]["summary"]["intent_model_median_ms"],
        "plan_median_ms": report["runner"]["summary"]["plan_warm_median_ms"],
    }
    print(json.dumps(summary, indent=2))
    print(f"report: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
