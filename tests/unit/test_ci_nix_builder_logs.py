"""A CI step whose nix build fails must keep the failed builder's log.

Contract: reprobuild-pm spec/Testing/CI-Bootstrap-Failure-Evidence.md,
"Derivation builder logs". When a derivation's builder fails, nix prints
only the last lines of its output; the rest lives in the runner's nix log
store and is lost with the job. Run 41201815981 showed both halves of the
defect this guards: the `Build codetracer ct` step's capture asked `nix log`
for every `.drv` the output named, in sorted order, the first lookup was for
a derivation that had never been built, and that failure ended the capture
before it reached the derivation that failed. No builder log was kept.

These tests run REAL nix builds: a two-derivation fixture whose first
derivation's builder prints a marker and then enough filler lines to push
it out of nix's 25-line failure tail, and fails; the second depends on it,
so nix reports it as `1 dependency failed` -- a derivation with no builder
log, as in the CI run. The failing builder's log can therefore only come
from `nix log`, which is what the capture must do.

The `Build codetracer ct` and `Bootstrap Reprobuild` cases execute the
step's actual `run:` body from ci.yml, extracted with the workflow parser
and with only `${{ github.workspace }}` substituted. One fake each, both
justified by the same reason: the real command builds CodeTracer (or
bootstraps Reprobuild) for hours with CI credentials, and what is under
test is what the STEP does once nix has failed, not that build. The fake
`direnv` (ct step) and fake `dev-exec` (bootstrap step) run the real
failing nix build in place of that work; nothing else is simulated.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from test_ci_reconcile_lock_credentials import job_steps


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
SCRIPT = ROOT / "scripts" / "ci_nix_builder_logs.sh"
MARKER = "NIX_BUILDER_LOG_ROOT_CAUSE_MARKER"

# The marker comes FIRST, then 60 lines: nix's failure report carries only
# the last 25 (its `log-lines` default), so the marker is in the builder log
# and nowhere in the step's own output. The dependent never runs a builder.
# `/bin/sh` is inside the sandbox on NixOS (`sandbox-paths`) and on macOS.
FIXTURE = textwrap.dedent(f"""
    {{ salt }}:
    let
      failing = derivation {{
        name = "nix-builder-logs-failing-${{salt}}";
        system = builtins.currentSystem;
        builder = "/bin/sh";
        args = [ "-c" ''
          echo {MARKER}
          i=0
          while [ $i -lt 60 ]; do echo "filler line $i"; i=$((i + 1)); done
          exit 3
        '' ];
      }};
      dependent = derivation {{
        name = "nix-builder-logs-dependent-${{salt}}";
        system = builtins.currentSystem;
        builder = "/bin/sh";
        args = [ "-c" "echo ${{failing}} > $out" ];
      }};
    in {{ inherit failing dependent; }}
    """)


def step(job: str, name: str):
    matches = [item for item in job_steps(WORKFLOW.read_text(), job)
               if item.name == name]
    if len(matches) != 1:
        raise AssertionError(f"expected one {job}/{name}, got {len(matches)}")
    return matches[0]


class NixFixture:
    """The failing fixture, at a salt that recreates run 41201815981.

    That run's capture took every `.drv` in sorted order and stopped at the
    first `nix log` failure. The salt is chosen so the dependent -- which
    has no log -- sorts before the failing derivation, the order in which
    that capture keeps nothing. Store paths are content hashes, so the
    salt is searched rather than fixed: the paths differ per system.
    """

    def __init__(self, directory: Path):
        self.nix = shutil.which("nix")
        if self.nix is None:
            raise AssertionError("nix is required: these tests run real nix builds")
        self.file = directory / "fixture.nix"
        self.file.write_text(FIXTURE)
        for salt in range(64):
            failing, dependent = (self.instantiate(salt, attr)
                                  for attr in ("failing", "dependent"))
            if dependent < failing:
                self.salt, self.failing, self.dependent = salt, failing, dependent
                return
        raise AssertionError("no salt orders the dependent first in 64 tries")

    def instantiate(self, salt: int, attr: str) -> str:
        return subprocess.run(
            [self.nix, "eval", "--raw", "--impure", "--file", str(self.file),
             "--argstr", "salt", str(salt), f"{attr}.drvPath"],
            check=True, text=True, capture_output=True).stdout.strip()

    def build_command(self) -> str:
        return (f"nix build --impure --no-link --file '{self.file}' "
                f"--argstr salt {self.salt} dependent")


class Scratch(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="ci-nix-builder-logs-")
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.bash = shutil.which("bash")
        self.assertIsNotNone(self.bash, "Bash is required to execute the CI steps")
        self.fixture = NixFixture(self.scratch)
        self.bin = self.scratch / "bin"
        self.bin.mkdir()

    def fake(self, name: str, body: str):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + textwrap.dedent(body).lstrip())
        path.chmod(0o755)

    def env(self, **extra) -> dict[str, str]:
        runner_temp = self.scratch / "runner-temp"
        runner_temp.mkdir(exist_ok=True)
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                   RUNNER_TEMP=str(runner_temp), GITHUB_ENV=str(runner_temp / "env"))
        env.pop("REPRO_PUBLISH_KEY", None)
        env.pop("REPRO_PUBLISH_CERT", None)
        env.update(extra)
        return env

    def builder_logs(self, logs: Path) -> dict[str, str]:
        return {path.name: path.read_text()
                for path in sorted(logs.glob("nix-builder-*.log"))}

    def assert_kept_only_the_failing_builder(self, logs: Path, result):
        output = result.stdout + result.stderr
        kept = self.builder_logs(logs)
        failing = f"nix-builder-{Path(self.fixture.failing).stem}.log"
        self.assertIn(failing, kept, f"failing builder's log not kept: {sorted(kept)}\n{output}")
        self.assertIn(MARKER, kept[failing])
        self.assertEqual(sorted(kept), [failing],
                         "a derivation that never ran a builder was collected")


class BuildCodetracerStepTests(Scratch):
    """The real `Build codetracer ct` run body."""

    def run_step(self, with_collector=True):
        repro_root = self.scratch / "reprobuild"
        (repro_root / "scripts").mkdir(parents=True)
        if with_collector:
            shutil.copy(SCRIPT, repro_root / "scripts" / SCRIPT.name)
        (self.scratch / "codetracer").mkdir()
        # `allow` is bookkeeping; `exec <dir> just build-once` is the build.
        self.fake("direnv", f"""
            [ "$1" = allow ] && exit 0
            if [ "$1" = exec ] && [ "$3" = just ] && [ "$4" = build-once ]; then
              exec {self.fixture.build_command()}
            fi
            echo "unexpected direnv invocation: $*" >&2
            exit 99
            """)
        body = textwrap.dedent(step("test", "Build codetracer ct (via reprobuild)").fields["run"])
        body = body.replace("${{ github.workspace }}", str(repro_root))
        self.assertNotIn("${{", body, "unresolved GitHub expression in run block")
        result = subprocess.run(
            [self.bash, "--noprofile", "--norc", "-eo", "pipefail", "-c", body],
            cwd=repro_root, env=self.env(), text=True, capture_output=True)
        return repro_root / "test-logs", result

    def test_failed_derivation_keeps_its_builder_log(self):
        logs, result = self.run_step()
        output = result.stdout + result.stderr
        # nix's own status, re-raised after the capture.
        self.assertEqual(result.returncode, 1, output)
        step_log = (logs / "ct-build.log").read_text()
        self.assertIn(f"Cannot build '{self.fixture.failing}'", step_log)
        # The condition the issue states: the step's output names the
        # derivation and not the cause.
        self.assertNotIn(MARKER, step_log)
        self.assert_kept_only_the_failing_builder(logs, result)
        # Echoed into the job log too, beside the file.
        self.assertIn(MARKER, result.stderr)

    def test_a_collector_that_cannot_run_does_not_replace_the_status(self):
        logs, result = self.run_step(with_collector=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.builder_logs(logs), {})


class BootstrapStepTests(Scratch):
    """The real `Bootstrap Reprobuild` run body: the job's first dev-exec."""

    def test_failed_dev_shell_build_keeps_its_builder_log(self):
        self.fake("dev-exec", f"""
            [ "$1" = just ] && [ "$2" = bootstrap ] && exec {self.fixture.build_command()}
            touch prep-reached
            exit 0
            """)
        body = textwrap.dedent(step("test", "Bootstrap Reprobuild").fields["run"])
        body = body.replace("${{ github.workspace }}", str(self.scratch))
        (self.scratch / "scripts").mkdir()
        shutil.copy(SCRIPT, self.scratch / "scripts" / SCRIPT.name)
        result = subprocess.run(
            [self.bash, "--noprofile", "--norc", "-eo", "pipefail", "-c", body],
            cwd=self.scratch, env=self.env(), text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse((self.scratch / "prep-reached").exists(),
                         "preparation ran after a failed bootstrap")
        self.assert_kept_only_the_failing_builder(self.scratch / "test-logs", result)


class RunWrapperTests(Scratch):
    """`run`: the form every other nix-driving step uses."""

    def wrapped(self, command: str):
        logs = self.scratch / "test-logs"
        script = (f'out="$(bash "{SCRIPT}" run "{logs}" probe -- sh -c "$1")"\n'
                  'rc=$?\nprintf "stdout=[%s]\\n" "$out"\nexit $rc')
        result = subprocess.run([self.bash, "-c", script, "wrapped", command],
                                env=self.env(), text=True, capture_output=True)
        return logs, result

    def test_failure_keeps_builder_log_status_and_stdout(self):
        logs, result = self.wrapped(f"echo only-stdout; {self.fixture.build_command()}")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        # `$(...)` around the wrapper sees the command's stdout and nothing else.
        self.assertIn("stdout=[only-stdout]", result.stdout)
        self.assertIn(f"Cannot build '{self.fixture.failing}'", result.stderr)
        self.assert_kept_only_the_failing_builder(logs, result)

    def test_failure_without_a_derivation_keeps_nothing(self):
        logs, result = self.wrapped("echo plain failure >&2; exit 7")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.builder_logs(logs), {})

    def test_success_keeps_nothing_and_passes_stdout(self):
        logs, result = self.wrapped("echo fine")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stdout=[fine]", result.stdout)
        self.assertEqual(self.builder_logs(logs), {})


class CollectTests(Scratch):
    """`collect` over an output that also names derivations that did not fail."""

    def test_unavailable_log_is_recorded_and_does_not_stop_the_rest(self):
        build = subprocess.run([self.bash, "-c", self.fixture.build_command()],
                               env=self.env(), text=True, capture_output=True)
        self.assertNotEqual(build.returncode, 0, build.stderr)
        gone = "/nix/store/" + "0" * 32 + "-never-built-here.drv"
        unrelated = "/nix/store/" + "1" * 32 + "-fetched.tar.xz.drv"
        output = self.scratch / "output.log"
        # A failure reported first whose log this host does not have, then
        # the lines a long build is full of -- GC, building, an old-format
        # report of a dependent -- then the real failure.
        output.write_text(
            f"error: Cannot build '{gone}'.\n"
            "       Reason: builder failed with exit code 1.\n"
            f"deleting '{unrelated}'\n"
            f"building '{unrelated}'...\n"
            f"\x1b[31;1merror:\x1b[0m Cannot build '{self.fixture.dependent}'.\n"
            "       Reason: 1 dependency failed.\n"
            + build.stderr)
        logs = self.scratch / "test-logs"
        result = subprocess.run([self.bash, str(SCRIPT), "collect", str(output), str(logs)],
                                env=self.env(), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        kept = self.builder_logs(logs)
        self.assertEqual(sorted(kept), sorted([
            f"nix-builder-{Path(gone).stem}.log",
            f"nix-builder-{Path(self.fixture.failing).stem}.log"]))
        self.assertIn("not available", kept[f"nix-builder-{Path(gone).stem}.log"])
        self.assertIn(MARKER, kept[f"nix-builder-{Path(self.fixture.failing).stem}.log"])

    def test_earlier_nix_wording_is_recognised(self):
        subprocess.run([self.bash, "-c", self.fixture.build_command()],
                       env=self.env(), text=True, capture_output=True)
        output = self.scratch / "output.log"
        output.write_text(
            f"error: builder for '{self.fixture.failing}' failed with exit code 3;\n"
            f"       For full logs, run 'nix log {self.fixture.failing}'.\n")
        logs = self.scratch / "test-logs"
        subprocess.run([self.bash, str(SCRIPT), "collect", str(output), str(logs)],
                       check=True, env=self.env(), text=True, capture_output=True)
        kept = self.builder_logs(logs)
        self.assertEqual(list(kept), [f"nix-builder-{Path(self.fixture.failing).stem}.log"])
        self.assertIn(MARKER, next(iter(kept.values())))


# A command word: at the start of a line or after `$(`, a pipe, `;`, `&&`,
# `||` or the wrapper's own `--`.
NIX_INVOCATION = re.compile(r"(?:^|\$\(|[|;&]|--)\s*(dev-exec|nix|direnv)(?=\s)", re.MULTILINE)


class CoverageTests(unittest.TestCase):
    """Every step of the jobs that upload test-logs/ that drives nix."""

    def test_every_nix_driving_step_keeps_builder_logs(self):
        text = WORKFLOW.read_text()
        checked = []
        for job in ("lint", "test", "nix-build"):
            for item in job_steps(text, job):
                run = item.fields.get("run", "")
                code = "\n".join(line for line in run.splitlines()
                                 if not line.lstrip().startswith("#"))
                if not NIX_INVOCATION.search(code):
                    continue
                checked.append(f"{job}/{item.name}")
                self.assertIn("ci_nix_builder_logs.sh", run,
                              f"{job}/{item.name} drives nix without keeping builder logs")
        # The scan must actually find the steps it exists for.
        for expected in ("lint/Suite case-count baseline and inventory entry set",
                         "lint/just lint", "lint/Nim 2.2.4 lane",
                         "test/Bootstrap Reprobuild",
                         "test/List the repositories CodeTracer's lock clones",
                         "test/Reconcile CodeTracer source dependencies",
                         "test/Build codetracer ct (via reprobuild)",
                         "test/just test", "test/Declare suite coverage",
                         "nix-build/Verify committed Nix inputs",
                         "nix-build/Check the trace-format pin against CodeTracer's lock",
                         "nix-build/nix build"):
            self.assertIn(expected, checked)


if __name__ == "__main__":
    unittest.main()
