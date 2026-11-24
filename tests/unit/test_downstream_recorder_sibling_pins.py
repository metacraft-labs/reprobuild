"""The downstream recorder job pins each build sibling where the recorder's CI does.

WHAT IS UNDER TEST
==================

The ``native-recorder-hcr-claims`` job in
``.github/workflows/downstream-tests.yml`` builds codetracer-native-recorder
against this checkout. Before it builds, its step "Put the recorder's build
siblings at the revisions its CI pins" puts four siblings at pinned
revisions: ``codetracer-trace-format-nim``, ``codetracer-trace-format``,
``codetracer-native-backend`` and ``codetracer-visual-replay``.

The step used to take all four from the recorder's ``repro.lock`` and refuse
unless all four were there. The recorder's lock records only what its
``repro.nim`` declares, and that file deliberately does not model
``build-license-ffi``, which builds inside ``../codetracer-native-backend``.
After the recorder re-derived its lock from ``repro.nim``, the lock stopped
naming the backend and the job failed every run with
``the recorder's lock names 3 of the 4 build siblings``.

The recorder's own CI pins the backend by commit in the ``siblings:`` list of
its ``nix-linux-tests`` job (``name=<sha>``). A bare name in that list means
"the revision ``repro.lock`` records". The fix is
``scripts/recorder_build_siblings_lock.sh``, which resolves each sibling the
same way, and the step now reads its pins from that script. These cases pin:

* the STEP, run end to end on a recorder shaped like the one the issue
  observed (lock without the backend, backend pinned in the workflow). Real
  bash runs the step's own ``run:`` body, real git provides the sibling
  checkouts, and the step's own scripts do the work. This case fails on the
  unfixed workflow, for the reason the issue states;
* the SCRIPT's resolution: the lock for a bare name, the workflow for
  ``name=<sha>``;
* the SCRIPT's refusals. It never builds against an unpinned sibling, and it
  never relaxes the count.

FIXTURES AND THE ONE STAND-IN, JUSTIFIED
========================================

The recorder is a hand-written fixture rather than a real
codetracer-native-recorder checkout. The suite must not depend on a sibling
being present at a particular revision. The fixture copies the real lock's
shape (v3 schema, a ``self = "true"`` root entry, one brace group per entry)
and the real workflow's ``siblings:`` block shape (bare names, ``name=<sha>``
with a trailing comment, comment lines).

The one stand-in is ``dev-exec``. In CI it is ``nix develop --command``. Here
it is a two-line script that runs its arguments directly, so the step's
credential helper (``scripts/ci_lock_source_credentials.py``) still runs for
real under this ``python3``. Entering the dev shell would add minutes and a
Nix dependency to a test whose subject is which revisions get picked. The
siblings already hold every pinned commit, so ``--fetch-only`` needs no
network and no forge stand-in.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ci_reconcile_lock_credentials import job_steps  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "recorder_build_siblings_lock.sh"
DOWNSTREAM_WORKFLOW = ROOT / ".github" / "workflows" / "downstream-tests.yml"
STEP_NAME = "Put the recorder's build siblings at the revisions its CI pins"
JOB = "native-recorder-hcr-claims"
RECORDER_JOB = "nix-linux-tests"
RECORDER_WORKFLOW = ".github/workflows/linux-tests.yml"

LOCKED = ["codetracer-trace-format-nim", "codetracer-trace-format",
          "codetracer-visual-replay"]
BACKEND = "codetracer-native-backend"
SIBLINGS = ["codetracer-trace-format-nim", "codetracer-trace-format",
            BACKEND, "codetracer-visual-replay"]
OWNER = "https://github.com/metacraft-labs"

GIT_ENV = {
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
}


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], check=True,
                          capture_output=True, text=True,
                          env={**os.environ, **GIT_ENV}).stdout.strip()


def make_sibling(path: Path) -> tuple[str, str]:
    """A checkout with two commits: (the older one, HEAD)."""
    path.mkdir(parents=True)
    git(path, "init", "-q", "-b", "dev")
    revisions = []
    for n in (1, 2):
        (path / "f").write_text(f"{n}\n")
        git(path, "add", "f")
        git(path, "commit", "-q", "-m", f"c{n}")
        revisions.append(git(path, "rev-parse", "HEAD"))
    return revisions[0], revisions[1]


def lock_entry(name: str, revision: str, depends: str = "") -> str:
    return (f'{{ name = "{name}", coord_kind = "vcs", url = "{OWNER}/{name}", '
            f'revision = "{revision}", integrity = "git-sha1:{revision}", '
            f'version = "", visibility = "public", participation = "", '
            f'depends = "{depends}", tags = "" }}')


def write_lock(recorder: Path, pins: dict[str, str]) -> None:
    """The recorder's lock: a self entry, the given vcs pins, and tool rows."""
    deps = [
        '{ name = "codetracer-native-recorder", self = "true", coord_kind = "vcs", '
        f'url = "{OWNER}/codetracer-native-recorder", revision = "{"0" * 40}", '
        f'integrity = "git-sha1:{"0" * 40}", version = "", visibility = "public", '
        'participation = "", depends = "codetracer-trace-format-nim,'
        'codetracer-visual-replay,codetracer-trace-format", tags = "" }',
        # A non-vcs row whose depends list names a sibling, so name matching
        # cannot be satisfied by a substring of another entry.
        '{ name = "nim", coord_kind = "package", version = "2.2.4", '
        'depends = "codetracer-native-backend", tags = "" }',
    ] + [lock_entry(name, revision) for name, revision in pins.items()]
    (recorder / "repro.lock").write_text(
        'schema = "reprobuild.solved-graph-lock.v3"\n\n[lock]\n'
        'platform = "amd64-linux"\noptimal = false\ndeps = ['
        + ", ".join(deps) + "]\n")


def write_workflow(recorder: Path, siblings_lines: list[str],
                   job: str = RECORDER_JOB) -> None:
    body = "\n".join(f"            {line}" for line in siblings_lines)
    path = recorder / RECORDER_WORKFLOW
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "name: Linux tests\n"
        "jobs:\n"
        "  other-job:\n"
        "    steps:\n"
        "      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev\n"
        "        with:\n"
        "          siblings: |\n"
        f"            {BACKEND}=refs/heads/not-this-job\n"
        f"  {job}:\n"
        "    runs-on: [self-hosted, linux, x64]\n"
        "    steps:\n"
        "      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev\n"
        "        with:\n"
        "          env-flavor: nix\n"
        "          # Siblings that repro.lock does not record are pinned HERE.\n"
        "          siblings: |\n"
        f"{body}\n"
        "\n"
        "      - name: Build\n"
        "        run: dev-exec just build-ct-mcr\n")


def recorder_as_observed(recorder: Path, pins: dict[str, str]) -> None:
    """The recorder as the issue observed it: lock without the backend,
    backend pinned by commit in the CI job's siblings: list."""
    recorder.mkdir(parents=True, exist_ok=True)
    write_lock(recorder, {n: pins[n] for n in LOCKED})
    write_workflow(recorder, [
        "codetracer=" + "a" * 40 + "  # dev tip on 2026-11-22; moves by hand",
        f"{BACKEND}={pins[BACKEND]}  # dev tip on 2026-11-22; moves by hand",
        "codetracer-trace-format",
        "codetracer-trace-format-nim",
        "# a comment line inside the block",
        "codetracer-visual-replay",
        "nim-stackable-hooks",
    ])


def run_script(recorder: Path, out: Path, *names: str,
               job: str = RECORDER_JOB) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(SCRIPT), str(recorder), RECORDER_WORKFLOW, job, str(out),
         *(names or SIBLINGS)],
        capture_output=True, text=True)


def entries(lock: Path) -> dict[str, str]:
    """name -> revision for every brace group in a lock file."""
    import re
    result = {}
    for group in re.findall(r"\{[^{}]*\}", lock.read_text()):
        name = re.search(r'(?:^|[{ ,])name = "([^"]*)"', group).group(1)
        result[name] = re.search(r'revision = "([0-9a-f]{40})"', group).group(1)
    return result


class StepEndToEnd(unittest.TestCase):
    """The workflow step itself, run under bash on a recorder shaped like the
    one the issue observed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.siblings_root = root / "siblings"
        self.repro_root = self.siblings_root / "reprobuild"
        (self.repro_root / "scripts").mkdir(parents=True)
        for script in ("reconcile_locked_siblings.sh",
                       "ci_lock_source_credentials.py",
                       "recorder_build_siblings_lock.sh"):
            source = ROOT / "scripts" / script
            if source.exists():
                (self.repro_root / "scripts" / script).write_bytes(
                    source.read_bytes())
        self.pinned: dict[str, str] = {}
        self.heads: dict[str, str] = {}
        for name in SIBLINGS:
            self.pinned[name], self.heads[name] = make_sibling(
                self.siblings_root / name)
        recorder_as_observed(self.siblings_root / "codetracer-native-recorder",
                             self.pinned)
        self.bin = root / "bin"
        self.bin.mkdir()
        dev_exec = self.bin / "dev-exec"
        dev_exec.write_text('#!/usr/bin/env bash\nexec "$@"\n')
        dev_exec.chmod(0o755)
        self.runner_temp = root / "runner-temp"
        self.runner_temp.mkdir()

    def step(self):
        steps = [s for s in job_steps(DOWNSTREAM_WORKFLOW.read_text(), JOB)
                 if s.fields.get("name") == STEP_NAME]
        self.assertEqual(len(steps), 1, f"exactly one step named {STEP_NAME!r}")
        return steps[0]

    def run_step(self) -> subprocess.CompletedProcess:
        step = self.step()
        run = step.fields["run"].replace("${{ github.workspace }}",
                                         str(self.repro_root))
        self.assertNotIn("${{", run, "the step reads a context this test "
                         "does not supply; extend the test")
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("GIT_CONFIG_")}
        for key, value in step.maps.get("env", {}).items():
            env[key] = value.strip("'\"")
        env.update({
            "GH_TOKEN": "test-token-not-a-secret",
            "RUNNER_TEMP": str(self.runner_temp),
            "PATH": f"{self.bin}{os.pathsep}{env.get('PATH', '')}",
            "GIT_AUTHOR_NAME": "t", "GIT_COMMITTER_NAME": "t",
        })
        return subprocess.run(["bash", "-c", run], cwd=self.repro_root,
                              env=env, capture_output=True, text=True)

    def test_step_puts_every_build_sibling_at_its_ci_pin(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 0,
                         f"step failed:\n{result.stdout}\n{result.stderr}")
        for name in SIBLINGS:
            self.assertEqual(git(self.siblings_root / name, "rev-parse", "HEAD"),
                             self.pinned[name],
                             f"{name} is not at the revision the recorder's CI pins")

    def test_step_refuses_when_the_backend_is_pinned_nowhere(self):
        write_workflow(self.siblings_root / "codetracer-native-recorder", [
            "codetracer-trace-format", "codetracer-trace-format-nim",
            BACKEND, "codetracer-visual-replay"])
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(BACKEND, result.stderr)
        for name in SIBLINGS:
            self.assertEqual(git(self.siblings_root / name, "rev-parse", "HEAD"),
                             self.heads[name], f"{name} moved on a refused run")


class ScriptResolution(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.recorder = self.root / "codetracer-native-recorder"
        self.pins = {name: f"{i + 1:x}" * 40 for i, name in enumerate(SIBLINGS)}
        recorder_as_observed(self.recorder, self.pins)
        self.out = self.root / "out.lock"

    def test_bare_names_come_from_the_lock_and_pinned_names_from_the_job(self):
        result = run_script(self.recorder, self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(entries(self.out), self.pins)
        text = self.out.read_text()
        self.assertTrue(text.startswith(
            'schema = "reprobuild.solved-graph-lock.v3"\n[lock]\ndeps = ['))
        self.assertIn(f'url = "{OWNER}/{BACKEND}"', text)
        self.assertIn(f'integrity = "git-sha1:{self.pins[BACKEND]}"', text)

    def test_only_the_named_job_is_read(self):
        # `other-job` names the backend at a branch; reading it would refuse.
        result = run_script(self.recorder, self.out, BACKEND)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(entries(self.out), {BACKEND: self.pins[BACKEND]})

    def test_a_pin_in_the_job_wins_over_the_lock(self):
        write_lock(self.recorder, {**{n: self.pins[n] for n in LOCKED},
                                   BACKEND: "f" * 40})
        result = run_script(self.recorder, self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(entries(self.out)[BACKEND], self.pins[BACKEND])

    def test_a_bare_name_the_lock_does_not_record_is_refused(self):
        write_workflow(self.recorder, [*LOCKED, BACKEND])
        result = run_script(self.recorder, self.out)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"leaves {BACKEND} to", result.stderr)
        self.assertFalse(self.out.exists())

    def test_a_branch_is_not_a_pin(self):
        write_workflow(self.recorder, [*LOCKED, f"{BACKEND}=dev"])
        result = run_script(self.recorder, self.out)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a full commit", result.stderr)
        self.assertFalse(self.out.exists())

    def test_a_short_sha_is_not_a_pin(self):
        write_workflow(self.recorder, [*LOCKED, f"{BACKEND}={'b' * 12}"])
        result = run_script(self.recorder, self.out)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a full commit", result.stderr)

    def test_a_sibling_the_job_does_not_clone_is_refused(self):
        write_workflow(self.recorder, LOCKED)
        result = run_script(self.recorder, self.out)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"does not clone {BACKEND}", result.stderr)

    def test_a_name_is_matched_exactly_not_as_a_prefix(self):
        # `codetracer-trace-format-nim` must not satisfy
        # `codetracer-trace-format`, in the job or in the lock.
        write_workflow(self.recorder, ["codetracer-trace-format-nim"])
        write_lock(self.recorder, {"codetracer-trace-format-nim": "1" * 40})
        result = run_script(self.recorder, self.out, "codetracer-trace-format")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not clone codetracer-trace-format,", result.stderr)

    def test_a_missing_job_is_refused(self):
        result = run_script(self.recorder, self.out, job="no-such-job")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no siblings: list", result.stderr)

    def test_a_lock_without_a_self_url_is_refused(self):
        lock = self.recorder / "repro.lock"
        lock.write_text(lock.read_text().replace('self = "true", ', ""))
        result = run_script(self.recorder, self.out)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no self entry", result.stderr)

    def test_an_existing_output_is_not_overwritten(self):
        self.out.write_text("keep\n")
        result = run_script(self.recorder, self.out)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.out.read_text(), "keep\n")


if __name__ == "__main__":
    unittest.main()
