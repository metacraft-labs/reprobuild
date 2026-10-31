#!/usr/bin/env python3
"""Run the real owner script/checker on private LF and CRLF source copies.

This filesystem fixture isolates version edits, not compiler behavior. It uses
actual repository declarations and the real scripts; no compiler, release or
Nix store is involved. The existing Nim t_version assertions remain unchanged.
"""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SUBJECT = ROOT / "scripts/bump_version.sh"
CHECKER = ROOT / "scripts/check_package_nix_version.sh"
FILES = {
    "reprobuild.nimble": rb'^version = "([^"]+)"\r?$',
    "nix/pkgs/by-name/re/reprobuild/package.nix": rb'^  version = "([^"]+)";\r?$',
    "libs/repro_core/src/repro_core.nim": rb'^const ReprobuildVersion\* \{\.strdefine\.\} = "([^"]+)"\r?$',
    "tests/unit/t_version.nim": rb'^  ExpectedReprobuildVersion = "([^"]+)"\r?$',
}


class BumpVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bump-version-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        target = self.root / "scripts/check_package_nix_version.sh"
        target.parent.mkdir(parents=True)
        shutil.copy2(CHECKER, target)

    def newline_fixtures(self):
        for newline in (b"\n", b"\r\n"):
            self.newline = newline
            for name in FILES:
                target = self.root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                raw = (ROOT / name).read_bytes()
                target.write_bytes(raw.replace(b"\r\n", b"\n").replace(b"\n", newline))
            self.old = self.versions()[0]
            self.new = self.old + b".1"  # Fixture value, never a release choice.
            yield

    def snapshot(self):
        return {name: (self.root / name).read_bytes() for name in FILES}

    def versions(self):
        values = []
        for name, pattern in FILES.items():
            matches = re.findall(pattern, (self.root / name).read_bytes(), re.M)
            self.assertEqual(len(matches), 1, name)
            values.append(matches[0])
        return values

    def run_bump(self, *args):
        args = [a.decode("ascii") if isinstance(a, bytes) else a for a in args]
        return subprocess.run(["bash", str(SUBJECT), *args], cwd=self.root,
                              capture_output=True, timeout=10)

    def test_all_four_declarations_move_and_other_bytes_stay(self):
        for _ in self.newline_fixtures():
            before = self.snapshot()
            result = self.run_bump(self.new)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.versions(), [self.new] * 4)
            for name, pattern in FILES.items():
                raw = (self.root / name).read_bytes()
                match = re.search(pattern, raw, re.M)
                restored = raw[:match.start(1)] + self.old + raw[match.end(1):]
                self.assertEqual(restored, before[name], name)

    def test_same_version_is_idempotent(self):
        for _ in self.newline_fixtures():
            before = self.snapshot()
            result = self.run_bump(self.old)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.snapshot(), before)

    def test_invalid_argument_or_arity_preserves_all_inputs(self):
        for _ in self.newline_fixtures():
            for args in [(), (self.new, "extra"), ("bad;value",), ("",)]:
                with self.subTest(args=args):
                    before = self.snapshot()
                    self.assertEqual(self.run_bump(*args).returncode, 2)
                    self.assertEqual(self.snapshot(), before)

    def test_missing_declaration_fails_before_any_write(self):
        for _ in self.newline_fixtures():
            path = self.root / "tests/unit/t_version.nim"
            path.write_bytes(path.read_bytes().replace(b"ExpectedReprobuildVersion =", b"OtherVersion ="))
            before = self.snapshot()
            self.assertNotEqual(self.run_bump(self.new).returncode, 0)
            self.assertEqual(self.snapshot(), before)

    def test_duplicate_declaration_fails_before_any_write(self):
        for _ in self.newline_fixtures():
            path = self.root / "libs/repro_core/src/repro_core.nim"
            with path.open("ab") as output:
                output.write(self.newline + b'const ReprobuildVersion* {.strdefine.} = "' + self.old + b'"' + self.newline)
            before = self.snapshot()
            self.assertNotEqual(self.run_bump(self.new).returncode, 0)
            self.assertEqual(self.snapshot(), before)

    def test_existing_disagreement_fails_before_any_write(self):
        for _ in self.newline_fixtures():
            path = self.root / "tests/unit/t_version.nim"
            old = b'ExpectedReprobuildVersion = "' + self.old + b'"'
            new = b'ExpectedReprobuildVersion = "' + self.new + b'"'
            path.write_bytes(path.read_bytes().replace(old, new))
            before = self.snapshot()
            self.assertNotEqual(self.run_bump(self.new).returncode, 0)
            self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
