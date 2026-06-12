r"""Hyper-V backend driver.

The Python side is a thin shell around three PowerShell helpers in
``tools/boot-harness/hyperv/``:

  - ``new-boot-vm.ps1``   creates the VM, attaches the named-pipe serial
                          and the ISO/VHDX, returns the VM name on stdout.
  - ``start-boot-vm.ps1``  starts the VM and tails ``\\.\pipe\<name>-com1``
                          to its own stdout; the Python driver reads that
                          stream.
  - ``stop-boot-vm.ps1``   force-stops, removes the VM, deletes the VHDX.

Cleanup contract: even on exception in the parent, ``close()`` (and an
``atexit`` hook) MUST run ``stop-boot-vm.ps1``. If that fails for any
reason, the wrapper logs the orphan VM name so the operator can clean
it up — every transient name carries the ``repro-test-boot-`` prefix
so a sweep is trivial.
"""

from __future__ import annotations

import atexit
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import weakref
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR.parents[1]) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR.parents[1]))

from lib.assertions import HarnessSession, LineBuffer, BootAssertionError  # noqa: E402


REPRO_PREFIX = "repro-test-boot-"
_HYPERV_DIR = _THIS_DIR.parents[1] / "hyperv"


def _ps_path(name: str) -> Path:
    p = _HYPERV_DIR / name
    if not p.is_file():
        raise FileNotFoundError(f"Hyper-V helper not found: {p}")
    return p


def _run_ps(script: Path, args: list[str], *, timeout: int = 120) -> subprocess.CompletedProcess:
    argv = [
        "powershell.exe", "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", str(script),
        *args,
    ]
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


@dataclass
class HyperVConfig:
    image_path: Optional[Path] = None  # None => --dry-run lifecycle smoke
    generation: int = 2                # Gen-2 UEFI by default
    memory_mb: int = 1024
    vhdx_size_gb: int = 8
    vm_name: str = ""
    serial_log_path: Optional[Path] = None
    vhdx_path: Optional[Path] = None
    pipe_name: str = ""                # named pipe \\.\pipe\<this>
    image_kind: str = "iso"            # "iso" | "vhdx"
    dry_run: bool = False              # create + destroy with no boot media


class HyperVSession(HarnessSession):
    _live: "weakref.WeakSet[HyperVSession]" = weakref.WeakSet()

    def __init__(self, cfg: HyperVConfig):
        if not cfg.vm_name:
            cfg.vm_name = f"{REPRO_PREFIX}{uuid.uuid4().hex[:8]}"
        if not cfg.vm_name.startswith(REPRO_PREFIX):
            raise RuntimeError(
                f"SAFETY: refusing Hyper-V op on VM name {cfg.vm_name!r} "
                f"(must start with {REPRO_PREFIX!r})"
            )
        if not cfg.pipe_name:
            cfg.pipe_name = f"{cfg.vm_name}-com1"
        base = Path(os.environ.get("TEMP", tempfile.gettempdir())) / "repro-boot-harness"
        base.mkdir(parents=True, exist_ok=True)
        if cfg.vhdx_path is None:
            cfg.vhdx_path = base / f"{cfg.vm_name}.vhdx"
        if cfg.serial_log_path is None:
            cfg.serial_log_path = base / f"{cfg.vm_name}.log"
        self.cfg = cfg
        self.buf = LineBuffer()
        self._serial_proc: Optional[subprocess.Popen[bytes]] = None
        self._reader: Optional[threading.Thread] = None
        self._log_fh = cfg.serial_log_path.open("wb")
        self._stop = threading.Event()
        self._chunk_q: "queue.Queue[bytes]" = queue.Queue()
        self._created = False
        HyperVSession._live.add(self)

    # --- lifecycle -------------------------------------------------------
    def start(self) -> None:
        args = [
            "-VmName", self.cfg.vm_name,
            "-PipeName", self.cfg.pipe_name,
            "-VhdxPath", str(self.cfg.vhdx_path),
            "-Generation", str(self.cfg.generation),
            "-MemoryMB", str(self.cfg.memory_mb),
            "-VhdxSizeGB", str(self.cfg.vhdx_size_gb),
        ]
        if self.cfg.image_path is not None and not self.cfg.dry_run:
            args += ["-ImagePath", str(self.cfg.image_path),
                     "-ImageKind", self.cfg.image_kind]
        if self.cfg.dry_run:
            args += ["-DryRun"]
        r = _run_ps(_ps_path("new-boot-vm.ps1"), args, timeout=180)
        if r.returncode != 0:
            raise RuntimeError(
                f"new-boot-vm.ps1 failed (rc={r.returncode}):\nstdout={r.stdout}\nstderr={r.stderr}"
            )
        self._created = True
        if self.cfg.dry_run:
            # No start: dry-run validates create+destroy lifecycle only.
            return
        # Start VM + tail serial pipe to stdout in a background powershell process.
        argv = [
            "powershell.exe", "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", str(_ps_path("start-boot-vm.ps1")),
            "-VmName", self.cfg.vm_name,
            "-PipeName", self.cfg.pipe_name,
        ]
        self._serial_proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0,
        )
        self._reader = threading.Thread(target=self._read_stdout,
                                        name="hyperv-serial", daemon=True)
        self._reader.start()

    def _read_stdout(self) -> None:
        assert self._serial_proc is not None and self._serial_proc.stdout is not None
        try:
            while not self._stop.is_set():
                chunk = self._serial_proc.stdout.read(4096)
                if not chunk:
                    return
                self._log_fh.write(chunk)
                self._log_fh.flush()
                self._chunk_q.put(chunk)
        except Exception:
            return

    def _drain(self) -> None:
        try:
            while True:
                chunk = self._chunk_q.get_nowait()
                self.buf.feed(chunk.decode("utf-8", errors="replace"))
        except queue.Empty:
            return

    # --- HarnessSession API ---------------------------------------------
    def expect_line(self, pattern: str, timeout_s: float = 60.0) -> re.Match[str]:
        return self.buf.expect(pattern, timeout_s, more=self._drain)

    def send(self, text: str) -> None:
        if self._serial_proc is None or self._serial_proc.stdin is None:
            raise BootAssertionError("Hyper-V session not started (or dry-run)")
        self._serial_proc.stdin.write(text.encode("utf-8"))
        self._serial_proc.stdin.flush()

    def capture_until(self, pattern: str, timeout_s: float = 60.0) -> str:
        return self.buf.capture_until(pattern, timeout_s, more=self._drain)

    def close(self) -> None:
        self._stop.set()
        if self._serial_proc is not None and self._serial_proc.poll() is None:
            try:
                self._serial_proc.terminate()
                try:
                    self._serial_proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self._serial_proc.kill()
            except Exception:
                pass
        try:
            self._log_fh.close()
        except Exception:
            pass
        if self._created:
            self._teardown_vm()

    def _teardown_vm(self) -> None:
        try:
            r = _run_ps(_ps_path("stop-boot-vm.ps1"),
                        ["-VmName", self.cfg.vm_name,
                         "-VhdxPath", str(self.cfg.vhdx_path)],
                        timeout=120)
            if r.returncode != 0:
                sys.stderr.write(
                    f"[boot-harness] WARN: stop-boot-vm.ps1 rc={r.returncode}\n"
                    f"  stdout: {r.stdout}\n  stderr: {r.stderr}\n"
                    f"  ORPHAN may remain: {self.cfg.vm_name}\n"
                )
        except Exception as exc:
            sys.stderr.write(
                f"[boot-harness] WARN: teardown threw: {exc}\n"
                f"  ORPHAN may remain: {self.cfg.vm_name}\n"
            )
        self._created = False

    def __enter__(self) -> "HyperVSession":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


@atexit.register
def _reap_all() -> None:
    for s in list(HyperVSession._live):
        try:
            s.close()
        except Exception:
            pass


def validate() -> tuple[bool, str]:
    """Check that the Hyper-V PowerShell module is available."""
    argv = [
        "powershell.exe", "-NoProfile", "-NonInteractive",
        "-Command",
        "if (Get-Command Get-VM -ErrorAction SilentlyContinue) { 'ok' } else { 'missing' }",
    ]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        out = (r.stdout or "").strip()
        if out == "ok":
            return (True, "Hyper-V module: Get-VM available")
        return (False, f"Hyper-V module missing (output={out!r}, rc={r.returncode})")
    except Exception as exc:
        return (False, f"powershell invocation failed: {exc}")
