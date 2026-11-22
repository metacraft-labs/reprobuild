"""The release `plan` job compares the pipeline copy that its caller loaded.

release.yml calls release-pipeline.yml twice: as `lane` (`...@agents`) and as
`general` (`./...`, the run's own commit), with complementary `if:`
conditions. GitHub resolves every `uses:` when it creates the run, the
skipped job's included, so the run's `referenced_workflows` always lists BOTH
copies. The guard step "Assert this pipeline is the tag's own" demanded
exactly one entry and so failed every release: v0.2.32 (run 44995307653, job
`general / Plan release`) was refused with

    expected exactly one referenced workflow ...release-pipeline.yml@*, found 2

These tests run that step's `script:` -- the text checked in to
release-pipeline.yml, unchanged -- under node, the way
`actions/github-script` runs it: as the body of an async function given
`github`, `context`, `core` and `require`. The step's own `env:` block is
honoured, so a repository variable reaches the script only if the workflow
passes it.

Why the GitHub API is stubbed: the step makes two REST calls
(`actions.getWorkflowRun` for `referenced_workflows`, `repos.getContent` for
the loaded copy's blob id), and they can only be answered by GitHub for a real
run. The stub answers with recorded data -- the `referenced_workflows` of run
44995307653 verbatim in the first case -- and with blob ids computed from real
bytes, so the byte-for-byte comparison the step makes is exercised for real.
The workflow text, node, and the filesystem the step reads are not mocked.
"""

from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PIPELINE_REL = ".github/workflows/release-pipeline.yml"
PIPELINE_YML = ROOT / PIPELINE_REL
RELEASE_YML = ROOT / ".github" / "workflows" / "release.yml"
STEP = "Assert this pipeline is the tag's own"
NODE = shutil.which("node")

OWNER, REPO = "metacraft-labs", "reprobuild"
PREFIX = f"{OWNER}/{REPO}/{PIPELINE_REL}@"
# v0.2.32: tag and `agents` named the same commit when the run was created.
V0232_SHA = "ca6a225033b765f50e70142f19f39e96a6d85681"
V0232_REFERENCED = [
    {"path": f"{PREFIX}{V0232_SHA}", "ref": "refs/tags/v0.2.32", "sha": V0232_SHA},
    {"path": f"{PREFIX}agents", "ref": "refs/heads/agents", "sha": V0232_SHA},
]
AGENTS_SHA = "a" * 40
OTHER_SHA = "b" * 40

# release.yml's `lane` condition. The guard mirrors it; see
# test_guard_mirrors_release_yml_lane_condition.
LANE_IF = "vars.RELEASE_LANE == 'admitted' && startsWith(github.ref, 'refs/tags/v')"


def _git_blob(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def _plan_step(name: str) -> str:
    """Return the text of step `name` of the `plan` job.

    A deliberately small reader of the checked-in workflow: it cuts the job at
    the next top-level job and the step at the next `      - ` item. The
    repository's lint runs actionlint over the same file, so a structurally
    broken workflow cannot reach this test.
    """
    text = PIPELINE_YML.read_text(encoding="utf-8")
    start = text.index("\n  plan:\n") + 1
    nxt = re.search(r"\n  [A-Za-z0-9_-]+:\n", text[start + len("  plan:\n"):])
    job = text[start:] if nxt is None else text[start: start + len("  plan:\n") + nxt.start() + 1]
    for chunk in re.split(r"\n(?=      - )", job)[1:]:
        if re.search(rf"^      - name: {re.escape(name)}$", chunk, re.M):
            return chunk
    raise AssertionError(f"plan has no step '{name}'")


def _step_script(step: str) -> str:
    m = re.search(r"^          script: \|\n((?:            .*\n|\s*\n)+)", step + "\n", re.M)
    if m is None:
        raise AssertionError(f"step has no `script: |` block:\n{step}")
    return "\n".join(line[12:] for line in m.group(1).splitlines())


def _step_env(step: str, variables: dict) -> dict:
    """Evaluate the step's `env:` block. Only `${{ vars.NAME }}` is supported:
    an unset variable is the empty string, as on GitHub."""
    m = re.search(r"^        env:\n((?:          \S.*\n)+)", step + "\n", re.M)
    env = {}
    if m is None:
        return env
    for line in m.group(1).splitlines():
        km = re.fullmatch(r"          ([A-Za-z_][A-Za-z0-9_]*): (.*)", line)
        if km is None:
            raise AssertionError(f"unreadable env line: {line!r}")
        key, value = km.groups()
        vm = re.fullmatch(r"\$\{\{\s*vars\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}", value.strip())
        if vm is None:
            raise AssertionError(f"this test evaluates only vars.* in env, got {line!r}")
        env[key] = variables.get(vm.group(1), "")
    return env


# The shape `actions/github-script` gives a script: an async function body
# with `github`, `context`, `core` and `require` in scope.
HARNESS = r"""
const fixture = JSON.parse(process.env.FIXTURE_JSON);
const result = { failed: null, info: [] };
const core = {
  setFailed: (m) => { result.failed = String(m); },
  info: (m) => { result.info.push(String(m)); },
};
const context = { repo: { owner: fixture.owner, repo: fixture.repo },
                  runId: 44995307653, ref: fixture.ref, sha: fixture.sha };
const github = { rest: {
  actions: { getWorkflowRun: async ({ run_id }) => {
    if (run_id !== context.runId) throw new Error(`asked for run ${run_id}`);
    return { data: { referenced_workflows: fixture.referenced } };
  } },
  repos: { getContent: async ({ owner, repo, path, ref }) => {
    if (owner !== fixture.owner || repo !== fixture.repo || path !== fixture.file)
      throw new Error(`unexpected getContent ${owner}/${repo}/${path}`);
    if (!(ref in fixture.blobs)) throw new Error(`No commit found for the ref ${ref}`);
    return { data: { sha: fixture.blobs[ref] } };
  } },
} };
const body = require('fs').readFileSync(process.env.SCRIPT_PATH, 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
new AsyncFunction('github', 'context', 'core', 'require', body)(github, context, core, require)
  .then(() => { process.stdout.write(JSON.stringify(result)); },
        (e) => { result.failed = `threw: ${e && e.stack || e}`;
                 process.stdout.write(JSON.stringify(result)); });
"""


@unittest.skipIf(NODE is None, "needs node on PATH (the dev shell provides it)")
class PipelineIdentityGuardTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="repro-test-release-identity-")
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        # The runner's checkout of the tag: the step reads the pipeline from it.
        self.checkout = self.work / "checkout"
        (self.checkout / ".github" / "workflows").mkdir(parents=True)
        self.tag_bytes = PIPELINE_YML.read_bytes()
        (self.checkout / PIPELINE_REL).write_bytes(self.tag_bytes)
        step = _plan_step(STEP)
        self.step = step
        self.script_path = self.work / "script.js"
        self.script_path.write_text(_step_script(step), encoding="utf-8")
        self.harness_path = self.work / "harness.js"
        self.harness_path.write_text(HARNESS, encoding="utf-8")

    def run_guard(self, *, ref, sha, referenced, blobs, variables):
        fixture = {"owner": OWNER, "repo": REPO, "file": PIPELINE_REL, "ref": ref,
                   "sha": sha, "referenced": referenced, "blobs": blobs}
        env = dict(os.environ, FIXTURE_JSON=json.dumps(fixture),
                   SCRIPT_PATH=str(self.script_path))
        env.pop("RELEASE_LANE", None)
        env.update(_step_env(self.step, variables))
        proc = subprocess.run([NODE, str(self.harness_path)], cwd=self.checkout,
                              env=env, capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def tag_blob(self):
        return _git_blob(self.tag_bytes)

    # -- the v0.2.32 run, as GitHub recorded it ------------------------------

    def test_v0232_general_run_passes(self):
        """The run that failed: lane off, both copies referenced."""
        r = self.run_guard(ref="refs/tags/v0.2.32", sha=V0232_SHA,
                           referenced=V0232_REFERENCED,
                           blobs={V0232_SHA: self.tag_blob()}, variables={})
        self.assertIsNone(r["failed"], r)
        self.assertTrue(any("refs/tags/v0.2.32" in line for line in r["info"]), r)

    def test_v0232_lane_run_passes(self):
        r = self.run_guard(ref="refs/tags/v0.2.32", sha=V0232_SHA,
                           referenced=V0232_REFERENCED,
                           blobs={V0232_SHA: self.tag_blob()},
                           variables={"RELEASE_LANE": "admitted"})
        self.assertIsNone(r["failed"], r)
        self.assertTrue(any("refs/heads/agents" in line for line in r["info"]), r)

    # -- agents ahead of the tag ---------------------------------------------

    def _ahead(self, agents_blob):
        referenced = [
            {"path": f"{PREFIX}{OTHER_SHA}", "ref": "refs/tags/v0.2.33", "sha": OTHER_SHA},
            {"path": f"{PREFIX}agents", "ref": "refs/heads/agents", "sha": AGENTS_SHA},
        ]
        blobs = {OTHER_SHA: self.tag_blob(), AGENTS_SHA: agents_blob}
        return referenced, blobs

    def test_lane_refuses_agents_copy_that_differs_from_the_tags(self):
        referenced, blobs = self._ahead(_git_blob(self.tag_bytes + b"# changed on agents\n"))
        r = self.run_guard(ref="refs/tags/v0.2.33", sha=OTHER_SHA, referenced=referenced,
                           blobs=blobs, variables={"RELEASE_LANE": "admitted"})
        self.assertIsNotNone(r["failed"])
        self.assertIn("differs from the copy", r["failed"])
        self.assertIn(AGENTS_SHA, r["failed"])

    def test_lane_accepts_agents_copy_with_the_tags_bytes(self):
        referenced, blobs = self._ahead(self.tag_blob())
        r = self.run_guard(ref="refs/tags/v0.2.33", sha=OTHER_SHA, referenced=referenced,
                           blobs=blobs, variables={"RELEASE_LANE": "admitted"})
        self.assertIsNone(r["failed"], r)
        self.assertTrue(any(AGENTS_SHA in line for line in r["info"]), r)

    def test_general_compares_the_runs_own_copy_not_agents(self):
        """Lane off: agents' differing copy was referenced but not loaded."""
        referenced, blobs = self._ahead(_git_blob(self.tag_bytes + b"# changed on agents\n"))
        r = self.run_guard(ref="refs/tags/v0.2.33", sha=OTHER_SHA, referenced=referenced,
                           blobs=blobs, variables={"RELEASE_LANE": ""})
        self.assertIsNone(r["failed"], r)
        self.assertTrue(any(OTHER_SHA in line and "loaded" in line for line in r["info"]), r)

    def test_lane_variable_does_not_apply_to_a_branch_dispatch(self):
        """release.yml runs `general` for a dispatch on a branch, whatever the
        variable says, so the guard must compare the run's own copy."""
        referenced = [
            {"path": f"{PREFIX}{OTHER_SHA}", "ref": "refs/heads/dev", "sha": OTHER_SHA},
            {"path": f"{PREFIX}agents", "ref": "refs/heads/agents", "sha": AGENTS_SHA},
        ]
        blobs = {OTHER_SHA: self.tag_blob(),
                 AGENTS_SHA: _git_blob(self.tag_bytes + b"# changed on agents\n")}
        r = self.run_guard(ref="refs/heads/dev", sha=OTHER_SHA, referenced=referenced,
                           blobs=blobs, variables={"RELEASE_LANE": "admitted"})
        self.assertIsNone(r["failed"], r)

    # -- still refuses what it cannot identify -------------------------------

    def test_lane_refuses_a_missing_agents_entry(self):
        referenced = [V0232_REFERENCED[0]]
        r = self.run_guard(ref="refs/tags/v0.2.32", sha=V0232_SHA, referenced=referenced,
                           blobs={V0232_SHA: self.tag_blob()},
                           variables={"RELEASE_LANE": "admitted"})
        self.assertIsNotNone(r["failed"])
        self.assertIn("found 0", r["failed"])

    def test_general_refuses_a_missing_own_entry(self):
        referenced = [V0232_REFERENCED[1] | {"sha": AGENTS_SHA}]
        r = self.run_guard(ref="refs/tags/v0.2.32", sha=V0232_SHA, referenced=referenced,
                           blobs={V0232_SHA: self.tag_blob(), AGENTS_SHA: self.tag_blob()},
                           variables={})
        self.assertIsNotNone(r["failed"])
        self.assertIn("found 0", r["failed"])

    def test_refuses_two_candidates_at_different_revisions(self):
        referenced = [
            {"path": f"{PREFIX}agents", "ref": "refs/heads/agents", "sha": AGENTS_SHA},
            {"path": f"{PREFIX}refs/heads/agents", "ref": "refs/heads/agents", "sha": OTHER_SHA},
        ]
        r = self.run_guard(ref="refs/tags/v0.2.32", sha=V0232_SHA, referenced=referenced,
                           blobs={AGENTS_SHA: self.tag_blob(), OTHER_SHA: self.tag_blob()},
                           variables={"RELEASE_LANE": "admitted"})
        self.assertIsNotNone(r["failed"])
        self.assertIn("found 2", r["failed"])

    def test_ignores_other_workflows(self):
        referenced = V0232_REFERENCED + [
            {"path": f"{OWNER}/{REPO}/.github/workflows/other.yml@agents",
             "ref": "refs/heads/agents", "sha": OTHER_SHA}]
        r = self.run_guard(ref="refs/tags/v0.2.32", sha=V0232_SHA, referenced=referenced,
                           blobs={V0232_SHA: self.tag_blob()},
                           variables={"RELEASE_LANE": "admitted"})
        self.assertIsNone(r["failed"], r)

    # -- the guard's lane test is release.yml's ------------------------------

    def test_guard_mirrors_release_yml_lane_condition(self):
        """The guard decides which copy was loaded by repeating release.yml's
        `lane` condition. If release.yml's condition changes, this fails until
        the guard is changed with it."""
        text = RELEASE_YML.read_text(encoding="utf-8")
        self.assertIn(f"  lane:\n    if: {LANE_IF}\n", text)
        self.assertIn(f"  general:\n    if: ${{{{ !({LANE_IF}) }}}}\n", text)
        self.assertIn("    uses: metacraft-labs/reprobuild/.github/workflows/release-pipeline.yml@agents\n",
                      text)
        script = _step_script(self.step)
        self.assertIn("=== 'admitted'", script)
        self.assertIn("startsWith('refs/tags/v')", script)
        self.assertIn("'refs/heads/agents'", script)


if __name__ == "__main__":
    unittest.main()
