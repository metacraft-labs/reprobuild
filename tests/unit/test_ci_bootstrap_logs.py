"""Execute CI's real bootstrap shell body and inspect its artifact contract.

The GitHub job-log service can lose logs, so the Bootstrap Reprobuild step
must retain stdout and stderr in an independently uploaded local file even
when dev-exec fails before just/bootstrap creates its own log. These tests
extract the actual workflow run block using the existing workflow parser,
substitute only github.workspace, and execute it with real Bash and tee in
an isolated real filesystem. No shell body is copied into the test.

The sole fake is dev-exec: provisioning the complete CI environment would
not reliably trigger the early failure under test and requires CI secrets.
It emits distinct stdout/stderr, exits with a chosen status, and records
whether runtime-library preparation was reached. On success it writes the
inner just-bootstrap log too, ensuring the outer capture cannot clobber it.
Another case fails that later preparation, and a directory at the log path
forces a real tee write error. Upload checks inspect the actual Test/Lint
step configuration; no artifact service or S3 credentials are simulated.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from test_ci_reconcile_lock_credentials import job_steps


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
LOG = Path("test-logs/ci-bootstrap.log")


def step(job, name):
    matches = [item for item in job_steps(WORKFLOW.read_text(), job)
               if item.name == name]
    if len(matches) != 1:
        raise AssertionError(f"expected one {job}/{name}, got {len(matches)}")
    return matches[0]


class BootstrapEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ci-bootstrap-evidence-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.bash = shutil.which("bash")
        self.assertIsNotNone(self.bash, "Bash is required to execute the CI step")
        fake = self.bin / "dev-exec"
        fake.write_text(textwrap.dedent(r"""
            #!/bin/sh
            if [ "$1" = just ] && [ "$2" = bootstrap ]; then
              printf 'bootstrap stdout evidence\n'
              printf 'bootstrap stderr evidence\n' >&2
              if [ "$BOOTSTRAP_STATUS" != 0 ]; then
                exit "$BOOTSTRAP_STATUS"
              fi
              mkdir -p test-logs
              printf 'inner bootstrap evidence\n' > test-logs/bootstrap.log
              exit 0
            fi
            if [ "$1" = sh ] && [ "$2" = -c ]; then
              touch prep-reached
              printf 'runtime preparation evidence\n' >&2
              exit "$PREP_STATUS"
            fi
            printf 'unexpected dev-exec invocation: %s\n' "$*" >&2
            exit 99
            """).lstrip())
        fake.chmod(0o755)

    def run_step(self, bootstrap_status=0, prep_status=0):
        body = textwrap.dedent(step("test", "Bootstrap Reprobuild").fields["run"])
        body = body.replace("${{ github.workspace }}", str(self.root))
        self.assertNotIn("${{", body, "unresolved GitHub expression in run block")
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   BOOTSTRAP_STATUS=str(bootstrap_status), PREP_STATUS=str(prep_status))
        return subprocess.run([self.bash, "--noprofile", "--norc", "-eo", "pipefail", "-c", body],
                              cwd=self.root, env=env, text=True, capture_output=True)

    def assert_evidence(self, result, *markers):
        log = self.root / LOG
        self.assertTrue(log.is_file(), f"bootstrap evidence missing: {result.stdout}{result.stderr}")
        retained = log.read_text()
        for marker in markers:
            self.assertIn(marker, retained)
            self.assertIn(marker, result.stdout + result.stderr)

    def test_early_failure_retains_both_streams_and_status(self):
        result = self.run_step(bootstrap_status=47)
        self.assertEqual(result.returncode, 47, result.stdout + result.stderr)
        self.assertFalse((self.root / "prep-reached").exists())
        self.assert_evidence(result, "bootstrap stdout evidence", "bootstrap stderr evidence")

    def test_success_keeps_inner_log_and_runs_preparation(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "prep-reached").is_file())
        self.assertEqual((self.root / "test-logs/bootstrap.log").read_text(),
                         "inner bootstrap evidence\n")
        self.assert_evidence(result, "bootstrap stdout evidence", "bootstrap stderr evidence",
                             "runtime preparation evidence", "LD_LIBRARY_PATH empty")

    def test_later_preparation_failure_is_also_retained(self):
        result = self.run_step(prep_status=61)
        self.assertEqual(result.returncode, 61, result.stdout + result.stderr)
        self.assertTrue((self.root / "prep-reached").is_file())
        self.assert_evidence(result, "bootstrap stdout evidence", "runtime preparation evidence")

    def test_tee_write_failure_cannot_report_success(self):
        (self.root / LOG).mkdir(parents=True)
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class UploadEvidenceTests(unittest.TestCase):
    def test_failure_evidence_uploads_always_run_and_refuse_missing_files(self):
        for job, artifact in (("test", "test-logs"), ("lint", "lint-logs")):
            with self.subTest(job=job):
                upload = step(job, "Upload logs")
                self.assertEqual(upload.fields["if"], "always()")
                self.assertEqual(upload.fields["uses"], "actions/upload-artifact@v4")
                self.assertNotIn("continue-on-error", upload.fields)
                self.assertEqual(upload.maps["with"]["name"], artifact)
                self.assertEqual(upload.maps["with"]["path"], "test-logs/")
                self.assertEqual(upload.maps["with"].get("if-no-files-found"), "error")


if __name__ == "__main__":
    unittest.main()
