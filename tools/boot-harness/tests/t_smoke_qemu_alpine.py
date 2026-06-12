#!/usr/bin/env python3
"""End-to-end smoke: boot Alpine standard ISO 3.20 via the QEMU backend.

Skips automatically if QEMU isn't installed or if the network is
unreachable (download). The test will be exercised in R1 on hosts that
have QEMU; the harness scaffolding tests (t_assertions, t_outcome_json)
run unconditionally.
"""

from __future__ import annotations

import hashlib
import os
import sys
import unittest
from pathlib import Path
from urllib.request import Request, urlopen

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent))

# --- Pinned Alpine fixture --------------------------------------------------
# alpine-standard-3.20.3-x86_64.iso, published 2024-09-06 by Alpine Linux.
# The sha256 below is the upstream-published digest; if Alpine rotates a
# release (rare for point releases) the download verifier will fail with
# a clear message and this constant should be re-pinned.
ALPINE_VERSION = "3.20.3"
ALPINE_ISO_NAME = f"alpine-standard-{ALPINE_VERSION}-x86_64.iso"
ALPINE_ISO_URL = (
    f"https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/{ALPINE_ISO_NAME}"
)
# Upstream-published sha256 (see https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/).
# Empty string => verifier accepts whatever we downloaded (R0 fallback so the
# test can still exercise the harness shape on hosts without a pre-pin); R1
# will tighten this to the actual digest before the gate goes live.
ALPINE_ISO_SHA256 = ""

CACHE_DIR_ENV = os.environ.get("LOCALAPPDATA") or os.environ.get("TEMP") or "/tmp"
CACHE_DIR = Path(CACHE_DIR_ENV) / "repro-boot-harness-cache"


def _download_iso(dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = Request(ALPINE_ISO_URL, headers={"User-Agent": "repro-boot-harness"})
    with urlopen(req, timeout=120) as resp, dest.open("wb") as fh:
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            fh.write(chunk)


def _verify_or_download() -> Path:
    target = CACHE_DIR / ALPINE_ISO_NAME
    if target.is_file():
        if not ALPINE_ISO_SHA256:
            return target
        h = hashlib.sha256()
        with target.open("rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        if h.hexdigest().lower() == ALPINE_ISO_SHA256.lower():
            return target
        target.unlink(missing_ok=True)
    _download_iso(target)
    if ALPINE_ISO_SHA256:
        h = hashlib.sha256()
        with target.open("rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        if h.hexdigest().lower() != ALPINE_ISO_SHA256.lower():
            raise RuntimeError(
                f"Alpine ISO sha256 mismatch: expected {ALPINE_ISO_SHA256}, got {h.hexdigest()}"
            )
    return target


class TestAlpineQEMUBoot(unittest.TestCase):
    def setUp(self) -> None:
        from lib.backends import qemu as qemu_backend
        ok, msg = qemu_backend.validate()
        if not ok:
            self.skipTest(f"QEMU not available: {msg}")
        try:
            self.iso = _verify_or_download()
        except Exception as exc:  # noqa: BLE001
            self.skipTest(f"Could not fetch Alpine ISO: {exc}")

    def test_boot_to_login_and_release(self):
        from lib.assertions import BootAssertion
        from lib.backends.qemu import QEMUConfig, QEMUSession

        cfg = QEMUConfig(image_path=self.iso, image_kind="iso", memory_mb=512)
        sess = QEMUSession(cfg)
        sess.start()
        try:
            assertions = [
                BootAssertion(expect_line=r"login:\s*$", timeout_s=120.0,
                              send_after_match="root\n",
                              description="Alpine login prompt"),
                BootAssertion(expect_line=r"localhost:~#", timeout_s=30.0,
                              send_after_match="cat /etc/alpine-release\n",
                              description="Root shell prompt"),
                BootAssertion(expect_line=r"^3\.\d+\.\d+", timeout_s=10.0,
                              description="alpine-release line"),
            ]
            records = sess.run_assertions(assertions)
            self.assertTrue(all(r.matched for r in records),
                            msg=f"records={[r.to_dict() for r in records]}")
        finally:
            sess.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
