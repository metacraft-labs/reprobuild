"""The per-landing run of the attestation collateral monitor must not
refuse a landing for the calendar, and must still refuse for what a
landing can break.

No mocks: it runs the real tool over the real ledger (or a copy with one
row edited) at an explicit --now, so the answer does not depend on the
wall clock.

Run: python3 -m unittest tests/unit/test_attestation_collateral_monitor_landing.py
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "attestation_collateral_monitor.py"
LEDGER_ROOT = ROOT / "tests" / "integration"
# Seven Intel documents ended 2026-11-01 and the AMD lists 2026-11-09.
AFTER_EXPIRY = "2026-11-12T00:00:00Z"


def run(*args, ledger_root=LEDGER_ROOT):
    p = subprocess.run(
        [sys.executable, str(TOOL), "--offline", "--ledger-root",
         str(ledger_root), *args],
        capture_output=True, text=True, cwd=ROOT)
    return p.returncode, p.stdout


class LandingVerdict(unittest.TestCase):
    def test_expired_pins_refuse_the_scheduled_run(self):
        code, out = run("--now", AFTER_EXPIRY)
        self.assertEqual(code, 1, out)
        self.assertIn("! PcsTcbInfoSprJson: expired", out)

    def test_expired_pins_are_only_notices_on_a_landing(self):
        code, out = run("--now", AFTER_EXPIRY, "--landing")
        self.assertEqual(code, 0, out)
        self.assertIn("~ PcsTcbInfoSprJson: expired", out)
        self.assertNotIn("  ! ", out)

    def test_due_for_refresh_is_a_notice_on_a_landing(self):
        code, out = run("--now", "2026-10-25T00:00:00Z", "--landing")
        self.assertEqual(code, 0, out)
        self.assertIn("~ ", out)

    def test_a_document_from_the_future_still_refuses_a_landing(self):
        code, out = run("--now", "2020-01-01T00:00:00Z", "--landing")
        self.assertEqual(code, 1, out)
        self.assertIn("not-yet-in-force", out)

    def test_a_vintage_that_is_not_expired_still_refuses_a_landing(self):
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copytree(LEDGER_ROOT, tmp, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("*.nim", "*.log"))
            ledger = Path(tmp) / "attestation-fixture-ledger.tsv"
            rows = ledger.read_text().splitlines()
            out_rows, edited = [], False
            for r in rows:
                f = r.split("\t")
                if len(f) == 10 and f[0] == "GtgQeIdentityJson":
                    f[9] = "2099-01-01T00:00:00Z"
                    edited = True
                    r = "\t".join(f)
                out_rows.append(r)
            self.assertTrue(edited)
            ledger.write_text("\n".join(out_rows) + "\n")
            code, out = run("--now", AFTER_EXPIRY, "--landing",
                            ledger_root=tmp)
        self.assertEqual(code, 1, out)
        self.assertIn("! GtgQeIdentityJson", out)


if __name__ == "__main__":
    unittest.main()
