#!/usr/bin/python3 -I
"""Probe which tools this identity can run, without a shell.

Usage: tool_probe.py CONTEXT CATALOG [OUTPUT]

CATALOG is the JSON file PtcManager writes: {"probes": [{"name", "argv"}]}.
Each probe runs as an argv list with stdin closed, a five-second timeout, and
its output capped. Raw results are recorded; PtcManager parses versions. With
OUTPUT the snapshot replaces that file atomically, otherwise it is printed.
"""
import datetime
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

MAX_PROBES = 24
TIMEOUT_SECONDS = 5
OUTPUT_LIMIT = 4096
NAME_LIMIT = 64
ARGV_LIMIT = 16


def fail(message):
    print("ptc-manager-tool-probe: " + message, file=sys.stderr)
    sys.exit(2)


def load_catalog(path):
    with open(path, "rb") as handle:
        catalog = json.loads(handle.read(256 * 1024))
    probes = catalog.get("probes") if isinstance(catalog, dict) else None
    if not isinstance(probes, list) or len(probes) > MAX_PROBES:
        fail("catalog must hold at most %d probes" % MAX_PROBES)
    for probe in probes:
        name = probe.get("name") if isinstance(probe, dict) else None
        argv = probe.get("argv") if isinstance(probe, dict) else None
        if not isinstance(name, str) or not 0 < len(name) <= NAME_LIMIT:
            fail("probe name is invalid")
        if (not isinstance(argv, list) or not 0 < len(argv) <= ARGV_LIMIT
                or not all(isinstance(part, str) and part for part in argv)):
            fail("probe argv is invalid")
    return probes


def drain(stream, chunks):
    """Read a pipe to its end, keeping only the first OUTPUT_LIMIT bytes."""
    kept = 0
    while True:
        data = os.read(stream.fileno(), 65536)
        if not data:
            return
        if kept < OUTPUT_LIMIT:
            chunks.append(data[:OUTPUT_LIMIT - kept])
            kept += len(chunks[-1])


def text(chunks):
    return b"".join(chunks).decode("utf-8", "replace")


def kill_group(pgid):
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        pass


def run_probe(probe):
    result = {"name": probe["name"], "exit_status": None, "timed_out": False,
              "stdout": "", "stderr": "", "error": None}
    # Each probe runs in a process group led by a sentinel this script owns and
    # reaps last. The group id therefore stays reserved until the whole group,
    # every descendant included, has been killed, however the probe exits.
    sentinel = subprocess.Popen(
        ["/bin/sleep", str(TIMEOUT_SECONDS + 60)], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        preexec_fn=lambda: os.setpgid(0, 0))
    try:
        return run_in_group(probe, result, sentinel.pid)
    finally:
        kill_group(sentinel.pid)
        sentinel.wait()


def run_in_group(probe, result, pgid):
    try:
        process = subprocess.Popen(
            probe["argv"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, preexec_fn=lambda: os.setpgid(0, pgid))
    except FileNotFoundError:
        result["error"] = "not_found"
        return result
    except PermissionError:
        result["error"] = "permission_denied"
        return result
    except OSError as error:
        result["error"] = "spawn_failed: " + error.__class__.__name__
        return result
    stdout, stderr = [], []
    readers = [threading.Thread(target=drain, args=(process.stdout, stdout), daemon=True),
               threading.Thread(target=drain, args=(process.stderr, stderr), daemon=True)]
    for reader in readers:
        reader.start()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    try:
        process.wait(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        result["timed_out"] = True
    for reader in readers:
        reader.join(timeout=max(deadline - time.monotonic(), 0))
    # Whatever the probe left behind goes now, which also closes its pipes.
    kill_group(pgid)
    process.wait()
    for reader in readers:
        reader.join(timeout=1)
    result["exit_status"] = process.returncode
    result["stdout"] = text(stdout)
    result["stderr"] = text(stderr)
    return result


def memory_bytes():
    try:
        with open("/proc/meminfo") as handle:
            for line in handle:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024
    except OSError:
        pass
    try:
        output = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "hw.memsize"], stdin=subprocess.DEVNULL,
            capture_output=True, timeout=TIMEOUT_SECONDS, check=True).stdout
        return int(output.strip())
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def disk_free_bytes():
    try:
        return shutil.disk_usage("/").free
    except OSError:
        return None


def snapshot(context, probes):
    return {
        "schema_version": 1,
        "context": context,
        "captured_at": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "os": platform.system().lower(),
        "arch": platform.machine(),
        "cpu_count": os.cpu_count(),
        "memory_bytes": memory_bytes(),
        "disk_free_bytes": disk_free_bytes(),
        "probes": [run_probe(probe) for probe in probes],
    }


def write_atomically(path, document):
    directory = os.path.dirname(os.path.abspath(path))
    descriptor, temporary = tempfile.mkstemp(
        prefix=".tool-inventory-", dir=directory)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(document, handle)
        os.chmod(temporary, 0o640)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def main(argv):
    if len(argv) not in (3, 4):
        fail("expected CONTEXT CATALOG [OUTPUT]")
    context = argv[1]
    if context not in ("pane", "setup"):
        fail("context must be pane or setup")
    document = snapshot(context, load_catalog(argv[2]))
    if len(argv) == 4:
        write_atomically(argv[3], document)
    else:
        json.dump(document, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
