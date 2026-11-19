"""scripts/check_superseded_doc_pointers.sh judges tracked files only.

The gate refuses a pointer to a superseded user-guide page in the
documentation of record: committed code, Nix, tests, tools and published
docs. It used to grep the whole directory tree, ignored files included, so in
a working checkout it read build/, .nimcache/, .repro/ and test-logs/ --
gigabytes once the suite has run -- and refused commits because build reports
quote the paths (reprobuild-pm issue
2026-11-19-the-superseded-doc-pointer-gate-greps-untracked-build-output.md).

Each case runs the real script with real bash and git in a scratch git
repository that holds a copy of it under scripts/. The scratch repository
stands in for this checkout because the cases need files that this checkout
must not carry: a committed pointer, and ignored and untracked files that
quote one. Nothing is mocked.
"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_superseded_doc_pointers.sh"
GIT = shutil.which("git")
BASH = shutil.which("bash")
# A page the script lists in SUPERSEDED. Assembled from two parts so that this
# file, which is tracked, does not itself name the page to the real gate.
POINTER = "see docs/user-guide/" + "home-export.md for the format\n"


class SupersededDocPointerGate(unittest.TestCase):
    def setUp(self):
        # Never a silent pass: without git and bash these cases say nothing.
        self.assertIsNotNone(GIT, "git is not on PATH")
        self.assertIsNotNone(BASH, "bash is not on PATH")
        self.repo = Path(tempfile.mkdtemp(prefix="superseded-doc-gate-"))
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        self.git("init", "-q")
        (self.repo / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.repo / "scripts" / SCRIPT.name)
        (self.repo / ".gitignore").write_text("build/\ntest-logs/\n")
        (self.repo / "src").mkdir()
        (self.repo / "src" / "clean.nim").write_text("discard\n")
        self.git("add", "-A")

    def git(self, *args):
        subprocess.run(
            [GIT, "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )

    def run_gate(self):
        return subprocess.run(
            [BASH, str(self.repo / "scripts" / SCRIPT.name)],
            cwd=self.repo,
            capture_output=True,
            text=True,
        )

    def test_ignored_and_untracked_files_are_not_judged(self):
        (self.repo / "build").mkdir()
        (self.repo / "build" / "report.json").write_text(POINTER)
        (self.repo / "test-logs").mkdir()
        (self.repo / "test-logs" / "lint.log").write_text(POINTER)
        (self.repo / "scratch.txt").write_text(POINTER)  # untracked, not ignored
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK", result.stdout)

    def test_a_tracked_pointer_is_refused(self):
        # The positive control: the same text, once tracked, is refused, so the
        # case above passes because the files are not tracked, not because the
        # pattern stopped matching.
        (self.repo / "src" / "pointer.nim").write_text("# " + POINTER)
        self.git("add", "src/pointer.nim")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("src/pointer.nim", result.stderr)

    def test_the_old_pages_and_the_gate_itself_are_not_judged(self):
        guide = self.repo / "docs" / "user-guide"
        guide.mkdir(parents=True)
        (guide / "README.md").write_text(POINTER)
        vendor = self.repo / "libs" / "vendor"
        vendor.mkdir(parents=True)
        (vendor / "x.nim").write_text("# " + POINTER)
        self.git("add", "-A")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
