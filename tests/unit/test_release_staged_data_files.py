"""The run-time data files a release's source root must carry.

An installed reprobuild opens some files of its source root at RUN time, from
beside the stdlib recipe that names them: a tarball arm's `closureManifest`
and a nixPackage arm's `expressionFile` (with the Nix files that expression
imports). v0.2.26's Windows archive had none of them: its stager reached git
with a bare `git`, which failed on that leg with the error discarded, and fell
back to a directory walk that kept only compile inputs by extension. Every
consumer's Windows tarball provisioning of playwright then failed with
"closure manifest not found: ...closures/playwright-core-1.56.1-windows.manifest".

These cases stage this tree's real `libs/` and `lints/` with the real
scripts/release/stage_release_sources.sh, in each of the ways the release legs
reach it, and hand the result to scripts/release/check_release_data_files.sh,
which derives the files to expect from the staged recipes themselves.

What is not real, and why:

* The checkout is a temporary git repository holding a COPY of this tree's
  tracked `libs/`, `lints/`, `config.nims` and staging scripts. The stager
  must run from a checkout root, and the cases need checkouts with and without
  `.git`, and one git refuses as another user's; doing that to this checkout
  would disturb it.
* The source-only inputs and the reprobuild-packages catalog are small
  temporary trees holding only each input's marker file. The stager resolves
  them from environment variables first, as the dev shell sets them; their
  contents are not under test here (check_release_source_closure.sh covers
  them), and the real ones are not present on every host that runs this suite.
* "Not owned by the current user" is git's own GIT_TEST_ASSUME_DIFFERENT_OWNER
  (https://github.com/git/git/blob/master/setup.c, ensure_valid_ownership), as
  in test_release_git.py.

Nothing is mocked: real bash, git, find and tar stage the files.
"""

from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
STAGER = "scripts/release/stage_release_sources.sh"
CHECK = ROOT / "scripts" / "release" / "check_release_data_files.sh"
GIT = shutil.which("git")
BASH = shutil.which("bash")
# The manifest v0.2.26's Windows archive lacked.
PLAYWRIGHT_MANIFEST = (
    "share/repro/source/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/"
    "packages/closures/playwright-core-1.56.1-windows.manifest"
)
# The filter v0.2.26's fallback walk applied to the source root: compile
# inputs by extension. Used to rebuild that archive's source root for the
# check's negative control.
COMPILE_ONLY = re.compile(
    r"(\.(nim|nims|nimble|cfg|h|hpp|c|cc|cpp|inc|S|s|asm)$)|(^(LICENSE|COPYING))"
)
# <ENV_VAR>, the marker the stager probes for under it.
SOURCE_ONLY_INPUTS = [
    ("REPRO_TEST_ADAPTERS_SRC", "repro_test_adapters/test_runner.nim"),
    ("TEST_CERTIFICATES_TOOLS_SRC", "test_certificates.nim"),
    ("REPRO_CT_TEST_RUNNER_SRC",
     "libs/ct_incremental_adapter/src/ct_incremental_adapter.nim"),
    ("IO_MON_SRC", "io_mon.nim"),
    ("STACKABLE_HOOKS_SRC", "stackable_hooks.nim"),
    ("SHM_GSET_SRC", "shm_gset.nim"),
    ("SHM_QUEUE_SRC", "shm_queue.nim"),
    ("CLI_SPEC_SRC", "clispec.nim"),
    ("ENTRYPOINTS_SRC", "entrypoints.nim"),
    ("CONFUTILS_SRC", "confutils.nim"),
    ("RUNQUOTA_SRC", "libs/runquota_core/src/runquota_core.nim"),
    ("BEARSSL_SRC", "bearssl/abi/consttypes.nim"),
]
# No automatic gc or maintenance: a fixture commit adds a few thousand loose
# objects, enough for `git commit` to start a DETACHED `gc --auto`, which was
# still writing packs into .git/objects when the case's cleanup removed the
# directory ("Directory not empty").
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_COUNT": "2",
    "GIT_CONFIG_KEY_0": "gc.auto", "GIT_CONFIG_VALUE_0": "0",
    "GIT_CONFIG_KEY_1": "maintenance.auto", "GIT_CONFIG_VALUE_1": "false",
}


def _git(repo: Path, *args: str, **env: str) -> str:
    return subprocess.run(
        [GIT, "-C", str(repo), *args],
        check=True, capture_output=True, text=True,
        env=dict(os.environ, **GIT_ENV, **env),
    ).stdout.strip()


def _commit_all(repo: Path) -> str:
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
         "commit", "-q", "-m", "fixture")
    return _git(repo, "rev-parse", "HEAD")


def _tracked(rel_trees):
    out = subprocess.run(
        [GIT, "-C", str(ROOT), "ls-files", "-z", "--", *rel_trees],
        check=True, capture_output=True, env=dict(os.environ, **GIT_ENV),
    ).stdout.decode()
    return [f for f in out.split("\0") if f and (ROOT / f).is_file()]


@unittest.skipIf(os.name == "nt", "the stager is exercised from a POSIX bash here")
@unittest.skipIf(GIT is None or BASH is None, "needs git and bash on PATH")
class StagedDataFilesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="repro-test-staged-data-")
        cls.work = Path(cls._tmp.name)

        # The template checkout: this tree's source root and staging scripts.
        cls.template = cls.work / "template"
        files = _tracked(["libs", "lints", "config.nims", "scripts/release",
                          "scripts/lib"])
        for rel in files:
            dest = cls.template / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, dest)

        # The source-only inputs: each one's marker, nothing else.
        cls.inputs_env = {}
        for env_name, marker in SOURCE_ONLY_INPUTS:
            root = cls.work / "inputs" / env_name
            (root / marker).parent.mkdir(parents=True, exist_ok=True)
            (root / marker).write_text("# marker\n")
            cls.inputs_env[env_name] = str(root)

        # The catalog: a git repository at the commit repro.lock pins, with
        # one recipe naming a closure manifest of its own, as the real
        # catalog's npm packages do.
        catalog = cls.work / "catalog"
        recipe = catalog / "packages" / "interfaces" / "fixture-tool"
        (recipe / "closures").mkdir(parents=True)
        (recipe / "repro.nim").write_text(
            "package fixtureTool:\n"
            "  provisioning:\n"
            '    tarball url = "https://example.invalid/t.tgz",\n'
            '      closureManifest = "closures/fixture-tool.manifest",\n'
        )
        (recipe / "closures" / "fixture-tool.manifest").write_text("")
        _git(catalog, "init", "-q")
        pin = _commit_all(catalog)
        (cls.template / "repro.lock").write_text(
            f'deps = [{{ name = "reprobuild-packages", revision = "{pin}" }}]\n'
        )
        cls.inputs_env["REPROBUILD_PACKAGES_ROOT"] = str(catalog)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="case-", dir=self.work)
        self.addCleanup(tmp.cleanup)
        self.case = Path(tmp.name)
        self.pkg = self.case / "pkg"
        self.pkg.mkdir()

    def _checkout(self, git: bool) -> Path:
        checkout = self.case / "reprobuild"
        shutil.copytree(self.template, checkout, symlinks=True)
        if git:
            _git(checkout, "init", "-q")
            _commit_all(checkout)
        return checkout

    def _stage(self, checkout: Path, path=None, **env: str):
        full = dict(os.environ, **GIT_ENV, **self.inputs_env, **env)
        if path is not None:
            full["PATH"] = path
        return subprocess.run(
            [BASH, STAGER, str(self.pkg)], cwd=checkout,
            capture_output=True, text=True, env=full,
        )

    def _check(self, pkg: Path):
        return subprocess.run(
            [BASH, str(CHECK), str(pkg)], capture_output=True, text=True,
            env=dict(os.environ),
        )

    def _assert_carries_every_named_file(self, stage):
        self.assertEqual(stage.returncode, 0, stage.stdout + stage.stderr)
        self.assertTrue((self.pkg / PLAYWRIGHT_MANIFEST).is_file(),
                        "the playwright Windows closure manifest was not staged")
        check = self._check(self.pkg)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        # Derived, not listed: the playwright manifest, the catalog's, and
        # at least one Nix expression with the shared file it imports.
        self.assertIn("packages/closures/playwright-core-1.56.1-windows.manifest",
                      check.stdout)
        self.assertIn("closures/fixture-tool.manifest", check.stdout)
        self.assertRegex(check.stdout, r"ok\s+\S+/packages/nix/[^ ]+/default\.nix")
        self.assertRegex(check.stdout, r"ok\s+\S+/packages/nix/nixpkgs\.nix\s+\(imported by")
        self.assertNotIn("MISSING", check.stdout)

    def test_a_git_checkout_stages_every_named_file(self):
        stage = self._stage(self._checkout(git=True))
        self._assert_carries_every_named_file(stage)
        self.assertIn("source root <- the tracked files", stage.stdout)

    def test_a_tree_without_git_stages_every_named_file(self):
        # A source archive has no .git, so the stager walks the tree. Before
        # the fix that walk kept compile inputs only, which is the archive
        # v0.2.26's Windows leg shipped.
        stage = self._stage(self._checkout(git=False))
        self._assert_carries_every_named_file(stage)
        self.assertIn("(no .git here)", stage.stdout)

    def test_a_checkout_owned_by_another_user_is_still_read_with_git(self):
        checkout = self._checkout(git=True)
        # Negative control: plain git refuses it, as it did the bare `git`
        # the stager used to run.
        refused = subprocess.run(
            [GIT, "-C", str(checkout), "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True,
            env=dict(os.environ, **GIT_ENV, GIT_TEST_ASSUME_DIFFERENT_OWNER="1"),
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("dubious ownership", refused.stderr)

        stage = self._stage(checkout, GIT_TEST_ASSUME_DIFFERENT_OWNER="1")
        self._assert_carries_every_named_file(stage)
        self.assertIn("source root <- the tracked files", stage.stdout)

    def test_git_off_path_is_found_where_git_for_windows_keeps_it(self):
        checkout = self._checkout(git=True)
        # Every tool this process's PATH offers except git, as in Git for
        # Windows' bash on the release leg; git itself in a stand-in for
        # /cmd/git.
        shadow = self.case / "no-git-bin"
        shadow.mkdir()
        for directory in os.environ.get("PATH", "").split(os.pathsep):
            if not os.path.isdir(directory):
                continue
            for entry in os.listdir(directory):
                if entry == "git" or (shadow / entry).exists():
                    continue
                try:
                    (shadow / entry).symlink_to(os.path.join(directory, entry))
                except OSError:
                    pass
        cmd = self.case / "cmd"
        cmd.mkdir()
        (cmd / "git").symlink_to(GIT)
        bare = subprocess.run([BASH, "-c", "command -v git || true"],
                              capture_output=True, text=True,
                              env={"PATH": str(shadow)})
        self.assertEqual(bare.stdout.strip(), "", "the shadow PATH still has git")

        stage = self._stage(checkout, path=str(shadow),
                            REPRO_RELEASE_GIT_CANDIDATES=f"{cmd}/git")
        self._assert_carries_every_named_file(stage)
        self.assertIn("source root <- the tracked files", stage.stdout)

    def test_a_checkout_git_cannot_read_is_an_error_not_a_walk(self):
        checkout = self._checkout(git=True)
        # A .git that names no repository: git fails, and the stager must
        # say so rather than stage something else.
        shutil.rmtree(checkout / ".git")
        (checkout / ".git").write_text("gitdir: /nonexistent/repository\n")
        stage = self._stage(checkout)
        self.assertNotEqual(stage.returncode, 0, stage.stdout)
        self.assertIn("git cannot read the checkout", stage.stderr)

    def test_the_check_fails_the_source_root_v0_2_26_shipped(self):
        # Negative control for the check: this tree's source root filtered to
        # compile inputs, as v0.2.26's Windows fallback staged it.
        pkg = self.case / "v0226"
        source = pkg / "share" / "repro" / "source"
        for rel in _tracked(["libs", "lints"]):
            if "/tests/" in f"/{rel}/" or not COMPILE_ONLY.search(Path(rel).name):
                continue
            (source / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, source / rel)
        check = self._check(pkg)
        self.assertNotEqual(check.returncode, 0, check.stdout)
        self.assertIn("MISSING source/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/"
                      "packages/closures/playwright-core-1.56.1-windows.manifest",
                      check.stdout)
        self.assertIn("MISSING source/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/"
                      "packages/nix/go-1.25.4/default.nix", check.stdout)

    def _recipe_pkg(self, body: str) -> Path:
        pkg = self.case / "recipe"
        recipe = pkg / "share" / "repro" / "source" / "libs" / "r" / "src" / "r.nim"
        recipe.parent.mkdir(parents=True)
        recipe.write_text(body)
        return pkg

    def test_a_nix_import_the_tree_lacks_fails_the_check(self):
        pkg = self._recipe_pkg(
            "package p:\n  provisioning:\n"
            '    nixPackage "x", expressionFile = "nix/p/default.nix"\n')
        expr = pkg / "share/repro/source/libs/r/src/nix/p/default.nix"
        expr.parent.mkdir(parents=True)
        expr.write_text("# import ../ignored.nix in a comment\n"
                        "{ pkgs ? import ../shared.nix }: pkgs.hello\n")
        check = self._check(pkg)
        self.assertNotEqual(check.returncode, 0, check.stdout)
        self.assertIn("MISSING source/libs/r/src/nix/shared.nix", check.stdout)
        self.assertNotIn("ignored.nix", check.stdout)
        (expr.parent.parent / "shared.nix").write_text("{}\n")
        check = self._check(pkg)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_a_constant_on_the_next_line_is_resolved(self):
        pkg = self._recipe_pkg(
            "const\n  Manifest* =\n    \"closures/m.manifest\"\n    ## doc\n"
            "package p:\n  provisioning:\n"
            "    tarball url = \"u\", closureManifest = Manifest\n")
        (pkg / "share/repro/source/libs/r/src/closures").mkdir()
        (pkg / "share/repro/source/libs/r/src/closures/m.manifest").write_text("")
        check = self._check(pkg)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        self.assertIn("ok      source/libs/r/src/closures/m.manifest", check.stdout)

    def test_a_reference_the_check_cannot_resolve_fails_it(self):
        pkg = self._recipe_pkg(
            "package p:\n  provisioning:\n"
            "    tarball url = \"u\", closureManifest = manifestFor(\"p\")\n")
        check = self._check(pkg)
        self.assertNotEqual(check.returncode, 0, check.stdout)
        self.assertIn("extend check_release_data_files", check.stderr)

    def test_a_tree_with_no_reference_at_all_fails_the_check(self):
        # Positive control: the scan that finds nothing did not run.
        pkg = self._recipe_pkg("package p:\n  discard\n")
        check = self._check(pkg)
        self.assertNotEqual(check.returncode, 0, check.stdout)
        self.assertIn("no closureManifest/expressionFile reference", check.stderr)


if __name__ == "__main__":
    unittest.main()
