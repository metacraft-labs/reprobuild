"""WSL2 backend driver.

For tarball-rootfs iteration: ``wsl --import`` a rootfs tarball into a
transient distro whose name starts with ``repro-test-boot-``, then
treat ``wsl -d <name> -- /bin/sh -c '<cmd>'`` as the "guest command"
channel. There is no serial console (no kernel) — assertions match
against process stdout/stderr instead.

Safety: ``wsl --unregister`` is restricted to ``repro-*``-prefixed
distros across the dev environment (see project memory
``project_dotfiles_cross_os_migration.md``). This driver hard-asserts
the prefix before any destructive op.
"""

from __future__ import annotations

import atexit
import os
import queue
import re
import shutil
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


def detect_wsl() -> Optional[Path]:
    p = shutil.which("wsl.exe") or shutil.which("wsl")
    return Path(p) if p else None


def _assert_safe(name: str) -> None:
    if not name.startswith(REPRO_PREFIX):
        raise RuntimeError(
            f"SAFETY: refusing to operate on WSL distro {name!r} "
            f"(must start with {REPRO_PREFIX!r})"
        )


@dataclass
class WSL2Config:
    rootfs_tar: Path
    vm_name: str = ""
    work_dir: Optional[Path] = None
    serial_log_path: Optional[Path] = None
    command: str = "/bin/sh"  # default shell to spawn for the session
    extra_args: list[str] = None  # type: ignore[assignment]


class WSL2Session(HarnessSession):
    """One transient WSL2 distro + interactive shell process."""

    _live: "weakref.WeakSet[WSL2Session]" = weakref.WeakSet()

    def __init__(self, cfg: WSL2Config):
        self.wsl = detect_wsl()
        if self.wsl is None:
            raise RuntimeError("wsl.exe not found on PATH")
        self.cfg = cfg
        if not cfg.vm_name:
            cfg.vm_name = f"{REPRO_PREFIX}{uuid.uuid4().hex[:8]}"
        _assert_safe(cfg.vm_name)
        base = Path(os.environ.get("TEMP", tempfile.gettempdir())) / "repro-boot-harness"
        if cfg.work_dir is None:
            cfg.work_dir = base / f"{cfg.vm_name}-wsl"
        if cfg.serial_log_path is None:
            cfg.serial_log_path = base / f"{cfg.vm_name}.log"
        cfg.serial_log_path.parent.mkdir(parents=True, exist_ok=True)
        cfg.work_dir.mkdir(parents=True, exist_ok=True)
        self.buf = LineBuffer()
        self._proc: Optional[subprocess.Popen[bytes]] = None
        self._reader: Optional[threading.Thread] = None
        self._log_fh = cfg.serial_log_path.open("wb")
        self._stop = threading.Event()
        self._chunk_q: "queue.Queue[bytes]" = queue.Queue()
        self._imported = False
        WSL2Session._live.add(self)

    # --- lifecycle -------------------------------------------------------
    def start(self) -> None:
        if not self.cfg.rootfs_tar.is_file():
            raise FileNotFoundError(f"rootfs tar not found: {self.cfg.rootfs_tar}")
        # wsl --import <name> <dir> <tar>
        argv_import = [str(self.wsl), "--import",
                       self.cfg.vm_name,
                       str(self.cfg.work_dir),
                       str(self.cfg.rootfs_tar)]
        r = subprocess.run(argv_import, capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(
                f"wsl --import failed (rc={r.returncode}): "
                f"{r.stdout!r} / {r.stderr!r}"
            )
        self._imported = True
        # Spawn the interactive shell for streaming assertions.
        argv_run = [str(self.wsl), "-d", self.cfg.vm_name, "--", self.cfg.command]
        if self.cfg.extra_args:
            argv_run += list(self.cfg.extra_args)
        self._proc = subprocess.Popen(
            argv_run,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        self._reader = threading.Thread(target=self._read_stdout, name="wsl2-stdout", daemon=True)
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
            raise BootAssertionError("WSL2 session not started")
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
        if self._imported:
            self._teardown_distro()

    def _teardown_distro(self) -> None:
        name = self.cfg.vm_name
        _assert_safe(name)
        try:
            subprocess.run([str(self.wsl), "--terminate", name], capture_output=True, timeout=15)
        except Exception:
            pass
        try:
            subprocess.run([str(self.wsl), "--unregister", name], capture_output=True, timeout=30)
        except Exception:
            pass
        try:
            if self.cfg.work_dir is not None and self.cfg.work_dir.exists():
                shutil.rmtree(self.cfg.work_dir, ignore_errors=True)
        except Exception:
            pass
        self._imported = False

    def __enter__(self) -> "WSL2Session":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


@atexit.register
def _reap_all() -> None:
    for s in list(WSL2Session._live):
        try:
            s.close()
        except Exception:
            pass


def validate() -> tuple[bool, str]:
    p = detect_wsl()
    if p is None:
        return (False, "wsl.exe not found on PATH")
    try:
        out = subprocess.check_output([str(p), "--status"],
                                      stderr=subprocess.STDOUT, timeout=15)
        # ``wsl --status`` output is UTF-16 LE on Windows; decode resiliently.
        text = out.decode("utf-16-le", errors="replace") if b"\x00" in out[:8] else out.decode("utf-8", errors="replace")
        return (True, f"wsl.exe present: {text.splitlines()[0].strip() if text.strip() else 'OK'}")
    except subprocess.CalledProcessError as exc:
        return (False, f"wsl --status failed: rc={exc.returncode}")
    except Exception as exc:
        return (False, f"wsl.exe found at {p} but --status failed: {exc}")
