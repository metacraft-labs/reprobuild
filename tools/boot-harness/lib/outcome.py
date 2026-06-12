"""Outcome dataclass + JSON serialization for boot-harness runs.

The schema written under ``boot-harness-out/<image-sha256>/<timestamp>.json``
is the only stable contract for downstream consumers (R1+, CI). Treat the
field set as append-only; never repurpose a field name.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

OutcomeStatus = Literal["PASS", "FAIL", "TIMEOUT", "ERROR"]
BackendName = Literal["hyperv", "wsl2", "qemu"]


def utc_now_iso() -> str:
    """Return current UTC time in ISO-8601 with trailing Z (no microseconds)."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: Path, chunk_size: int = 65536) -> str:
    """Return the lowercase hex sha256 of the file at ``path``."""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(chunk_size), b""):
            h.update(block)
    return h.hexdigest()


@dataclass
class Outcome:
    """One harness run.

    ``vm_name`` is the backend-allocated transient name (Hyper-V VM,
    WSL2 distro, or "qemu-pid-<pid>" for QEMU). ``serial_log_path`` is
    the absolute path to the captured serial-console transcript.
    """

    backend: BackendName
    image_sha256: str
    image_path: str
    started_at: str
    finished_at: str
    outcome: OutcomeStatus
    assertions_passed: int
    assertions_failed: int
    serial_log_path: str
    vm_name: str
    error_message: str = ""
    assertions: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)

    def to_json(self, *, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, sort_keys=True)

    def write(self, out_root: Path) -> Path:
        """Write self under ``out_root/<image_sha256>/<timestamp>.json``.

        Returns the path written.
        """
        # finished_at is already ISO-8601 Z; sanitize colons for file system.
        stamp = self.finished_at.replace(":", "").replace("-", "")
        target_dir = out_root / self.image_sha256
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / f"{stamp}.json"
        target.write_text(self.to_json() + "\n", encoding="utf-8")
        return target


def default_out_root(repo_root: Path) -> Path:
    """Standard output root for harness runs.

    ``boot-harness-out/`` lives under the repo root (git-ignored) so
    artifacts from multiple runs accumulate in one place across
    invocations from different shells.
    """
    return repo_root / "boot-harness-out"
