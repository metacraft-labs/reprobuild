"""The clingo windows-arm64 producer publishes only for a pushed producer tag.

.github/workflows/clingo-windows-arm64.yml builds a toolchain binary that
windows/toolchain-versions.env pins by sha256, so what may start it and what it
may write are part of the supply chain. Its design: a person or a session
pushes `producer/clingo-windows-arm64/v<CLINGO_VERSION>-<n>` from a commit on
`agents`; the run builds that commit and creates a release FOR THE EXISTING
TAG; a workflow_dispatch is a build-only dry run. These tests hold that:

  * the trigger is that tag pattern plus workflow_dispatch, nothing else, and
    the pattern is disjoint from release.yml's `v*` in both directions;
  * the only write is `gh release create --verify-tag` in a job a dispatch
    cannot reach, and nothing in the workflow creates or moves a tag;
  * the guard scripts the `admit` job runs refuse a tag of the wrong shape or
    version and a commit that is not on the branch -- run for real, as the
    workflow's own `run:` lines, against a real bare repository.

Nothing is mocked. The remote is a bare repository on the filesystem, which
`git fetch` and `git ls-remote` treat as they treat github.com; the
workflow's hard-coded https URL is pointed at it with git's own `insteadOf`
configuration, passed through GIT_CONFIG_COUNT. Only GitHub itself (`gh`) is
absent, so the release-existence steps are checked by shape and order only.
"""

from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "clingo-windows-arm64.yml"
RELEASE_YML = ROOT / ".github" / "workflows" / "release.yml"
TOOLCHAIN_ENV = ROOT / "windows" / "toolchain-versions.env"
TAG_GUARD = ROOT / "scripts" / "release" / "assert_producer_tag.sh"
BRANCH_GUARD = ROOT / "scripts" / "release" / "assert_commit_on_branch.sh"
GIT = shutil.which("git")
BASH = shutil.which("bash")

PREFIX = "producer/clingo-windows-arm64"
REPO = "metacraft-labs/reprobuild"


# -- a deliberately small reader of the checked-in workflow ----------------
#
# The repository's lint runs actionlint over these files, so a structurally
# broken workflow cannot reach this test; this reader only needs to find
# blocks by indentation.

def _block(text: str, header: str, indent: int) -> str:
    """The lines under `header` (at `indent` spaces) up to the next sibling."""
    lines = text.splitlines()
    pad = " " * indent
    for i, line in enumerate(lines):
        if line == pad + header:
            out = []
            for nxt in lines[i + 1:]:
                if nxt.strip() and not nxt.startswith(pad + " ") and not nxt.lstrip().startswith("#"):
                    break
                out.append(nxt)
            return "\n".join(out)
    raise AssertionError(f"no '{header}' at indent {indent}")


def _on_block(text: str) -> str:
    return _block(text, "on:", 0)


def _tag_patterns(on_block: str):
    tags = _block(on_block, "tags:", 4)
    return [m.group(1) for m in re.finditer(r'^\s+- "([^"]+)"$', tags, re.M)]


def _job(text: str, name: str) -> str:
    return _block(_block(text, "jobs:", 0), f"{name}:", 2)


def _steps(job: str):
    chunks = re.split(r"\n(?=      - )", job)
    steps = []
    for chunk in chunks[1:]:
        m = re.search(r"^      - (?:name: (.+)|uses: (.+))$", chunk, re.M)
        if m:
            steps.append(((m.group(1) or m.group(2)).strip(), chunk))
    return steps


def _run_line(step_text: str) -> str:
    m = re.search(r"^        run: (.+)$", step_text, re.M)
    if m is None:
        raise AssertionError(f"step has no single-line run:\n{step_text}")
    return m.group(1)


def _job_if(job: str) -> str:
    m = re.search(r"^    if: (.+)$", job, re.M)
    return "" if m is None else m.group(1)


def _filter_regex(pattern: str) -> re.Pattern:
    """GitHub's ref filter glob: `*` stops at `/`, `**` does not.

    https://docs.github.com/actions/writing-workflows/workflow-syntax-for-github-actions#filter-pattern-cheat-sheet
    `?`, `+`, `[]` and `!` are not used by either workflow; refuse them so a
    future pattern that uses them is not silently mis-modelled here.
    """
    if re.search(r"[?+\[\]!]", pattern):
        raise AssertionError(f"pattern '{pattern}' uses syntax this model omits")
    out = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(out + r"\Z")


def _literal_head(pattern: str) -> str:
    return re.split(r"[*?\[]", pattern, maxsplit=1)[0]


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


def _clingo_version() -> str:
    m = re.search(r"^CLINGO_VERSION=(.+)$", TOOLCHAIN_ENV.read_text(encoding="utf-8"), re.M)
    assert m is not None, "windows/toolchain-versions.env has no CLINGO_VERSION"
    return m.group(1).strip()


class WorkflowShapeTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_trigger_is_the_producer_tag_and_dispatch_only(self):
        on = _on_block(self.text)
        events = re.findall(r"^  ([a-z_]+):", on, re.M)
        self.assertEqual(["push", "workflow_dispatch"], events)
        push = _block(on, "push:", 2)
        filters = re.findall(r"^    ([a-z-]+):", push, re.M)
        # Only `tags`: with no branch filter GitHub runs it for no branch push.
        self.assertEqual(["tags"], filters)
        self.assertEqual([f"{PREFIX}/v*"], _tag_patterns(on))

    def test_producer_and_release_tag_patterns_are_disjoint(self):
        producer = _tag_patterns(_on_block(self.text))
        release = _tag_patterns(_on_block(RELEASE_YML.read_text(encoding="utf-8")))
        self.assertEqual(["v*"], release)
        # A proof, not a sample: two patterns whose literal heads are not
        # prefixes of one another can match no common ref.
        for p in producer:
            for r in release:
                hp, hr = _literal_head(p), _literal_head(r)
                self.assertFalse(hp.startswith(hr) or hr.startswith(hp),
                                 f"'{p}' and '{r}' may both match a tag")
        # And the concrete names each side cuts.
        release_tags = ["v0.2.35", "v1.0.0", "v0.2.24-rc1"]
        producer_tags = [f"{PREFIX}/v5.8.0-1", f"{PREFIX}/v5.8.0-12"]
        for tag in producer_tags:
            self.assertTrue(any(_filter_regex(p).match(tag) for p in producer), tag)
            self.assertFalse(any(_filter_regex(r).match(tag) for r in release), tag)
        for tag in release_tags:
            self.assertTrue(any(_filter_regex(r).match(tag) for r in release), tag)
            self.assertFalse(any(_filter_regex(p).match(tag) for p in producer), tag)

    def test_only_the_publish_job_can_write_and_only_on_a_tag_push(self):
        self.assertIn("\npermissions:\n  contents: read\n", self.text)
        publish = _job(self.text, "publish")
        self.assertIn("    permissions:\n      contents: write\n", publish)
        cond = _job_if(publish)
        self.assertIn("github.event_name == 'push'", cond)
        self.assertIn(f"startsWith(github.ref, 'refs/tags/{PREFIX}/v')", cond)
        self.assertNotIn("||", cond)
        for job in ("admit", "build"):
            self.assertNotIn("contents: write", _job(self.text, job), job)

    def test_dispatch_builds_only_when_admit_is_skipped(self):
        admit_if = _job_if(_job(self.text, "admit"))
        self.assertIn("github.event_name == 'push'", admit_if)
        build = _job(self.text, "build")
        self.assertIn("needs: admit", build)
        cond = re.search(r"^    if: >-\n((?:      .+\n)+)", build + "\n", re.M)
        self.assertIsNotNone(cond, "build has no folded `if:`")
        cond = " ".join(cond.group(1).split())
        self.assertIn("needs.admit.result == 'success'", cond)
        self.assertIn("(github.event_name == 'workflow_dispatch' && needs.admit.result == 'skipped')", cond)

    def test_publish_describes_the_pushed_tag_and_never_creates_one(self):
        steps = _steps(_job(self.text, "publish"))
        names = [n for n, _ in steps]
        create = dict(steps)["Create the release for the pushed tag"]
        self.assertRegex(create, r'gh release create "\$\{TAG\}" [^\n]*--verify-tag')
        self.assertIn("TAG: ${{ github.ref_name }}", create)
        self.assertNotIn("--target", create)
        # Nothing anywhere in the workflow makes or moves a tag.
        code = "\n".join(l for l in self.text.splitlines() if not l.lstrip().startswith("#"))
        for forbidden in ("git tag", "git push", "git/refs", "git/tags", "--target"):
            self.assertNotIn(forbidden, code, forbidden)
        # The overwrite and tag guards come first; the after-check follows.
        i = names.index
        self.assertLess(i("Refuse if the tag no longer names this build (before upload)"),
                        i("Create the release for the pushed tag"))
        self.assertLess(i("Refuse to overwrite an existing release or asset"),
                        i("Create the release for the pushed tag"))
        self.assertLess(i("Create the release for the pushed tag"),
                        i("Refuse if the tag no longer names this build (after publishing)"))
        overwrite = dict(steps)["Refuse to overwrite an existing release or asset"]
        self.assertIn('gh release view "${TAG}"', overwrite)
        self.assertIn(".assets[]", overwrite)

    def test_admit_runs_every_guard(self):
        names = [n for n, _ in _steps(_job(self.text, "admit"))]
        for guard in ("Refuse a tag that does not name this clingo version",
                      "Refuse a commit that is not on the producer source branch",
                      "Refuse if the tag no longer names this commit",
                      "Refuse if a release for this tag already exists"):
            self.assertIn(guard, names)
        self.assertIn("PRODUCER_SOURCE_BRANCH: agents", self.text)

    def test_header_names_the_tag_command(self):
        self.assertIn(f"git push origin {PREFIX}/v", self.text)
        self.assertIn("--verify-tag", self.text)


@unittest.skipIf(os.name == "nt", "the guards run in the Linux admit job")
@unittest.skipIf(GIT is None or BASH is None, "needs git and bash on PATH")
class GuardTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="repro-test-clingo-producer-")
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        self.origin = self.work / "origin.git"
        self.dev = self.work / "dev"
        subprocess.run([GIT, "init", "-q", "--bare", str(self.origin)], check=True, env=_env())
        subprocess.run([GIT, "init", "-q", str(self.dev)], check=True, env=_env())
        _git(self.dev, "commit", "-q", "--allow-empty", "-m", "base")
        self.landed = _git(self.dev, "rev-parse", "HEAD")
        _git(self.dev, "commit", "-q", "--allow-empty", "-m", "tip")
        self.tip = _git(self.dev, "rev-parse", "HEAD")
        _git(self.dev, "checkout", "-q", "-b", "side", self.landed)
        _git(self.dev, "commit", "-q", "--allow-empty", "-m", "unreviewed")
        self.stray = _git(self.dev, "rev-parse", "HEAD")
        _git(self.dev, "remote", "add", "origin", str(self.origin))
        _git(self.dev, "push", "-q", "origin", f"{self.tip}:refs/heads/agents",
             f"{self.stray}:refs/heads/side")
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def tag_guard(self, *args):
        return subprocess.run([BASH, str(TAG_GUARD), *args],
                              capture_output=True, text=True, env=_env())

    def branch_guard(self, *args):
        return subprocess.run([BASH, str(BRANCH_GUARD), *args],
                              capture_output=True, text=True, env=_env())

    def run_admit_step(self, name: str, tag: str, sha: str):
        """Run an `admit` step's `run:` line in a stand-in runner checkout."""
        steps = dict(_steps(_job(self.text, "admit")))
        self.assertIn(name, steps)
        runner = self.work / "runner"
        if not runner.exists():
            (runner / "scripts" / "release").mkdir(parents=True)
            (runner / "windows").mkdir()
            for script in (TAG_GUARD, BRANCH_GUARD):
                shutil.copy2(script, runner / "scripts" / "release" / script.name)
            shutil.copy2(TOOLCHAIN_ENV, runner / "windows" / TOOLCHAIN_ENV.name)
        env = _env()
        env.update(
            TAG=tag, GITHUB_SHA=sha, GITHUB_REF_NAME=tag, GITHUB_REPOSITORY=REPO,
            PRODUCER_SOURCE_BRANCH="agents", PRODUCER_TAG_PREFIX=PREFIX,
            # The workflow fetches https://github.com/<repo>.git; send that
            # URL to the bare repository instead.
            GIT_CONFIG_COUNT="1",
            GIT_CONFIG_KEY_0=f"url.{self.origin.as_uri()}.insteadOf",
            GIT_CONFIG_VALUE_0=f"https://github.com/{REPO}.git",
        )
        return subprocess.run([BASH, "-e", "-c", _run_line(steps[name])],
                              cwd=runner, capture_output=True, text=True, env=env)

    # -- assert_producer_tag.sh ------------------------------------------

    def test_a_tag_naming_the_pinned_version_passes(self):
        r = self.tag_guard(PREFIX, f"{PREFIX}/v5.8.0-1", "5.8.0")
        self.assertEqual(0, r.returncode, r.stderr)
        r = self.tag_guard(PREFIX, f"{PREFIX}/v5.8.0-12", "5.8.0")
        self.assertEqual(0, r.returncode, r.stderr)

    def test_a_tag_of_the_wrong_shape_or_version_is_refused(self):
        for tag in (f"{PREFIX}/v5.8.1-1",      # another version
                    f"{PREFIX}/v5.8.0",        # no build number
                    f"{PREFIX}/v5.8.0-0",      # build numbers start at 1
                    f"{PREFIX}/v5.8.0-01",
                    f"{PREFIX}/v5.8.0-1/x",
                    f"{PREFIX}-probe/v5.8.0-1",
                    "v5.8.0-1"):
            r = self.tag_guard(PREFIX, tag, "5.8.0")
            self.assertEqual(1, r.returncode, f"{tag}: {r.stdout}{r.stderr}")

    def test_a_missing_or_malformed_pin_is_a_usage_error(self):
        self.assertEqual(2, self.tag_guard(PREFIX, f"{PREFIX}/v5.8.0-1", "").returncode)
        self.assertEqual(2, self.tag_guard(PREFIX, f"{PREFIX}/v5.8.0-1", "5.8.0\n").returncode)
        self.assertEqual(2, self.tag_guard(PREFIX, f"{PREFIX}/v5.8.0-1").returncode)

    def test_the_admit_step_reads_the_version_from_the_tagged_pins(self):
        version = _clingo_version()
        name = "Refuse a tag that does not name this clingo version"
        r = self.run_admit_step(name, f"{PREFIX}/v{version}-1", self.tip)
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)
        r = self.run_admit_step(name, f"{PREFIX}/v{version}.9-1", self.tip)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)

    # -- assert_commit_on_branch.sh --------------------------------------

    def test_the_branch_tip_and_its_ancestors_pass(self):
        for sha in (self.tip, self.landed):
            r = self.branch_guard(str(self.origin), "agents", sha)
            self.assertEqual(0, r.returncode, r.stderr)

    def test_a_commit_off_the_branch_is_refused(self):
        r = self.branch_guard(str(self.origin), "agents", self.stray)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)
        self.assertIn("is not on agents", r.stderr)

    def test_an_unknown_commit_is_refused(self):
        r = self.branch_guard(str(self.origin), "agents", "a" * 40)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)

    def test_a_tag_object_is_refused_not_peeled(self):
        _git(self.dev, "tag", "-a", "-m", "t", "t1", self.tip)
        _git(self.dev, "push", "-q", "origin", "refs/tags/t1")
        tag_object = _git(self.dev, "rev-parse", "refs/tags/t1")
        r = self.branch_guard(str(self.origin), "agents", tag_object)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)

    def test_a_missing_branch_or_remote_is_refused(self):
        r = self.branch_guard(str(self.origin), "no-such-branch", self.tip)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)
        r = self.branch_guard(str(self.work / "nowhere.git"), "agents", self.tip)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)

    def test_an_abbreviated_commit_is_a_usage_error(self):
        r = self.branch_guard(str(self.origin), "agents", self.tip[:12])
        self.assertEqual(2, r.returncode, r.stdout + r.stderr)

    def test_the_admit_step_asks_the_repository_remote(self):
        name = "Refuse a commit that is not on the producer source branch"
        r = self.run_admit_step(name, f"{PREFIX}/v5.8.0-1", self.landed)
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)
        r = self.run_admit_step(name, f"{PREFIX}/v5.8.0-1", self.stray)
        self.assertEqual(1, r.returncode, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
