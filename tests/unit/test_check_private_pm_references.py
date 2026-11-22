"""scripts/check_private_pm_references.py holds the private-reference count down.

The lint is a per-file ratchet over references to the private
project-management repository: a file's count may fall but never rise, a file
not on the baseline must carry none, and a fallen count rewrites the baseline
smaller. These cases pin each of those rules, the documented blind spot (a
reference moving within one file), and the refusals that keep a failed or
empty scan from reading as "everything was cleaned".

Each case runs the real script with real python and git in a scratch git
repository that holds a copy of it under scripts/. The scratch repository
stands in for this checkout because the cases need files that this checkout
must not carry: new references, ignored and untracked files that carry one,
and a baseline written for the scratch tree. Nothing is mocked. The scratch
tree is a handful of files, so every run passes `--tracked-file-floor 1`
except the one case that tests the floor itself.
"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_private_pm_references.py"
GIT = shutil.which("git")
# Assembled from two parts so that this file, which is tracked, does not
# itself carry a reference to the real gate.
NAME = "reprobuild" + "-pm"
BASELINE_NAME = "private-pm-references-baseline.tsv"


class PrivatePmReferenceRatchet(unittest.TestCase):
    def setUp(self):
        # Never a silent pass: without git these cases say nothing.
        self.assertIsNotNone(GIT, "git is not on PATH")
        self.repo = Path(tempfile.mkdtemp(prefix="private-pm-ref-gate-"))
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        self.git("init", "-q")
        (self.repo / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.repo / "scripts" / SCRIPT.name)
        (self.repo / ".gitignore").write_text("build/\n")
        (self.repo / "src").mkdir()
        self.write("src/clean.nim", "discard\n")
        self.write("src/debt.nim", f"# see {NAME} issue A\n# and {NAME} spec B\n")
        self.git("add", "-A")
        result = self.run_gate("--write-baseline")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.baseline_rows(), {"src/debt.nim": 2})

    # -- helpers ----------------------------------------------------------

    def git(self, *args):
        subprocess.run(
            [GIT, "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_gate(self, *args, floor=True):
        extra = ["--tracked-file-floor", "1"] if floor else []
        return subprocess.run(
            [sys.executable, str(self.repo / "scripts" / SCRIPT.name), *extra, *args],
            cwd=self.repo,
            capture_output=True,
            text=True,
        )

    def baseline_rows(self):
        rows = {}
        text = (self.repo / "scripts" / BASELINE_NAME).read_text()
        for line in text.splitlines():
            if line and not line.startswith("#"):
                path, count = line.split("\t")
                rows[path] = int(count)
        return rows

    # -- the ratchet ------------------------------------------------------

    def test_the_recorded_tree_passes(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 reference(s) in 1 file(s), all baselined", result.stdout)

    def test_a_reference_in_a_file_not_on_the_baseline_is_refused(self):
        self.write("src/new.nim", f"# per the {NAME} plan\n")
        self.git("add", "src/new.nim")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("src/new.nim", result.stderr)
        self.assertIn("file not on the baseline", result.stderr)
        # The matching line is shown, with its number.
        self.assertIn(f"1:# per the {NAME} plan", result.stderr)

    def test_a_second_reference_on_an_existing_line_is_refused(self):
        # Occurrences, not lines: the line count does not change here.
        self.write("src/debt.nim", f"# see {NAME} issue A, {NAME} issue C\n# and {NAME} spec B\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("src/debt.nim  [2 -> 3 references]", result.stderr)

    def test_the_match_is_case_insensitive(self):
        self.write("src/new.nim", "# " + NAME.upper() + " says so\n")
        self.git("add", "src/new.nim")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("src/new.nim", result.stderr)

    def test_a_removed_reference_passes_and_shrinks_the_baseline(self):
        self.write("src/debt.nim", f"# see {NAME} issue A\n# and the reason, in place\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("rewritten smaller", result.stdout)
        self.assertEqual(self.baseline_rows(), {"src/debt.nim": 1})

    def test_a_cleaned_file_is_dropped_from_the_baseline(self):
        self.write("src/debt.nim", "# the reason, in place\n")
        self.write("src/other.nim", f"# {NAME}\n")
        self.git("add", "-A")
        self.run_gate("--write-baseline")
        self.write("src/other.nim", "# cleaned\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.baseline_rows(), {})
        # And an empty baseline over a clean tree is the finish line, not an
        # error.
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("burn-down is complete", result.stdout)

    def test_a_new_reference_withholds_the_rewrite_of_a_shrunk_row(self):
        self.write("src/debt.nim", f"# see {NAME} issue A\n")
        self.write("src/new.nim", f"# {NAME}\n")
        self.git("add", "src/new.nim")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("NOT rewritten", result.stderr)
        self.assertEqual(self.baseline_rows(), {"src/debt.nim": 2})

    def test_a_reference_moving_within_a_file_is_not_reported(self):
        # The documented blind spot of a per-file count. Pinned so that it
        # cannot change without this test, and its header, changing too.
        self.write("src/debt.nim", f"discard\n# and {NAME} spec B\n# see {NAME} issue A\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # -- what is and is not scanned ---------------------------------------

    def test_ignored_and_untracked_files_are_not_judged(self):
        self.write("build/report.json", f"{NAME}\n")
        self.write("scratch.txt", f"{NAME}\n")  # untracked, not ignored
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_script_and_its_baseline_are_not_judged(self):
        # Both name the pattern or carry paths next to it; tracking them must
        # not count. The script copy names the pattern once by construction.
        self.git("add", "-A")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("scripts/", "".join(self.baseline_rows()))

    # -- refusals that keep a bad scan from passing -----------------------

    def test_a_missing_baseline_is_refused(self):
        (self.repo / "scripts" / BASELINE_NAME).unlink()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("missing baseline", result.stderr)

    def test_a_malformed_baseline_row_is_refused(self):
        path = self.repo / "scripts" / BASELINE_NAME
        path.write_text(path.read_text() + "src/x.nim\tnot-a-number\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("is not an integer", result.stderr)

    def test_a_corpus_below_the_floor_is_refused_before_the_baseline_is_touched(self):
        before = (self.repo / "scripts" / BASELINE_NAME).read_text()
        self.write("src/debt.nim", "# cleaned\n")
        result = self.run_gate(floor=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("floor", result.stderr)
        self.assertEqual((self.repo / "scripts" / BASELINE_NAME).read_text(), before)

    def test_outside_a_git_checkout_the_scan_fails_instead_of_passing(self):
        outside = Path(tempfile.mkdtemp(prefix="private-pm-ref-nogit-"))
        self.addCleanup(shutil.rmtree, outside, ignore_errors=True)
        (outside / "scripts").mkdir()
        shutil.copy2(SCRIPT, outside / "scripts" / SCRIPT.name)
        shutil.copy2(self.repo / "scripts" / BASELINE_NAME, outside / "scripts" / BASELINE_NAME)
        result = subprocess.run(
            [sys.executable, str(outside / "scripts" / SCRIPT.name), "--tracked-file-floor", "1"],
            cwd=outside,
            capture_output=True,
            text=True,
            env={"PATH": "/usr/bin:/bin:" + str(Path(GIT).parent), "GIT_CEILING_DIRECTORIES": str(outside.parent)},
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
