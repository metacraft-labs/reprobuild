#!/usr/bin/env python3
r"""R1 boot-test driver — vendored-systemd-on-WSL2 end-to-end gate.

Validates that the R0 boot-harness (WSL2 backend) + the vendored
Debian-bookworm-slim rootfs + post-import systemd install + systemd-as-PID-1
in WSL2 + the assertion DSL all work together against a real systemd
userspace. This is the gate that proves R0 + ISO/rootfs build + boot
integration BEFORE R4-R10 invest months in the from-source bootstrap.

Path A (WSL2 + Debian) is implemented here. Path B (Hyper-V + Debian
cloud image) is a follow-up — `qemu-img` for qcow2 -> VHDX conversion
is not available on this host, and that's the only documented blocker.

Run:

    pwsh recipes/reproos-ref-iso/vendor/fetch.ps1
    python recipes/reproos-ref-iso/boot-test.py

Output: PASS / FAIL with the per-assertion match text + an outcome JSON
under `recipes/reproos-ref-iso/run-evidence/<utc-timestamp>.json`.
The full serial-log (rootfs stdout/stderr stream) lives under
`$env:TEMP\repro-boot-harness\<vm-name>.log` per the R0 contract and is
referenced from the outcome JSON.

Cleanup: the WSL2 distro is unregistered (and its filesystem deleted)
in `finally:`. Names use the `repro-test-boot-` prefix; the R0
WSL2Session driver hard-fails any operation on a name without that
prefix, so cleanup cannot escape the test sandbox.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_REPO_ROOT = _HERE.parents[1]
_HARNESS_ROOT = _REPO_ROOT / "tools" / "boot-harness"
sys.path.insert(0, str(_HARNESS_ROOT))

# Imports come from the R0 harness; these are intentionally not at module
# scope until we've fixed up sys.path.
from lib.backends.wsl2 import WSL2Config, WSL2Session, REPRO_PREFIX  # noqa: E402
from lib.assertions import BootAssertion, AssertionRecord, BootAssertionError  # noqa: E402
from lib.outcome import Outcome, sha256_file, utc_now_iso  # noqa: E402


VENDOR_DIR = _HERE / "vendor"
EVIDENCE_DIR = _HERE / "run-evidence"
EXPECT_PATH = _HERE / "expected.json"


def log(msg: str) -> None:
    print(f"[r1-boot-test] {msg}", flush=True)


def _utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _verify_blob(expected: dict) -> Path:
    """Confirm the vendored rootfs blob is present + sha256 matches."""
    rel = expected["image"]
    sha = expected["image_sha256"]
    blob = (_HERE / rel).resolve()
    if not blob.is_file():
        raise SystemExit(
            f"vendored blob missing: {blob}\n"
            f"run `pwsh recipes/reproos-ref-iso/vendor/fetch.ps1` first"
        )
    got = sha256_file(blob)
    if got != sha:
        raise SystemExit(
            f"vendored blob sha256 mismatch:\n  got      {got}\n  expected {sha}\n"
            f"delete {blob} and re-run fetch.ps1"
        )
    log(f"blob OK: {blob.name} sha256={got}")
    return blob


def _wsl_exec(wsl: Path, distro: str, *args: str, capture: bool = True,
              timeout: float = 120.0) -> subprocess.CompletedProcess:
    """Run `wsl -d <distro> -- <args>` with deterministic env.

    We invoke the user-mode shell directly (not `--exec`) so the calls
    work both before and after `systemd=true` is in wsl.conf — under
    systemd-mode WSL still honours per-command spawns.
    """
    if not distro.startswith(REPRO_PREFIX):
        raise RuntimeError(f"SAFETY: refusing wsl exec on {distro!r}")
    argv = [str(wsl), "-d", distro, "--user", "root", "--"] + list(args)
    return subprocess.run(argv, capture_output=capture, timeout=timeout)


def _wsl_terminate(wsl: Path, distro: str) -> None:
    if not distro.startswith(REPRO_PREFIX):
        raise RuntimeError(f"SAFETY: refusing wsl terminate on {distro!r}")
    subprocess.run([str(wsl), "--terminate", distro],
                   capture_output=True, timeout=30)


def _wsl_unregister(wsl: Path, distro: str) -> None:
    if not distro.startswith(REPRO_PREFIX):
        raise RuntimeError(f"SAFETY: refusing wsl unregister on {distro!r}")
    subprocess.run([str(wsl), "--unregister", distro],
                   capture_output=True, timeout=60)


def _decode_wsl_output(b: bytes) -> str:
    """`wsl.exe` emits UTF-16-LE for its own messages and UTF-8 for guest
    output. Heuristically try UTF-16-LE first (NUL-byte presence) and
    fall through to UTF-8."""
    if b[:2] == b"\xff\xfe" or (len(b) >= 4 and b[1] == 0 and b[3] == 0):
        try:
            return b.decode("utf-16-le", errors="replace")
        except Exception:
            pass
    return b.decode("utf-8", errors="replace")


def _phase_import_and_bootstrap(distro: str, rootfs: Path, work_dir: Path,
                                bootstrap_log: Path, expected: dict) -> None:
    """Phase 1: import + apt-install systemd + write wsl.conf + restart.

    Driving via `wsl.exe` subprocess calls (not the WSL2Session interactive
    stdin pump) because the install needs a multi-second `apt-get update`
    that's awkward to assert against. The R0 WSL2Session pump comes back
    online in `_phase_run_assertions`.
    """
    wsl = Path(os.environ.get("ComSpec", "")).parent / "wsl.exe"
    # `shutil.which` is more reliable than the ComSpec hack.
    import shutil
    wsl_path = shutil.which("wsl.exe") or shutil.which("wsl")
    if wsl_path is None:
        raise SystemExit("wsl.exe not found on PATH")
    wsl = Path(wsl_path)

    work_dir.mkdir(parents=True, exist_ok=True)
    bootstrap_log.parent.mkdir(parents=True, exist_ok=True)
    blog = bootstrap_log.open("w", encoding="utf-8", newline="\n")

    def _record(label: str, rc: int, stdout: bytes, stderr: bytes,
                elapsed: float) -> None:
        blog.write(f"\n===== {label} (rc={rc}, {elapsed:.2f}s) =====\n")
        blog.write("--- stdout ---\n")
        blog.write(_decode_wsl_output(stdout))
        blog.write("\n--- stderr ---\n")
        blog.write(_decode_wsl_output(stderr))
        blog.flush()

    log(f"import: {rootfs.name} -> {distro}")
    t0 = time.monotonic()
    r = subprocess.run(
        [str(wsl), "--import", distro, str(work_dir), str(rootfs), "--version", "2"],
        capture_output=True, timeout=180,
    )
    _record("wsl --import", r.returncode, r.stdout, r.stderr, time.monotonic() - t0)
    if r.returncode != 0:
        raise SystemExit(
            f"wsl --import failed (rc={r.returncode}):\n"
            f"  stdout={_decode_wsl_output(r.stdout)}\n"
            f"  stderr={_decode_wsl_output(r.stderr)}"
        )

    # The bookworm-slim rootfs has no /etc/resolv.conf; WSL auto-generates
    # one via `[network] generateResolvConf=true` (default), so DNS works
    # before we even touch wsl.conf.

    # First check what we've got: should be Debian bookworm.
    t0 = time.monotonic()
    r = _wsl_exec(wsl, distro, "/bin/sh", "-c",
                  "cat /etc/os-release", timeout=30)
    _record("os-release", r.returncode, r.stdout, r.stderr,
            time.monotonic() - t0)
    if r.returncode != 0:
        raise SystemExit(f"could not read os-release from {distro}")
    if b"bookworm" not in r.stdout.lower():
        log(f"warning: os-release did not contain 'bookworm':\n"
            f"{_decode_wsl_output(r.stdout)}")

    # Run the post-import setup script. We concatenate the steps into one
    # `/bin/sh -c` invocation so failures halt the chain.
    setup_steps = expected.get("post_import_setup", [])
    if not setup_steps:
        raise SystemExit("expected.json: post_import_setup is empty")
    setup_script = " && ".join(setup_steps)
    log(f"bootstrap: {setup_script[:80]}...")
    t0 = time.monotonic()
    # apt's network fetch can be slow; allow 6 minutes.
    r = _wsl_exec(wsl, distro, "/bin/sh", "-c", setup_script, timeout=360)
    _record("post-import-setup", r.returncode, r.stdout, r.stderr,
            time.monotonic() - t0)
    if r.returncode != 0:
        raise SystemExit(
            f"post-import setup failed (rc={r.returncode}):\n"
            f"  stdout={_decode_wsl_output(r.stdout)}\n"
            f"  stderr={_decode_wsl_output(r.stderr)}"
        )

    # Sanity-check: /etc/wsl.conf exists and contains systemd=true.
    r = _wsl_exec(wsl, distro, "/bin/sh", "-c", "cat /etc/wsl.conf",
                  timeout=15)
    if b"systemd=true" not in r.stdout:
        raise SystemExit(
            f"/etc/wsl.conf did not contain systemd=true after setup:\n"
            f"  stdout={_decode_wsl_output(r.stdout)}"
        )

    # Terminate so the next launch picks up the new wsl.conf.
    log("terminating distro to apply wsl.conf changes")
    _wsl_terminate(wsl, distro)
    blog.close()


def _phase_run_assertions(distro: str, expected: dict,
                          rootfs: Path, image_sha: str,
                          started_at: str) -> tuple[Outcome, list[AssertionRecord]]:
    """Phase 2: spawn an interactive shell under the now-systemd-mode
    distro and run the assertions from expected.json."""
    # WSL2Config + WSL2Session do a fresh `--import` if we hand them the
    # original tar, which is wrong here — we've already imported and
    # bootstrapped. Construct a thin direct session instead.

    import shutil
    import threading
    import queue
    wsl_path = shutil.which("wsl.exe") or shutil.which("wsl")
    if wsl_path is None:
        raise SystemExit("wsl.exe not found on PATH")
    wsl = Path(wsl_path)

    # Re-use the R0 LineBuffer for the assertion DSL.
    from lib.assertions import LineBuffer, BootTimeoutError

    serial_log = (
        Path(os.environ.get("TEMP", "/tmp")) /
        "repro-boot-harness" / f"{distro}.log"
    )
    serial_log.parent.mkdir(parents=True, exist_ok=True)
    log_fh = serial_log.open("wb")

    proc = subprocess.Popen(
        [str(wsl), "-d", distro, "--user", "root", "--", "/bin/sh"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, bufsize=0,
    )
    buf = LineBuffer()
    stop = threading.Event()
    q: "queue.Queue[bytes]" = queue.Queue()

    def reader() -> None:
        assert proc.stdout is not None
        try:
            while not stop.is_set():
                chunk = proc.stdout.read(4096)
                if not chunk:
                    return
                log_fh.write(chunk)
                log_fh.flush()
                q.put(chunk)
        except Exception:
            return

    th = threading.Thread(target=reader, name="r1-pump", daemon=True)
    th.start()

    def drain() -> None:
        try:
            while True:
                chunk = q.get_nowait()
                buf.feed(chunk.decode("utf-8", errors="replace"))
        except queue.Empty:
            return

    records: list[AssertionRecord] = []
    error_message = ""
    try:
        # Wait briefly for systemd to come up (WSL2 systemd boot is async).
        # First send a no-op + newline to get a fresh prompt, then assert.
        time.sleep(2.0)
        for spec in expected["assertions"]:
            a = BootAssertion(
                expect_line=spec["expect_line"],
                timeout_s=float(spec.get("timeout_s", 60.0)),
                description=spec.get("description", ""),
            )
            send_before = spec.get("send_before")
            if send_before is not None:
                assert proc.stdin is not None
                proc.stdin.write(send_before.encode("utf-8"))
                proc.stdin.flush()
            t0 = time.monotonic()
            try:
                m = buf.expect(a.expect_line, a.timeout_s, more=drain)
                rec = AssertionRecord(
                    assertion=a, matched=True,
                    elapsed_s=time.monotonic() - t0,
                    matched_text=m.group(0),
                )
                records.append(rec)
                log(f"PASS expect_line({a.expect_line!r}) "
                    f"matched {m.group(0)!r} at {rec.elapsed_s:.2f}s")
            except BootTimeoutError as exc:
                rec = AssertionRecord(
                    assertion=a, matched=False,
                    elapsed_s=time.monotonic() - t0,
                    error=str(exc),
                )
                records.append(rec)
                log(f"FAIL expect_line({a.expect_line!r}): {exc}")
                break
    except Exception as exc:  # noqa: BLE001
        error_message = f"{type(exc).__name__}: {exc}"
    finally:
        stop.set()
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=3)
        except Exception:
            pass
        try:
            log_fh.close()
        except Exception:
            pass

    n_failed = sum(1 for r in records if not r.matched)
    n_passed = sum(1 for r in records if r.matched)
    n_expected = len(expected["assertions"])
    status = "PASS" if n_failed == 0 and n_passed == n_expected else "FAIL"

    outcome = Outcome(
        backend="wsl2",
        image_sha256=image_sha,
        image_path=str(rootfs),
        started_at=started_at,
        finished_at=utc_now_iso(),
        outcome=status,
        assertions_passed=n_passed,
        assertions_failed=n_failed,
        serial_log_path=str(serial_log),
        vm_name=distro,
        error_message=error_message,
        assertions=[r.to_dict() for r in records],
    )
    return outcome, records


def main() -> int:
    expected = json.loads(EXPECT_PATH.read_text(encoding="utf-8"))
    if expected.get("backend") != "wsl2":
        raise SystemExit(
            f"expected.json backend must be 'wsl2' for R1 Path A, "
            f"got {expected.get('backend')!r}"
        )
    rootfs = _verify_blob(expected)

    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)

    distro = f"{REPRO_PREFIX}r1-{uuid.uuid4().hex[:6]}"
    work_dir = Path(os.environ.get("TEMP", "/tmp")) / "repro-boot-harness" / f"{distro}-wsl"
    bootstrap_log = (
        Path(os.environ.get("TEMP", "/tmp")) /
        "repro-boot-harness" / f"{distro}.bootstrap.log"
    )

    started = utc_now_iso()
    wall_t0 = time.monotonic()
    log(f"distro={distro}")
    log(f"work_dir={work_dir}")
    log(f"bootstrap_log={bootstrap_log}")

    outcome: Outcome | None = None
    import shutil
    try:
        _phase_import_and_bootstrap(distro, rootfs, work_dir,
                                    bootstrap_log, expected)
        outcome, _records = _phase_run_assertions(
            distro, expected, rootfs,
            expected["image_sha256"], started,
        )
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        log(f"unexpected error: {type(exc).__name__}: {exc}")
        outcome = Outcome(
            backend="wsl2",
            image_sha256=expected["image_sha256"],
            image_path=str(rootfs),
            started_at=started,
            finished_at=utc_now_iso(),
            outcome="ERROR",
            assertions_passed=0,
            assertions_failed=0,
            serial_log_path="",
            vm_name=distro,
            error_message=f"{type(exc).__name__}: {exc}",
        )
    finally:
        # Cleanup: terminate + unregister + remove work_dir.
        log(f"cleanup: unregister {distro}")
        wsl_path = shutil.which("wsl.exe") or shutil.which("wsl")
        if wsl_path is not None:
            wsl = Path(wsl_path)
            _wsl_terminate(wsl, distro)
            _wsl_unregister(wsl, distro)
        try:
            if work_dir.exists():
                shutil.rmtree(work_dir, ignore_errors=True)
        except Exception:
            pass

    wall = time.monotonic() - wall_t0
    log(f"wall-clock: {wall:.2f}s")

    if outcome is not None:
        # Write the outcome JSON into the recipe's run-evidence/ dir
        # (in addition to the R0 harness-out location which we skipped).
        stamp = _utc_stamp()
        target = EVIDENCE_DIR / f"{stamp}.json"
        target.write_text(outcome.to_json() + "\n", encoding="utf-8")
        log(f"outcome JSON: {target}")
        log(f"serial log: {outcome.serial_log_path}")
        log(f"=== {outcome.outcome} ===")
        return 0 if outcome.outcome == "PASS" else 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
