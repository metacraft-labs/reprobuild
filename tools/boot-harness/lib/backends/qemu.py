"""QEMU backend driver.

Spawns ``qemu-system-x86_64.exe -nographic -serial stdio …`` directly,
reads stdout in a background thread, writes guest input to stdin.

Cleanup contract: ``close()`` (or context-manager exit) MUST terminate
the QEMU child even on exception. We hold the ``Popen`` handle and
register an ``atexit`` callback so a Ctrl-C in the parent shell still
reaps the VM.
"""

from __future__ import annotations

import atexit
import os
import queue
import re
import shutil
import signal
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

# Allow ``python lib/backends/qemu.py``-style direct execution to find lib.*
_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR.parents[1]) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR.parents[1]))

from lib.assertions import HarnessSession, LineBuffer, BootAssertionError  # noqa: E402


QEMU_EXE_CANDIDATES = (
    "qemu-system-x86_64.exe",
    "qemu-system-x86_64",
)


def detect_qemu() -> Optional[Path]:
    """Return the absolute path to ``qemu-system-x86_64`` or ``None``."""
    for name in QEMU_EXE_CANDIDATES:
        p = shutil.which(name)
        if p:
            return Path(p)
    return None


@dataclass
class QEMUConfig:
    image_path: Path
    memory_mb: int = 1024
    serial_log_path: Optional[Path] = None
    vm_name: str = ""
    bios_path: Optional[Path] = None  # OVMF.fd for UEFI; None for SeaBIOS
    image_kind: str = "iso"  # "iso" | "vhdx" | "raw"
    extra_args: list[str] = None  # type: ignore[assignment]


class QEMUSession(HarnessSession):
    """One transient QEMU process driven via -serial stdio."""

    _live: "weakref.WeakSet[QEMUSession]" = weakref.WeakSet()

    def __init__(self, cfg: QEMUConfig):
        self.cfg = cfg
        if not cfg.vm_name:
            cfg.vm_name = f"repro-test-boot-{uuid.uuid4().hex[:8]}"
        if cfg.serial_log_path is None:
            cfg.serial_log_path = Path(tempfile.gettempdir()) / "repro-boot-harness" / f"{cfg.vm_name}.log"
        cfg.serial_log_path.parent.mkdir(parents=True, exist_ok=True)
        self.qemu = detect_qemu()
        if self.qemu is None:
            raise RuntimeError(
                "qemu-system-x86_64 not found on PATH. Install via "
                "`winget install QEMU.QEMU` or `scoop install qemu`."
            )
        self.buf = LineBuffer()
        self._proc: Optional[subprocess.Popen[bytes]] = None
        self._reader: Optional[threading.Thread] = None
        self._log_fh = cfg.serial_log_path.open("wb")
        self._stop = threading.Event()
        self._chunk_q: "queue.Queue[bytes]" = queue.Queue()
        QEMUSession._live.add(self)

    # --- lifecycle -------------------------------------------------------
    def start(self) -> None:
        argv: list[str] = [str(self.qemu),
                           "-m", str(self.cfg.memory_mb),
                           "-nographic",
                           "-serial", "stdio",
                           "-display", "none",
                           "-no-reboot"]
        if self.cfg.bios_path is not None:
            argv += ["-bios", str(self.cfg.bios_path)]
        kind = self.cfg.image_kind
        if kind == "iso":
            argv += ["-cdrom", str(self.cfg.image_path)]
        elif kind in ("vhdx", "raw"):
            argv += ["-drive", f"file={self.cfg.image_path},format={'raw' if kind == 'raw' else 'vhdx'}"]
        else:
            raise ValueError(f"unsupported image kind {kind!r}")
        if self.cfg.extra_args:
            argv += list(self.cfg.extra_args)
        # Spawn detached enough that Ctrl-C in parent doesn't double-signal.
        self._proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        self._reader = threading.Thread(target=self._read_stdout, name="qemu-stdout", daemon=True)
        self._reader.start()

    def _read_stdout(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        try:
            while not self._stop.is_set():
                chunk = self._proc.stdout.read(4096)
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
        if self._proc is None or self._proc.stdin is None:
            raise BootAssertionError("QEMU session not started")
        self._proc.stdin.write(text.encode("utf-8"))
        self._proc.stdin.flush()

    def capture_until(self, pattern: str, timeout_s: float = 60.0) -> str:
        return self.buf.capture_until(pattern, timeout_s, more=self._drain)

    def close(self) -> None:
        self._stop.set()
        if self._proc is not None and self._proc.poll() is None:
            try:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
                    self._proc.wait(timeout=3)
            except Exception:
                pass
        try:
            self._log_fh.close()
        except Exception:
            pass

    def __enter__(self) -> "QEMUSession":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


@atexit.register
def _reap_all() -> None:
    for s in list(QEMUSession._live):
        try:
            s.close()
        except Exception:
            pass


def validate() -> tuple[bool, str]:
    """``harness.py validate --backend=qemu`` smoke."""
    p = detect_qemu()
    if p is None:
        return (False, "qemu-system-x86_64 not on PATH")
    try:
        out = subprocess.check_output([str(p), "--version"], stderr=subprocess.STDOUT, timeout=10)
        first = out.decode("utf-8", errors="replace").splitlines()[0]
        return (True, f"found {p}: {first}")
    except Exception as exc:
        return (False, f"qemu found at {p} but --version failed: {exc}")
