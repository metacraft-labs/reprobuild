"""The release publishes only while its tag still names the commit it built.

v0.2.24's assets were built from 7c670d248 (run 43218423379, attempt 2), but
42 seconds after that attempt started the tag was moved to 8cd4a5051e, 73
commits later, and the run published its 7c670d248 assets under a tag naming
8cd4a5051e. A consumer who checked a fix by ancestry against the tag was told
v0.2.24 carried fixes its assets did not.

These tests recreate that: a real bare "origin" repository, a tag pushed at the
commit a run "built", then moved to a later commit, and the guard
(scripts/release/assert_tag_names_commit.sh) asked about it the way the
release workflow's publish job asks -- by running the `run:` line of the
workflow's own steps in a clone whose origin is that repository, with the
GitHub-provided values in the environment.

Nothing is mocked: real git, a real repository on the filesystem as the
remote, and the workflow text as it is checked in. Only GitHub itself is
absent, and the guard talks to the remote through `git ls-remote`, which
behaves the same against a local path as against github.com.
"""

from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "scripts" / "release" / "assert_tag_names_commit.sh"
RELEASE_YML = ROOT / ".github" / "workflows" / "release.yml"
GIT = shutil.which("git")
BASH = shutil.which("bash")

BEFORE_STEP = "Refuse if the tag no longer names this build (before upload)"
AFTER_STEP = "Refuse if the tag no longer names this build (after publishing)"
HIDE_STEP = "Hide the release again, its tag moved while it was publishing"
TAG = "v0.2.24"


def _env():
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    env.update(
        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
    )
    return env


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        [GIT, "-C", str(repo), *args],
        check=True, capture_output=True, text=True, env=_env(),
    ).stdout.strip()


def _publish_job_steps():
    """Return [(name, step_text)] for the steps of the `publish-release` job.

    A deliberately small reader of the checked-in workflow: it splits the job
    at its `      - ` step markers. The repository's lint runs actionlint over
    the same file, so a structurally broken workflow cannot reach this test.
    """
    text = RELEASE_YML.read_text(encoding="utf-8")
    start = text.index("\n  publish-release:\n")
    rest = text[start + 1:]
    nxt = re.search(r"\n  [A-Za-z0-9_-]+:\n", rest[len("  publish-release:\n"):])
    job = rest if nxt is None else rest[: len("  publish-release:\n") + nxt.start() + 1]
    chunks = re.split(r"\n(?=      - )", job)
    steps = []
    for chunk in chunks[1:]:
        m = re.search(r"^      - (?:name: (.+)|uses: (.+))$", chunk, re.M)
        if not m:
            continue
        steps.append(((m.group(1) or m.group(2)).strip(), chunk))
    return steps


def _run_line(step_text: str) -> str:
    m = re.search(r"^        run: (.+)$", step_text, re.M)
    if m is None:
        raise AssertionError(f"step has no single-line run:\n{step_text}")
    return m.group(1)


@unittest.skipIf(os.name == "nt", "the guard runs in the Linux publish job")
@unittest.skipIf(GIT is None or BASH is None, "needs git and bash on PATH")
class TagNamesBuildTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="repro-test-release-tag-")
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        self.origin = self.work / "origin.git"
        self.dev = self.work / "dev"
        subprocess.run([GIT, "init", "-q", "--bare", str(self.origin)],
                       check=True, env=_env())
        subprocess.run([GIT, "init", "-q", str(self.dev)], check=True, env=_env())
        _git(self.dev, "commit", "-q", "--allow-empty", "-m", "release: 0.2.24")
        self.built = _git(self.dev, "rev-parse", "HEAD")
        _git(self.dev, "commit", "-q", "--allow-empty", "-m",
             "ci(release): raise the Linux release job cap")
        self.later = _git(self.dev, "rev-parse", "HEAD")
        _git(self.dev, "remote", "add", "origin", str(self.origin))
        _git(self.dev, "push", "-q", "origin", "HEAD:refs/heads/dev")

    # -- helpers ---------------------------------------------------------

    def tag(self, commit: str, annotated: bool = False, name: str = TAG):
        if annotated:
            _git(self.dev, "tag", "-f", "-a", "-m", name, name, commit)
        else:
            _git(self.dev, "tag", "-f", name, commit)
        _git(self.dev, "push", "-q", "-f", "origin", f"refs/tags/{name}")

    def guard(self, *args: str, remote=None):
        return subprocess.run(
            [BASH, str(GUARD), str(remote or self.origin), *args],
            capture_output=True, text=True, env=_env(),
        )

    def run_step(self, step_name: str, built: str):
        """Run a publish-job step's `run:` line as the runner would.

        The runner's checkout is a clone of origin taken when the run started
        (actions/checkout), so its own tag ref still names the built commit
        whatever happened on the remote since. The step must ask the remote.
        """
        steps = dict(_publish_job_steps())
        self.assertIn(step_name, steps, f"publish-release has no step '{step_name}'")
        checkout = self.work / "runner"
        if not checkout.exists():
            subprocess.run([GIT, "clone", "-q", str(self.origin), str(checkout)],
                           check=True, env=_env())
            (checkout / "scripts" / "release").mkdir(parents=True)
            shutil.copy2(GUARD, checkout / "scripts" / "release" / GUARD.name)
        env = _env()
        env.update(TAG=TAG, BUILT_COMMIT=built, GITHUB_SHA=built,
                   GITHUB_REF_NAME=TAG)
        return subprocess.run(
            [BASH, "-e", "-c", _run_line(steps[step_name])],
            cwd=checkout, capture_output=True, text=True, env=env,
        )

    # -- the guard -------------------------------------------------------

    def test_tag_that_still_names_the_built_commit_passes(self):
        self.tag(self.built)
        r = self.guard(TAG, self.built)
        self.assertEqual(0, r.returncode, r.stderr)

    def test_annotated_tag_is_compared_by_the_commit_it_peels_to(self):
        self.tag(self.built, annotated=True)
        r = self.guard(TAG, self.built)
        self.assertEqual(0, r.returncode, r.stderr)
        tag_object = _git(self.dev, "rev-parse", f"refs/tags/{TAG}")
        self.assertNotEqual(tag_object, self.built)
        r = self.guard(TAG, tag_object)
        self.assertEqual(0, r.returncode, r.stderr)

    def test_tag_moved_after_the_run_started_is_refused(self):
        # The v0.2.24 sequence: the run starts on `built`, then the tag moves.
        self.tag(self.built)
        self.tag(self.later)
        r = self.guard(TAG, self.built)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)
        self.assertIn(self.later, r.stderr)
        self.assertIn(self.built, r.stderr)

    def test_annotated_tag_moved_to_another_commit_is_refused(self):
        self.tag(self.built, annotated=True)
        self.tag(self.later, annotated=True)
        r = self.guard(TAG, self.built)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)

    def test_deleted_tag_is_refused(self):
        self.tag(self.built)
        _git(self.dev, "push", "-q", "origin", f":refs/tags/{TAG}")
        r = self.guard(TAG, self.built)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)
        self.assertIn("no longer exists", r.stderr)

    def test_a_tag_that_only_ends_in_the_same_name_does_not_vouch(self):
        # `git ls-remote origin refs/tags/v0.2.24` also lists
        # refs/tags/x/refs/tags/v0.2.24: it matches the pattern against ref
        # tails that start at a `/`. That tag names the built commit; the
        # real tag does not.
        self.tag(self.later)
        self.tag(self.built, name=f"x/refs/tags/{TAG}")
        listing = _git(self.dev, "ls-remote", "--tags", str(self.origin),
                       f"refs/tags/{TAG}")
        self.assertIn(f"refs/tags/x/refs/tags/{TAG}", listing)
        r = self.guard(TAG, self.built)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)

    def test_unreadable_remote_is_refused(self):
        r = self.guard(TAG, self.built, remote=self.work / "no-such-remote.git")
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)

    def test_abbreviated_or_malformed_commit_is_a_usage_error(self):
        self.tag(self.built)
        for bad in (self.built[:12], "", "z" * 40, self.built + "0"):
            with self.subTest(bad=bad):
                self.assertEqual(2, self.guard(TAG, bad).returncode)
        self.assertEqual(2, subprocess.run(
            [BASH, str(GUARD), str(self.origin), TAG],
            capture_output=True, text=True, env=_env()).returncode)

    # -- the release workflow's publish job ------------------------------

    def test_publish_job_refuses_before_upload_once_the_tag_moved(self):
        self.tag(self.built)
        r = self.run_step(BEFORE_STEP, self.built)
        self.assertEqual(0, r.returncode, r.stderr)
        self.tag(self.later)
        r = self.run_step(BEFORE_STEP, self.built)
        self.assertNotEqual(0, r.returncode, r.stdout + r.stderr)

    def test_publish_job_refuses_after_publishing_once_the_tag_moved(self):
        self.tag(self.built)
        self.run_step(BEFORE_STEP, self.built)  # the runner's clone, at `built`
        self.tag(self.later)
        r = self.run_step(AFTER_STEP, self.built)
        self.assertNotEqual(0, r.returncode, r.stdout + r.stderr)

    def test_guards_bracket_every_step_that_changes_the_release(self):
        names = [n for n, _ in _publish_job_steps()]
        idx = names.index
        # Before anything touches the release: drafting an existing release,
        # uploading, publishing.
        for later in ("Force existing release for this tag back to draft",
                      "Upload assets to a draft release",
                      "Verify the draft, then publish it"):
            self.assertLess(idx(BEFORE_STEP), idx(later), later)
        # After the release becomes visible, and before anything that tells
        # the outside world about it.
        self.assertGreater(idx(AFTER_STEP), idx("Verify the draft, then publish it"))
        self.assertLess(idx(AFTER_STEP),
                        idx("Publish the packages into the organisation's repositories"))
        self.assertGreater(idx(HIDE_STEP), idx(AFTER_STEP))
        # The package publisher must not hear about a release whose tag
        # check failed: its steps run only on success (no `if:` overriding
        # the default), so a failed post-publish check skips them.
        for name in ("Mint a token for the organisation's package publisher",
                     "Publish the packages into the organisation's repositories"):
            self.assertGreater(idx(name), idx(AFTER_STEP), name)
            self.assertNotRegex(dict(_publish_job_steps())[name],
                                r"(?m)^        if:", name)

        steps = dict(_publish_job_steps())
        for name in (BEFORE_STEP, AFTER_STEP):
            text = steps[name]
            # The built commit is the run's, not anything resolved later.
            self.assertIn("BUILT_COMMIT: ${{ github.sha }}", text)
            self.assertIn("TAG: ${{ github.ref_name }}", text)
            self.assertNotIn("continue-on-error", text)
            self.assertNotRegex(text, r"(?m)^        if:", "nothing may switch the guard off")
        self.assertIn("id: tag_after_publish", steps[AFTER_STEP])
        hide = steps[HIDE_STEP]
        self.assertIn("if: failure() && steps.tag_after_publish.outcome == 'failure'", hide)
        self.assertIn("--draft=true", hide)


if __name__ == "__main__":
    unittest.main()
