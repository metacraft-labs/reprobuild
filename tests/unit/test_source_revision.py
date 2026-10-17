"""`scripts/source_revision.sh` is the one derivation of an image's revision.

Both build routes for the engine -- `scripts/build_apps.sh` and the
`reprobuild.apps.reprobuild` edge in `repro.nim` (through the
`reprobuild.apps.source-revision` probe edge) -- embed what this script
reports as `ReprobuildSourceRevision`. The graph route used to read only
`$REPROBUILD_SOURCE_REVISION`, at recipe evaluation, so the engine
`repro build` produced carried no revision and the export provenance gate
(`tests/e2e/m83/t_e2e_home_export_matches_compiled_intent.nim`) failed on the
suite's own route.

These cases pin the script's contract against real git repositories in a
temporary directory: the env override wins, a clean tree reports HEAD, a
change to a tracked file appends `-dirty` (an untracked file does not), a
directory that is not the top level of a work tree reports nothing, a refused
character fails, and the generated Nim module is exactly the revision and is
left untouched while the revision is unchanged. Two source checks keep the
two routes from growing a second derivation again.

No mocks: the real script runs under the real bash against real git.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "source_revision.sh"
ENV_NAME = "REPROBUILD_SOURCE_REVISION"


class SourceRevisionScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="repro-source-rev-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.tree = self.base / "tree"
        self.tree.mkdir()
        self.bash = shutil.which("bash")
        self.assertIsNotNone(self.bash, "bash is required by this script test")
        self.assertIsNotNone(shutil.which("git"), "git is required by this test")
        # The caller's environment may carry the override (the release
        # workflow sets it job-wide), and the caller's git configuration may
        # sign commits or run hooks. Neither belongs in these cases.
        self.env = {k: v for k, v in os.environ.items() if k != ENV_NAME}
        self.env["HOME"] = str(self.base)
        self.env["GIT_CONFIG_NOSYSTEM"] = "1"
        self.env["GIT_CONFIG_GLOBAL"] = os.devnull

    def git(self, *arguments, cwd=None):
        result = subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
             "-c", "commit.gpgsign=false", *arguments],
            cwd=cwd or self.tree, env=self.env, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.stdout.decode("ascii").strip()

    def commit_tree(self):
        self.git("init", "-q")
        (self.tree / "tracked.txt").write_text("one\n", encoding="ascii")
        self.git("add", "tracked.txt")
        self.git("commit", "-q", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def run_script(self, *arguments, tree=None, env=None):
        return subprocess.run(
            [self.bash, str(SCRIPT), "--tree", str(tree or self.tree),
             *arguments],
            env=env or self.env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE)

    def revision(self, **kwargs):
        result = self.run_script(**kwargs)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.decode("ascii")

    def test_clean_tree_reports_head(self):
        head = self.commit_tree()
        self.assertEqual(len(head), 40)
        self.assertEqual(self.revision(), head + "\n")

    def test_modified_tracked_file_is_dirty(self):
        head = self.commit_tree()
        (self.tree / "tracked.txt").write_text("two\n", encoding="ascii")
        self.assertEqual(self.revision(), head + "-dirty\n")

    def test_staged_change_is_dirty(self):
        head = self.commit_tree()
        (self.tree / "tracked.txt").write_text("two\n", encoding="ascii")
        self.git("add", "tracked.txt")
        self.assertEqual(self.revision(), head + "-dirty\n")

    def test_untracked_file_is_not_dirty(self):
        head = self.commit_tree()
        (self.tree / "untracked.txt").write_text("new\n", encoding="ascii")
        self.assertEqual(self.revision(), head + "\n")

    def test_env_override_wins_over_git(self):
        self.commit_tree()
        env = dict(self.env, **{ENV_NAME: "0123abcd-dirty"})
        self.assertEqual(self.revision(env=env), "0123abcd-dirty\n")

    def test_env_override_outside_git(self):
        env = dict(self.env, **{ENV_NAME: "v1.2.3+build.4"})
        self.assertEqual(self.revision(env=env), "v1.2.3+build.4\n")

    def test_empty_env_override_falls_back_to_git(self):
        head = self.commit_tree()
        env = dict(self.env, **{ENV_NAME: ""})
        self.assertEqual(self.revision(env=env), head + "\n")

    def test_non_repository_reports_nothing(self):
        self.assertEqual(self.revision(), "")

    def test_subdirectory_of_another_repository_reports_nothing(self):
        # A source tree that merely sits inside some other repository must
        # not borrow that repository's commit.
        self.commit_tree()
        nested = self.tree / "vendored"
        nested.mkdir()
        self.assertEqual(self.revision(tree=nested), "")

    def test_refused_characters_fail(self):
        for bad in ('abc"def', "abc def", "abc\\def", "abc$(x)", "abc\ndef"):
            with self.subTest(revision=bad):
                env = dict(self.env, **{ENV_NAME: bad})
                module = self.base / "generated" / "rev.nim"
                result = self.run_script("--nim-module", str(module), env=env)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertFalse(module.exists())
                printed = self.run_script(env=env)
                self.assertEqual(printed.returncode, 3, printed.stderr)
                self.assertEqual(printed.stdout, b"")

    def test_unknown_argument_is_a_usage_error(self):
        result = self.run_script("--bogus")
        self.assertEqual(result.returncode, 2)

    def nim_module(self, env=None):
        module = self.base / "generated" / "source-revision" / "rev.nim"
        result = self.run_script("--nim-module", str(module), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        return module.read_bytes()

    def test_nim_module_declares_the_revision(self):
        head = self.commit_tree()
        (self.tree / "tracked.txt").write_text("two\n", encoding="ascii")
        expected = (
            "# Generated by scripts/source_revision.sh -- do not edit.\n"
            'const reprobuildGeneratedSourceRevision* = "'
            + head + '-dirty"\n').encode("ascii")
        self.assertEqual(self.nim_module(), expected)
        # Deterministic: an unchanged revision yields identical bytes.
        self.assertEqual(self.nim_module(), expected)

    def test_nim_module_is_left_alone_when_the_revision_is_unchanged(self):
        # Identical bytes are not enough: the engine edge revalidates its
        # recorded inputs by timestamp metadata first, so rewriting the same
        # bytes made the engine miss on every `repro build`
        # (t_b1_apps_action_cache_hit). The module may change on disk only
        # when the revision does.
        self.commit_tree()
        first = self.nim_module()
        module = self.base / "generated" / "source-revision" / "rev.nim"
        past = module.stat().st_mtime_ns - 10_000_000_000
        os.utime(module, ns=(past, past))
        before = module.stat()
        self.assertEqual(self.nim_module(), first)
        after = module.stat()
        self.assertEqual(after.st_mtime_ns, past)
        self.assertEqual(after.st_ino, before.st_ino)
        # A real change -- the tree turning dirty -- still rewrites it.
        (self.tree / "tracked.txt").write_text("two\n", encoding="ascii")
        self.assertNotEqual(self.nim_module(), first)
        self.assertNotEqual(module.stat().st_mtime_ns, past)

    def test_nim_module_with_other_content_is_rewritten(self):
        head = self.commit_tree()
        module = self.base / "generated" / "source-revision" / "rev.nim"
        module.parent.mkdir(parents=True)
        module.write_bytes(b"const reprobuildGeneratedSourceRevision* = \"\"\n")
        self.assertIn(head.encode("ascii"), self.nim_module())

    def test_nim_module_for_unknown_revision_is_empty_string(self):
        self.assertEqual(
            self.nim_module(),
            b"# Generated by scripts/source_revision.sh -- do not edit.\n"
            b'const reprobuildGeneratedSourceRevision* = ""\n')

    def test_default_tree_is_this_repository(self):
        # Run without --tree, from an unrelated directory: the script asks
        # about the repository it lives in, not the caller's cwd.
        result = subprocess.run(
            [self.bash, str(SCRIPT)], cwd=self.base, env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        explicit = self.run_script(tree=ROOT)
        self.assertEqual(result.stdout, explicit.stdout)


class SingleDerivationTests(unittest.TestCase):
    """Neither build route may grow its own derivation again."""

    def test_build_apps_delegates_to_the_script(self):
        text = (ROOT / "scripts" / "build_apps.sh").read_text(encoding="utf-8")
        # assertTrue rather than assertIn: the latter prints the whole file.
        self.assertTrue("bash scripts/source_revision.sh" in text,
                        "build_apps.sh does not call scripts/source_revision.sh")
        self.assertFalse("git rev-parse HEAD" in text,
                         "build_apps.sh derives the revision itself again")

    def test_repro_nim_does_not_read_the_revision_at_evaluation(self):
        # A `getEnv` at recipe evaluation is snapshotted by the provider and
        # served stale to later builds (idiomatic-reprobuild.md §4.4).
        text = (ROOT / "repro.nim").read_text(encoding="utf-8")
        self.assertFalse('getEnv("REPROBUILD_SOURCE_REVISION")' in text,
                         "repro.nim reads the revision at recipe evaluation")
        self.assertTrue("scripts/source_revision.sh --nim-module" in text,
                        "repro.nim has no source-revision probe edge")


if __name__ == "__main__":
    unittest.main()
