"""The release catalog probe's verdict does not depend on where TMPDIR is.

check_release_source_closure.sh proves that a recipe using a package which
moved to reprobuild-packages compiles against a release archive alone, from
the archive's own share/repro/reprobuild-packages. The lookup it exercises
(`reprobuildPackagesSearch`) prefers a reprobuild-packages checkout beside the
consumer or an ancestor of it, and the probe's consumer is a file in its
scratch directory. With TMPDIR beside such a checkout -- the layout
stage_release_catalog.sh asks for ("clone it at ../reprobuild-packages") --
`just lint` failed with "its share/repro/reprobuild-packages catalog is
missing or not where the lookup looks" while the archive's catalog was
present: the probe had resolved the package from that checkout instead.

The first class drives scripts/lib/catalog_free_scratch.sh, which chooses the
probe's scratch directory, against real directory trees. The second stages a
real archive with scripts/release/stage_release_sources.sh, exactly as
scripts/release/check_staged_release_sources.sh does, and runs the real
check_release_source_closure.sh on it with TMPDIR beside a reprobuild-packages
checkout. That case needs what the lint step needs: `nim` on PATH and the
staging inputs resolvable (the dev shell's `*_SRC` variables or the sibling
checkouts). It takes a few minutes.

What is not real, and why: the reprobuild-packages checkout beside TMPDIR is
a directory holding a copy of the staged catalog's sqlite3 interface, not a
git clone. The lookup selects an unpinned sibling by the directory existing
and resolves the interface by its file; neither reads git. Nothing is mocked:
real bash, mktemp, nim and the real scripts run.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts" / "lib" / "catalog_free_scratch.sh"
STAGER = ROOT / "scripts" / "release" / "stage_release_sources.sh"
CLOSURE = ROOT / "scripts" / "release" / "check_release_source_closure.sh"
BASH = shutil.which("bash")
NIM = shutil.which("nim")


def helper(*args, env=None):
    """Run ``catalog_free_scratch <args>`` from the sourced helper."""
    script = '. "$1"; shift; catalog_free_scratch "$@"'
    return subprocess.run([BASH, "-c", script, "bash", str(HELPER), *args],
                          capture_output=True, text=True, env=env)


@unittest.skipIf(os.name == "nt", "the helper is exercised from a POSIX bash here")
@unittest.skipIf(BASH is None, "needs bash on PATH")
class CatalogFreeScratchTests(unittest.TestCase):
    def setUp(self):
        self.top = Path(tempfile.mkdtemp(prefix="catalog-scratch-")).resolve()
        self.addCleanup(shutil.rmtree, self.top, ignore_errors=True)
        # The issue's layout: <scratch>/tmp beside <scratch>/reprobuild-packages.
        self.beside = self.top / "beside"
        (self.beside / "reprobuild-packages" / "packages" / "interfaces").mkdir(parents=True)
        self.dirty = self.beside / "tmp"
        self.dirty.mkdir()
        self.clean = self.top / "clean" / "tmp"
        self.clean.mkdir(parents=True)

    def created(self, run):
        self.assertEqual(run.returncode, 0, run.stderr)
        path = Path(run.stdout.strip())
        self.assertTrue(path.is_dir(), run.stdout)
        return path

    def test_a_clean_tmpdir_is_used(self):
        path = self.created(helper("probe-XXXXXX", str(self.clean), str(self.dirty)))
        self.assertEqual(path.parent, self.clean)

    def test_a_tmpdir_beside_a_checkout_is_passed_over(self):
        path = self.created(helper("probe-XXXXXX", str(self.dirty), str(self.clean)))
        self.assertEqual(path.parent, self.clean)
        self.assertEqual(list(self.dirty.iterdir()), [])

    def test_a_checkout_beside_a_farther_ancestor_is_found(self):
        deep = self.dirty / "a" / "b"
        deep.mkdir(parents=True)
        run = helper("probe-XXXXXX", str(deep))
        self.assertEqual(run.returncode, 1)
        self.assertIn(str(self.beside / "reprobuild-packages"), run.stderr)

    def test_a_lock_naming_the_catalog_above_is_found(self):
        locked = self.top / "locked"
        (locked / "tmp").mkdir(parents=True)
        (locked / "repro.lock").write_text(
            '{ name = "reprobuild-packages", revision = "' + "0" * 40 + '" }\n')
        run = helper("probe-XXXXXX", str(locked / "tmp"))
        self.assertEqual(run.returncode, 1)
        self.assertIn(str(locked / "repro.lock"), run.stderr)

    def test_a_symlink_into_a_dirty_tree_is_judged_by_its_target(self):
        link = self.top / "clean" / "link"
        link.symlink_to(self.dirty)
        run = helper("probe-XXXXXX", str(link))
        self.assertEqual(run.returncode, 1)
        self.assertIn(str(self.beside / "reprobuild-packages"), run.stderr)

    def test_no_clean_parent_refuses_naming_each_finding_and_creates_nothing(self):
        other = self.top / "other"
        (other / "reprobuild-packages").mkdir(parents=True)
        (other / "tmp").mkdir()
        run = helper("probe-XXXXXX", str(self.dirty), str(other / "tmp"))
        self.assertEqual(run.returncode, 1)
        self.assertEqual(run.stdout, "")
        self.assertIn(str(self.beside / "reprobuild-packages"), run.stderr)
        self.assertIn(str(other / "reprobuild-packages"), run.stderr)
        self.assertIn("TMPDIR", run.stderr)
        self.assertEqual(list(self.dirty.iterdir()), [])
        self.assertEqual(list((other / "tmp").iterdir()), [])


@unittest.skipIf(os.name == "nt", "the closure check is exercised from a POSIX bash here")
@unittest.skipIf(BASH is None or NIM is None, "needs bash and nim on PATH (the dev shell provides them)")
class ClosureCheckWithTmpdirBesideACheckoutTests(unittest.TestCase):
    def test_the_verdict_does_not_depend_on_tmpdir(self):
        top = Path(tempfile.mkdtemp(prefix="closure-tmpdir-")).resolve()
        self.addCleanup(shutil.rmtree, top, ignore_errors=True)
        # Staged copies of store paths can be read-only.
        self.addCleanup(subprocess.run, ["chmod", "-R", "u+w", str(top)],
                        capture_output=True)
        pkg = top / "pkg"
        pkg.mkdir()
        stage = subprocess.run([BASH, str(STAGER), str(pkg)], cwd=ROOT,
                               capture_output=True, text=True)
        self.assertEqual(stage.returncode, 0, stage.stdout + stage.stderr)
        catalog = pkg / "share" / "repro" / "reprobuild-packages"
        sqlite3 = catalog / "packages" / "interfaces" / "sqlite3"
        self.assertTrue((sqlite3 / "repro.nim").is_file(), "the stager staged no catalog")

        # A reprobuild-packages checkout beside TMPDIR that also defines
        # sqlite3, so a lookup that reaches it resolves from it.
        sibling = top / "beside" / "reprobuild-packages" / "packages" / "interfaces"
        shutil.copytree(sqlite3, sibling / "sqlite3")
        tmpdir = top / "beside" / "tmp"
        tmpdir.mkdir()

        env = dict(os.environ, TMPDIR=str(tmpdir))
        env.pop("REPROBUILD_PACKAGES_ROOT", None)
        check = subprocess.run([BASH, str(CLOSURE), str(pkg)], cwd=ROOT, env=env,
                               capture_output=True, text=True)
        output = check.stdout + check.stderr
        self.assertNotIn("catalog is missing", output)
        self.assertEqual(check.returncode, 0, output)
        self.assertIn("catalog OK: the moved package resolved from the archive's own catalog",
                      check.stdout)
        # The check cleaned up after itself, under TMPDIR and elsewhere.
        self.assertEqual(list(tmpdir.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
