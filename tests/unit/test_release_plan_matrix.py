"""The release `plan` job: the matrix, the asset set, and proving runs.

`plan`'s step "Derive matrix and expected asset set" reads
.github/release-platforms.json and decides two things that must agree: which
legs `build-release` runs, and which assets `publish-release` demands before it
makes a release visible. A leg that is being proved (a `candidates` row)
must be buildable through that same job without ever joining the asset set of
a tag, because the release is all-or-nothing: a promised leg that has never
built blocks every release. linux-aarch64 was proved that way and promoted on
2026-11-24, so the checked-in `candidates` is empty; the candidate mechanism is
exercised here with a synthetic row (`SYNTHETIC_CANDIDATE`) added to a copy of
the real file.

These tests run the step's `script:` -- the text checked in to
release-pipeline.yml, unchanged -- under node, the way `actions/github-script`
runs it, against a checkout holding the real release-platforms.json (and, for
the candidate cases, a copy carrying the synthetic candidate, in `candidates`
or moved unchanged into `platforms`). The
step's `env:` line for the filter is asserted to be the one the workflow
passes, then set directly.

What is stubbed, and why: `core` and `context` are the two objects
`actions/github-script` hands the script; the stub records `setOutput` /
`setFailed` exactly as the runner would. The script makes no API calls. The
workflow text, the platform declaration, node and the filesystem are real.
"""

from pathlib import Path
import importlib.util
import json
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLATFORMS_JSON = ROOT / ".github" / "release-platforms.json"
RELEASE_YML = ROOT / ".github" / "workflows" / "release.yml"
PIPELINE_YML = ROOT / ".github" / "workflows" / "release-pipeline.yml"
STEP = "Derive matrix and expected asset set"
VERSION = "9.8.7"

# The workflow readers are shared with the pipeline-identity test, which
# documents them; loading that module keeps one copy.
_spec = importlib.util.spec_from_file_location(
    "release_identity", Path(__file__).with_name("test_release_pipeline_identity.py"))
_identity = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_identity)
NODE = _identity.NODE

HARNESS = r"""
const fixture = JSON.parse(process.env.FIXTURE_JSON);
const result = { failed: null, outputs: {}, info: [] };
const core = {
  setFailed: (m) => { result.failed = String(m); },
  info: (m) => { result.info.push(String(m)); },
  setOutput: (k, v) => { result.outputs[k] = String(v); },
};
const context = { ref: fixture.ref };
const body = require('fs').readFileSync(process.env.SCRIPT_PATH, 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
new AsyncFunction('github', 'context', 'core', 'require', body)({}, context, core, require)
  .then(() => { process.stdout.write(JSON.stringify(result)); },
        (e) => { result.failed = `threw: ${e && e.stack || e}`;
                 process.stdout.write(JSON.stringify(result)); });
"""


def _released_spec():
    return json.loads(PLATFORMS_JSON.read_text(encoding="utf-8"))


def _leg(p):
    return f"{p['platform']}-{p['arch']}"


def _archive(p):
    return f"reprobuild-{VERSION}-{_leg(p)}.{p['archive_ext']}"


def _released_row(leg):
    return next(p for p in _released_spec()["platforms"] if _leg(p) == leg)


# A leg no runner serves, shaped exactly like a real `platforms` row. It only
# ever exists in a temporary copy of release-platforms.json, so the candidate
# path of the plan script stays tested while the checked-in `candidates` is
# empty. riscv64 is used because the real file declares it nowhere (the
# unknown-leg test relies on that too).
SYNTHETIC_CANDIDATE = {
    "os-name": "linux",
    "runner": ["self-hosted", "linux", "riscv64"],
    "env-flavor": "nix",
    "platform": "linux",
    "arch": "riscv64",
    "archive_ext": "tar.gz",
}


def _spec_with_candidate():
    spec = _released_spec()
    spec["candidates"] = list(spec.get("candidates", [])) + [dict(SYNTHETIC_CANDIDATE)]
    return spec


class CandidateDeclarationTests(unittest.TestCase):
    """The checked-in declaration, read as data."""

    BUILD_KEYS = {"os-name", "runner", "env-flavor", "platform", "arch", "archive_ext"}

    def test_linux_aarch64_is_a_released_platform_not_a_candidate(self):
        """Promoted 2026-11-24 after proving run 45380792531 went green."""
        spec = _released_spec()
        self.assertIn("linux-aarch64", {_leg(p) for p in spec["platforms"]})
        self.assertNotIn("linux-aarch64", {_leg(p) for p in spec["candidates"]})

    def test_candidates_key_is_kept_as_a_list(self):
        """Empty when nothing is being proved, but present: the plan script
        and this file both read it, and the next leg is added there."""
        self.assertIsInstance(_released_spec()["candidates"], list)

    def test_released_platforms_carry_every_key_the_build_job_reads(self):
        for row in _released_spec()["platforms"]:
            self.assertLessEqual(self.BUILD_KEYS, set(row), row)

    def test_candidates_carry_every_key_the_build_job_reads(self):
        """A candidate is promoted by moving it unchanged, so it must already be
        a complete `platforms` row."""
        for row in _released_spec()["candidates"]:
            self.assertLessEqual(self.BUILD_KEYS, set(row), row)

    def test_linux_aarch64_runs_natively_on_linux_arm64(self):
        row = _released_row("linux-aarch64")
        self.assertEqual(row["os-name"], "linux")
        self.assertEqual(row["env-flavor"], "nix")
        self.assertEqual(row["archive_ext"], "tar.gz")
        self.assertEqual(row["runner"], ["self-hosted", "linux", "arm64"])

    def test_no_leg_is_both_released_and_a_candidate(self):
        spec = _released_spec()
        self.assertFalse({_leg(p) for p in spec["platforms"]} &
                         {_leg(p) for p in spec["candidates"]})


class WorkflowWiringTests(unittest.TestCase):
    def test_release_yml_passes_the_filter_to_both_callers(self):
        text = RELEASE_YML.read_text(encoding="utf-8")
        self.assertRegex(text, r"workflow_dispatch:\n    inputs:\n      (#.*\n      )*platforms:")
        self.assertEqual(text.count("      platforms: ${{ inputs.platforms || '' }}"), 2, text)

    def test_pipeline_declares_the_input(self):
        text = PIPELINE_YML.read_text(encoding="utf-8")
        self.assertRegex(text, r"on:\n  workflow_call:\n    inputs:\n(      #.*\n)*      platforms:\n")

    def test_native_package_steps_follow_the_matrix_flag(self):
        """A Linux leg no package is made from must not run the install check,
        whose `checked -gt 0` guard would fail it."""
        text = PIPELINE_YML.read_text(encoding="utf-8")
        for name in ("Build native packages from this leg's archive",
                     "Verify the native packages install the archive intact"):
            self.assertRegex(text, rf"- name: {re.escape(name)}\n        if: matrix\.native-packages\n")

    def test_nix_cache_push_is_skipped_on_a_proving_run(self):
        text = PIPELINE_YML.read_text(encoding="utf-8")
        job = text[text.index("\n  publish-nix-cache:"):text.index("\n  publish-release:")]
        self.assertIn("    if: needs.plan.outputs.full-release == 'true'\n", job)


@unittest.skipIf(NODE is None, "needs node on PATH (the dev shell provides it)")
class PlanScriptTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="repro-test-release-plan-")
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        self.checkout = self.work / "checkout"
        (self.checkout / ".github").mkdir(parents=True)
        (self.checkout / "reprobuild.nimble").write_text(f'version       = "{VERSION}"\n')
        self.write_spec(_released_spec())
        step = _identity._plan_step(STEP)
        self.assertIn("        env:\n          PLATFORM_FILTER: ${{ inputs.platforms }}\n", step)
        self.script_path = self.work / "script.js"
        self.script_path.write_text(_identity._step_script(step), encoding="utf-8")
        self.harness_path = self.work / "harness.js"
        self.harness_path.write_text(HARNESS, encoding="utf-8")

    def write_spec(self, spec):
        (self.checkout / ".github" / "release-platforms.json").write_text(json.dumps(spec))

    def plan(self, *, ref, platforms=""):
        env = dict(os.environ, FIXTURE_JSON=json.dumps({"ref": ref}),
                   SCRIPT_PATH=str(self.script_path), PLATFORM_FILTER=platforms)
        proc = subprocess.run([NODE, str(self.harness_path)], cwd=self.checkout, env=env,
                              capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def assert_ok(self, r):
        self.assertIsNone(r["failed"], r)
        return (json.loads(r["outputs"]["matrix"]),
                r["outputs"]["expected-assets"].splitlines())

    # -- a release ------------------------------------------------------------

    def test_tag_builds_exactly_the_released_platforms(self):
        spec = _released_spec()
        matrix, assets = self.assert_ok(self.plan(ref=f"refs/tags/v{VERSION}"))
        self.assertEqual([_leg(p) for p in matrix], [_leg(p) for p in spec["platforms"]])
        for p in spec["platforms"]:
            self.assertIn(_archive(p), assets)
        self.assertIn(f"reprobuild-{VERSION}-linux-aarch64.tar.gz", assets)

    def test_tag_never_builds_a_candidate(self):
        self.write_spec(_spec_with_candidate())
        matrix, assets = self.assert_ok(self.plan(ref=f"refs/tags/v{VERSION}"))
        self.assertEqual([_leg(p) for p in matrix],
                         [_leg(p) for p in _released_spec()["platforms"]])
        self.assertNotIn(_archive(SYNTHETIC_CANDIDATE), assets)

    def test_tag_marks_only_the_package_source_leg(self):
        r = self.plan(ref=f"refs/tags/v{VERSION}")
        matrix, _ = self.assert_ok(r)
        sources = {p["from"] for p in _released_spec()["packages"]}
        for row in matrix:
            self.assertEqual(row["native-packages"], _leg(row) in sources, row)
        self.assertEqual(r["outputs"]["full-release"], "true")
        self.assertNotEqual(r["outputs"].get("addon-runner", ""), "")

    def test_tag_with_a_filter_is_refused(self):
        r = self.plan(ref=f"refs/tags/v{VERSION}", platforms="linux-aarch64")
        self.assertIsNotNone(r["failed"])
        self.assertIn("every platform", r["failed"])
        self.assertNotIn("matrix", r["outputs"])

    # -- a proving run --------------------------------------------------------

    def test_proving_run_builds_only_the_candidate_and_publishes_nothing_else(self):
        self.write_spec(_spec_with_candidate())
        r = self.plan(ref="refs/heads/agents", platforms="linux-riscv64")
        matrix, assets = self.assert_ok(r)
        self.assertEqual([_leg(p) for p in matrix], ["linux-riscv64"])
        self.assertEqual(assets, [_archive(SYNTHETIC_CANDIDATE)])
        self.assertIs(matrix[0]["native-packages"], False)
        self.assertEqual(r["outputs"]["packages"], "")
        self.assertEqual(r["outputs"].get("addon-runner", ""), "")
        self.assertEqual(r["outputs"]["full-release"], "false")

    def test_proving_run_of_linux_aarch64_builds_no_package(self):
        """The promoted leg still has no package made from it, so a filtered
        run of it alone builds its archive and nothing else."""
        r = self.plan(ref="refs/heads/agents", platforms="linux-aarch64")
        matrix, assets = self.assert_ok(r)
        self.assertEqual([_leg(p) for p in matrix], ["linux-aarch64"])
        self.assertEqual(assets, [f"reprobuild-{VERSION}-linux-aarch64.tar.gz"])
        self.assertIs(matrix[0]["native-packages"], False)
        self.assertEqual(r["outputs"]["packages"], "")
        self.assertEqual(r["outputs"].get("addon-runner", ""), "")
        self.assertEqual(r["outputs"]["full-release"], "false")

    def test_proving_run_of_a_released_leg_keeps_what_that_leg_builds(self):
        r = self.plan(ref="refs/heads/agents", platforms="linux-x86_64")
        matrix, assets = self.assert_ok(r)
        self.assertEqual([_leg(p) for p in matrix], ["linux-x86_64"])
        self.assertIs(matrix[0]["native-packages"], True)
        for p in _released_spec()["packages"]:
            self.assertIn(p["asset"].replace("{version}", VERSION), assets)
        self.assertNotEqual(r["outputs"].get("addon-runner", ""), "")

    def test_filter_accepts_commas_and_spaces(self):
        r = self.plan(ref="refs/heads/agents", platforms=" linux-aarch64, darwin-aarch64 ")
        matrix, _ = self.assert_ok(r)
        self.assertEqual(sorted(_leg(p) for p in matrix), ["darwin-aarch64", "linux-aarch64"])

    def test_unknown_leg_is_refused(self):
        r = self.plan(ref="refs/heads/agents", platforms="linux-riscv64")
        self.assertIn("unknown platform(s) linux-riscv64", r["failed"] or "")

    # -- promotion ------------------------------------------------------------

    def test_promoting_the_candidate_unchanged_adds_it_to_the_release(self):
        spec = _spec_with_candidate()
        row = next(p for p in spec["candidates"] if _leg(p) == "linux-riscv64")
        spec["platforms"].append(row)
        spec["candidates"] = [p for p in spec["candidates"] if p is not row]
        self.write_spec(spec)
        matrix, assets = self.assert_ok(self.plan(ref=f"refs/tags/v{VERSION}"))
        self.assertIn("linux-riscv64", [_leg(p) for p in matrix])
        self.assertIn(_archive(SYNTHETIC_CANDIDATE), assets)
        promoted = next(p for p in matrix if _leg(p) == "linux-riscv64")
        self.assertIs(promoted["native-packages"], False)


if __name__ == "__main__":
    unittest.main()
