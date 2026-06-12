#!/usr/bin/env python3
"""JSON-shape stability tests for the Outcome dataclass.

The schema written under ``boot-harness-out/<image-sha256>/<timestamp>.json``
is the only stable contract for downstream consumers. These tests pin
the field names + types so future edits don't silently break R1+.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent))

from lib.outcome import Outcome, default_out_root, sha256_file, utc_now_iso  # noqa: E402


REQUIRED_FIELDS = {
    "backend",
    "image_sha256",
    "image_path",
    "started_at",
    "finished_at",
    "outcome",
    "assertions_passed",
    "assertions_failed",
    "serial_log_path",
    "vm_name",
    "error_message",
    "assertions",
}


class TestOutcomeShape(unittest.TestCase):
    def _make_outcome(self) -> Outcome:
        return Outcome(
            backend="qemu",
            image_sha256="a" * 64,
            image_path="C:/tmp/x.iso",
            started_at=utc_now_iso(),
            finished_at=utc_now_iso(),
            outcome="PASS",
            assertions_passed=2,
            assertions_failed=0,
            serial_log_path="C:/tmp/x.log",
            vm_name="repro-test-boot-deadbeef",
        )

    def test_schema_has_required_fields(self):
        d = self._make_outcome().to_dict()
        self.assertEqual(REQUIRED_FIELDS, set(d.keys()))

    def test_schema_types(self):
        d = self._make_outcome().to_dict()
        self.assertIsInstance(d["backend"], str)
        self.assertIsInstance(d["image_sha256"], str)
        self.assertIsInstance(d["image_path"], str)
        self.assertIsInstance(d["started_at"], str)
        self.assertIsInstance(d["finished_at"], str)
        self.assertIn(d["outcome"], ("PASS", "FAIL", "TIMEOUT", "ERROR"))
        self.assertIsInstance(d["assertions_passed"], int)
        self.assertIsInstance(d["assertions_failed"], int)
        self.assertIsInstance(d["serial_log_path"], str)
        self.assertIsInstance(d["vm_name"], str)
        self.assertIsInstance(d["error_message"], str)
        self.assertIsInstance(d["assertions"], list)

    def test_json_roundtrip(self):
        d = self._make_outcome().to_dict()
        s = json.dumps(d)
        d2 = json.loads(s)
        self.assertEqual(d, d2)

    def test_write_targets_per_sha_dir(self):
        with tempfile.TemporaryDirectory() as td:
            out_root = Path(td)
            target = self._make_outcome().write(out_root)
            self.assertTrue(target.is_file())
            # Layout: <out_root>/<image_sha256>/<timestamp>.json
            self.assertEqual(target.parent.parent, out_root)
            self.assertEqual(target.parent.name, "a" * 64)
            self.assertTrue(target.name.endswith(".json"))

    def test_sha256_file_roundtrip(self):
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(b"hello world")
            tmp_path = Path(tmp.name)
        try:
            h = sha256_file(tmp_path)
            self.assertEqual(h, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        finally:
            tmp_path.unlink(missing_ok=True)

    def test_default_out_root_relative_to_repo(self):
        root = default_out_root(Path("D:/metacraft/reprobuild"))
        self.assertEqual(root.name, "boot-harness-out")


if __name__ == "__main__":
    unittest.main(verbosity=2)
