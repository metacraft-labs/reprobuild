"""Tests for scripts/lib/release_git.sh, the git the release staging scripts use.

The Windows release leg runs the staging scripts in Git for Windows' bash,
where Git may be absent from PATH and the runner's service account may not
own the sibling checkouts. v0.2.8 (run 37941621127) failed catalog staging on the
first, and v0.2.14 (run 39794420520) failed the runquota staging with "does
not have <rev>" after that script discarded Git's error. The latter log did
not distinguish its actual cause. These tests independently reproduce the
missing-PATH and ownership failure modes; they do not attribute that run.

No Windows host is needed to exercise either trap:

* "git is not on PATH" is reproduced with a PATH holding only bash and
  coreutils, and the Git for Windows locations are replaced by a temporary
  directory through REPRO_RELEASE_GIT_CANDIDATES (the helper's documented
  seam; the release legs never set it).
* "not owned by the current user" is reproduced with git's own
  GIT_TEST_ASSUME_DIFFERENT_OWNER, which makes git's ownership check treat
  every repository as foreign
  (https://github.com/git/git/blob/master/setup.c, ensure_valid_ownership).

Both use a real git and a real repository; nothing is mocked.
"""

from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts" / "lib" / "release_git.sh"
STAGING_SCRIPTS = [
    ROOT / "scripts" / "release" / "stage_release_catalog.sh",
    ROOT / "scripts" / "release" / "stage_release_runquota.sh",
]
GIT = shutil.which("git")
BASH = shutil.which("bash")


def _git(repo: Path, *args: str) -> str:
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run(
        [GIT, "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    ).stdout.strip()


@unittest.skipIf(os.name == "nt", "the helper is exercised from a POSIX bash here")
@unittest.skipIf(GIT is None or BASH is None, "needs git and bash on PATH")
class ReleaseGitTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="repro-test-release-git-")
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        self.repo = self.work / "sibling"
        self.repo.mkdir()
        _git(self.repo, "init", "-q")
        (self.repo / "payload.txt").write_text("pinned\n")
        _git(self.repo, "add", "payload.txt")
        _git(
            self.repo,
            "-c", "user.name=t", "-c", "user.email=t@example.invalid",
            "commit", "-q", "-m", "pin",
        )
        self.rev = _git(self.repo, "rev-parse", "HEAD")

        # A PATH with bash and coreutils but no git: what Git for Windows'
        # bash sees on the release leg.
        self.no_git_bin = self.work / "no-git-bin"
        self.no_git_bin.mkdir()
        for tool in ("bash", "cat", "dirname", "env"):
            found = shutil.which(tool)
            self.assertIsNotNone(found, tool)
            (self.no_git_bin / tool).symlink_to(found)
        # Stands in for /cmd/git: a directory holding the real git.
        self.git_for_windows = self.work / "cmd"
        self.git_for_windows.mkdir()
        (self.git_for_windows / "git").symlink_to(GIT)

    def _run(self, body: str, path: str, **extra_env: str):
        env = {
            "PATH": path,
            "HOME": str(self.work),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        env.update(extra_env)
        script = f'set -euo pipefail\n. "{HELPER}"\n{body}\n'
        return subprocess.run(
            [BASH, "-c", script], capture_output=True, text=True, env=env
        )

    def _cat_file(self) -> str:
        return (
            "release_git_init test\n"
            f'release_git -C "{self.repo}" cat-file -e "{self.rev}^{{commit}}"\n'
            'echo "resolved=$RELEASE_GIT_BIN"'
        )

    def test_git_on_path_is_used(self):
        result = self._run(self._cat_file(), os.environ["PATH"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("resolved=", result.stdout)
        self.assertNotIn(str(self.git_for_windows), result.stdout)

    def test_git_for_windows_location_is_used_when_path_lacks_git(self):
        # Negative control: the bare `git` the runquota staging used to run
        # is not found on this PATH.
        bare = subprocess.run(
            [BASH, "-c", f'git -C "{self.repo}" cat-file -e "{self.rev}^{{commit}}"'],
            capture_output=True, text=True, env={"PATH": str(self.no_git_bin)},
        )
        self.assertEqual(bare.returncode, 127, bare.stderr)

        result = self._run(
            self._cat_file(),
            str(self.no_git_bin),
            REPRO_RELEASE_GIT_CANDIDATES=f"{self.work}/absent/git {self.git_for_windows}/git",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"resolved={self.git_for_windows}/git", result.stdout)

    def test_missing_git_names_every_location_it_tried(self):
        result = self._run(
            self._cat_file(),
            str(self.no_git_bin),
            REPRO_RELEASE_GIT_CANDIDATES=f"{self.work}/a/git {self.work}/b/git",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("test: ERROR: git is not on PATH", result.stderr)
        self.assertIn(f"{self.work}/a/git, {self.work}/b/git", result.stderr)
        self.assertNotIn("resolved=", result.stdout)

    def test_checkout_owned_by_another_user_is_still_read(self):
        # Negative control: plain git refuses the checkout once it is treated
        # as another user's, so this case really exercises the ownership check.
        refused = subprocess.run(
            [GIT, "-C", str(self.repo), "cat-file", "-e", f"{self.rev}^{{commit}}"],
            capture_output=True, text=True,
            env=dict(
                os.environ,
                GIT_TEST_ASSUME_DIFFERENT_OWNER="1",
                GIT_CONFIG_GLOBAL=os.devnull,
                GIT_CONFIG_NOSYSTEM="1",
            ),
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("dubious ownership", refused.stderr)

        result = self._run(
            self._cat_file()
            + f'\nrelease_git -C "{self.repo}" archive --format=tar "{self.rev}" | cat >/dev/null',
            os.environ["PATH"],
            GIT_TEST_ASSUME_DIFFERENT_OWNER="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_staging_scripts_run_git_only_through_the_helper(self):
        # A bare `git` in a staging script is the defect this helper exists
        # to prevent; comments and quoted remedies ("run: git -C ...") are
        # not calls.
        call = re.compile(r"(^|[;&|(]|\$\()\s*git\s")
        for script in STAGING_SCRIPTS:
            text = script.read_text()
            self.assertIn("lib/release_git.sh", text, script.name)
            self.assertIn("release_git_init", text, script.name)
            for number, line in enumerate(text.splitlines(), 1):
                code = line.split("#", 1)[0]
                code = re.sub(r'"[^"]*"', '""', code)
                self.assertIsNone(
                    call.search(code), f"{script.name}:{number}: bare git: {line.strip()}"
                )


if __name__ == "__main__":
    unittest.main()
