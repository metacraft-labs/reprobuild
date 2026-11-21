"""The release's Attic push retries transient failures and does not gate the release.

v0.2.26 (Release run 43892878762, attempt 1): the Linux leg built every asset
in 8 hours, then its last step, `attic push`, met HTTP 500
(`InternalServerError`) from atticd for 19 minutes. The step failed, so the leg
failed, so the all-or-nothing publish refused and nothing was released. These
tests pin the fix in place:

  * scripts/release/attic_push_with_retry.sh retries a transient failure with
    exponential backoff (1, 2, 4, 8, 16 minutes), fails at once on a permanent
    or unrecognised one, and bounds every attempt;
  * the push lives in its own job, `publish-nix-cache`, which builds the
    package itself, so a re-run of it repeats nothing the Linux leg did;
  * `publish-release` neither needs nor waits for that job.

The workflow-shape cases took over `ReleaseWorkflowPublishesNixPackage` from
test_release_smoke_dev_exec.py, which pinned the push as a step of the Linux
leg.

WHY THE `attic`, `sleep` AND `nix` HERE ARE FAKES. The script under test is
real and runs unmodified; what it calls is not:

  * `attic`: the failure under test is atticd answering HTTP 500 in a burst,
    which cannot be produced on demand against a real server, and pushing to
    the organisation cache from a unit test would need its write token. The
    fake prints exactly the lines the real client prints for each case (the
    shapes are quoted from the v0.2.26 log and from the attic client's
    `ApiError` Display, client/src/api/mod.rs in
    https://github.com/zhaofengli/attic) and exits 1, as the real client does.
  * `sleep`: the backoff schedule is 31 minutes of waiting. The fake records
    each requested duration and returns, so the schedule itself is asserted
    instead of being skipped by setting the base to zero.
  * `nix`, only in the test that runs the workflow step's own `run:` block:
    it stands in for `nix build nixpkgs#attic-client`, which would otherwise
    download the client; it answers with the directory holding the fake
    `attic`.

`timeout`, `tee`, `grep`, `mktemp` and bash are the real ones, as on the runner.
"""

from pathlib import Path
import os
import re
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release" / "attic_push_with_retry.sh"
RELEASE_YML = ROOT / ".github" / "workflows" / "release-pipeline.yml"
BASH = shutil.which("bash")
TIMEOUT = shutil.which("timeout")

PATH_ = "/nix/store/dshxrj8ghlmmaiwbdxkbrnmscxj732b9-reprobuild-0.2.26"
# The two lines the real client printed on v0.2.26.
ISE = (
    f"❌ {PATH_[len('/nix/store/'):]}: InternalServerError: The server "
    "encountered an internal error or misconfiguration.\n"
    "Error: InternalServerError: The server encountered an internal error "
    "or misconfiguration."
)
UNAUTHORIZED = "Error: Unauthorized: Unauthorized."
NO_SUCH_CACHE = "Error: NoSuchCache: The requested cache does not exist."
CONNECTION = (
    "Error: error sending request for url "
    "(https://cache.metacraft-labs.com/_api/v1/cache-config/ci): "
    "error trying to connect: tcp connect error: Connection refused (os error 111)"
)
BAD_GATEWAY = "Error: HTTP 502 Bad Gateway: <html><body>502</body></html>"
TOO_MANY = "Error: HTTP 429 Too Many Requests: slow down"
FORBIDDEN_HTML = "Error: HTTP 403 Forbidden: <html>denied</html>"
UNKNOWN = "Error: something nobody has seen before"


def _job(name: str) -> str:
    """Return the text of one job of release-pipeline.yml, up to the next job."""
    text = RELEASE_YML.read_text(encoding="utf-8")
    start = text.index(f"\n  {name}:\n") + 1
    nxt = re.search(r"\n  [A-Za-z0-9_-]+:\n", text[start + len(name) + 4:])
    return text[start:] if nxt is None else text[start: start + len(name) + 4 + nxt.start() + 1]


def _steps(job_text: str):
    """Return {name: step_text} for a job, split at its `      - ` markers."""
    steps = {}
    for chunk in re.split(r"\n(?=      - )", job_text)[1:]:
        m = re.search(r"^      - (?:name: (.+)|uses: (.+))$", chunk, re.M)
        if m:
            steps[(m.group(1) or m.group(2)).strip()] = chunk
    return steps


def _run_block(step_text: str) -> str:
    """Return the body of a step's `run: |` block, dedented."""
    m = re.search(r"^        run: \|\n((?:          .*\n|\s*\n)+)", step_text + "\n", re.M)
    if m is None:
        raise AssertionError(f"step has no `run: |` block:\n{step_text}")
    return textwrap.dedent(m.group(1))


@unittest.skipIf(os.name == "nt", "the push runs in a Linux job")
@unittest.skipIf(None in (BASH, TIMEOUT), "needs bash and timeout")
class AtticPushRetryTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="repro-test-attic-push-")
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.calls = self.work / "calls"
        self.sleeps = self.work / "sleeps"
        self.summary = self.work / "summary.md"
        self.plan_dir = self.work / "plan"
        self.plan_dir.mkdir()
        # attic: attempt N prints plan/N.out and exits with plan/N.rc (default
        # 0); plan/N.hang makes it hang, so the per-attempt limit must stop it.
        self._exe("attic", f"""\
            #!{BASH}
            printf '%s\\n' "$*" >> {self.calls}
            if [ "$1" = login ]; then exit 0; fi
            n=$(grep -c '^push ' {self.calls})
            # A busy loop, not `sleep`: the hang must outlive the attempt's
            # limit, and `sleep` is the recording fake on this PATH.
            if [ -f {self.plan_dir}/$n.hang ]; then while :; do :; done; fi
            [ -f {self.plan_dir}/$n.out ] && cat {self.plan_dir}/$n.out
            exit $(cat {self.plan_dir}/$n.rc 2>/dev/null || echo 0)
            """)
        self._exe("sleep", f"""\
            #!{BASH}
            printf '%s\\n' "$1" >> {self.sleeps}
            """)

    def _exe(self, name: str, body: str):
        p = self.bin / name
        p.write_text(textwrap.dedent(body), encoding="utf-8")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)

    def plan(self, *outcomes):
        """One (output, rc) per attempt; output None = hang."""
        for i, (out, rc) in enumerate(outcomes, start=1):
            if out is None:
                (self.plan_dir / f"{i}.hang").write_text("")
            else:
                (self.plan_dir / f"{i}.out").write_text(out + "\n", encoding="utf-8")
            (self.plan_dir / f"{i}.rc").write_text(str(rc))

    def env(self, **extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin}{os.pathsep}{env.get('PATH', '')}"
        env["GITHUB_STEP_SUMMARY"] = str(self.summary)
        env.pop("ATTIC", None)
        for k in ("ATTIC_PUSH_ATTEMPTS", "ATTIC_PUSH_BACKOFF_BASE_SECONDS",
                  "ATTIC_PUSH_ATTEMPT_TIMEOUT_SECONDS"):
            env.pop(k, None)
        env.update(extra)
        return env

    def push(self, *args, **extra):
        return subprocess.run(
            [BASH, str(SCRIPT), *(args or ("ci", PATH_))],
            capture_output=True, text=True, env=self.env(**extra), timeout=120,
        )

    def pushes(self):
        if not self.calls.exists():
            return 0
        return sum(1 for line in self.calls.read_text().splitlines()
                   if line.startswith("push "))

    def waits(self):
        if not self.sleeps.exists():
            return []
        return [int(x) for x in self.sleeps.read_text().split()]

    # -- the cases -------------------------------------------------------

    def test_a_push_that_succeeds_is_tried_once(self):
        r = self.push()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.pushes(), 1)
        self.assertEqual(self.waits(), [])
        self.assertIn(f"push ci {PATH_}", self.calls.read_text())

    def test_the_v0_2_26_burst_of_500s_is_retried_until_it_passes(self):
        self.plan((ISE, 1), (ISE, 1), ("", 0))
        r = self.push()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.pushes(), 3)
        self.assertEqual(self.waits(), [60, 120])
        self.assertIn("::warning::", r.stdout)
        self.assertIn("pushed", self.summary.read_text())

    def test_the_backoff_doubles_from_one_minute_and_six_attempts_is_the_limit(self):
        self.plan(*[(ISE, 1)] * 7)
        r = self.push()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.pushes(), 6)
        self.assertEqual(self.waits(), [60, 120, 240, 480, 960])
        self.assertIn("still failing after 6 attempts", r.stdout)

    def test_an_auth_failure_is_not_retried(self):
        for out in (UNAUTHORIZED, NO_SUCH_CACHE, FORBIDDEN_HTML):
            with self.subTest(out=out):
                self.calls.unlink(missing_ok=True)
                self.sleeps.unlink(missing_ok=True)
                self.plan((out, 1))
                r = self.push()
                self.assertEqual(r.returncode, 1)
                self.assertEqual(self.pushes(), 1)
                self.assertEqual(self.waits(), [])
                self.assertIn("permanent", r.stdout)

    def test_proxy_5xx_429_and_connection_failures_are_transient(self):
        for out in (BAD_GATEWAY, TOO_MANY, CONNECTION):
            with self.subTest(out=out):
                self.calls.unlink(missing_ok=True)
                self.sleeps.unlink(missing_ok=True)
                self.plan((out, 1), ("", 0))
                r = self.push()
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(self.pushes(), 2)
                self.assertEqual(self.waits(), [60])

    def test_a_permanent_error_wins_over_a_500_in_the_same_output(self):
        self.plan((ISE + "\n" + UNAUTHORIZED, 1))
        r = self.push()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.pushes(), 1)

    def test_an_unrecognised_failure_is_not_retried(self):
        self.plan((UNKNOWN, 1))
        r = self.push()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.pushes(), 1)
        self.assertIn("not one this script knows to be transient", r.stdout)

    def test_a_hung_attempt_is_stopped_and_retried(self):
        self.plan((None, 0), ("", 0))
        r = self.push(ATTIC_PUSH_ATTEMPT_TIMEOUT_SECONDS="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.pushes(), 2)
        self.assertIn("did not finish within 1 s", r.stdout)

    def test_usage_errors(self):
        self.assertEqual(self.push("ci").returncode, 2)
        self.assertEqual(self.push("ci", PATH_, ATTIC_PUSH_ATTEMPTS="0").returncode, 2)
        self.assertEqual(self.push("ci", PATH_, ATTIC_PUSH_ATTEMPTS="x").returncode, 2)
        self.assertEqual(self.pushes(), 0)

    def test_the_workflow_step_runs_the_script_with_a_logged_in_client(self):
        """Run the `publish-nix-cache` push step's own `run:` block."""
        steps = _steps(_job("publish-nix-cache"))
        body = _run_block(steps["Push the package to Attic"])
        prefix = self.work / "attic-client"
        (prefix / "bin").mkdir(parents=True)
        shutil.copy2(self.bin / "attic", prefix / "bin" / "attic")
        self._exe("nix", f"""\
            #!{BASH}
            case " $* " in *" nixpkgs#attic-client "*) echo {prefix}; exit 0;; esac
            echo "unexpected nix $*" >&2; exit 1
            """)
        (self.bin / "attic").unlink()  # the step must use the client nix built
        checkout = self.work / "checkout"
        (checkout / "scripts" / "release").mkdir(parents=True)
        shutil.copy2(SCRIPT, checkout / "scripts" / "release" / SCRIPT.name)
        self.plan((ISE, 1), ("", 0))
        r = subprocess.run(
            [BASH, "-c", body], cwd=checkout, capture_output=True, text=True,
            timeout=120,
            env=self.env(ATTIC_CACHE="ci", ATTIC_ENDPOINT="https://cache.example/",
                         ATTIC_TOKEN="t0ken", PACKAGE=PATH_, GITHUB_SHA="abc"),
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertTrue(calls[0].startswith("login "), calls)
        self.assertIn("https://cache.example/ t0ken", calls[0])
        self.assertEqual(self.pushes(), 2)
        self.assertEqual(self.waits(), [60])


class CachePushJobShapeTests(unittest.TestCase):
    """The push is its own job, and the release does not wait for it."""

    def test_the_linux_leg_no_longer_pushes(self):
        leg = _job("build-release")
        self.assertNotIn("attic push", leg)
        self.assertNotIn("attic_push_with_retry", leg)
        self.assertNotIn("Publish the Nix package to the organisation cache", _steps(leg))

    def test_publish_release_does_not_need_or_test_the_cache_job(self):
        pub = _job("publish-release")
        needs = re.search(r"^    needs: \[(.*)\]$", pub, re.M)
        self.assertIsNotNone(needs)
        self.assertNotIn("publish-nix-cache", needs.group(1))
        code = "\n".join(l for l in pub.splitlines() if not l.lstrip().startswith("#"))
        self.assertNotIn("publish-nix-cache", code)

    def test_the_cache_job_builds_the_package_the_consumers_ask_for(self):
        job = _job("publish-nix-cache")
        # `plan` only: it carries the release-lane guard and must take the
        # lane's warm runner first. Nothing a leg built.
        needs = re.findall(r"^    needs: (.*)$", job, re.M)
        self.assertEqual(needs, ["plan"], "it needs `plan` and nothing a leg built")
        self.assertRegex(job, re.compile(r"^    runs-on: \[self-hosted, linux, x64\]$", re.M))
        steps = _steps(job)
        build = _run_block(steps["Build the Nix package of this revision"])
        self.assertIn('"github:${GITHUB_REPOSITORY}/${GITHUB_SHA}#reprobuild"', build)
        self.assertIn("--no-update-lock-file", build)
        push = _run_block(steps["Push the package to Attic"])
        self.assertIn("scripts/release/attic_push_with_retry.sh", push)

    def test_the_build_fetches_with_a_token_minted_in_this_job(self):
        """The package's locked inputs include private repositories.

        The installation token lives one hour; a token minted hours earlier in
        the Linux leg answered 401 to this very fetch (dispatch run
        43294626712). Here it is minted at the start of the job that fetches.
        """
        job = _job("publish-nix-cache")
        mint = job.index("uses: actions/create-github-app-token@v2")
        setup = job.index("uses: metacraft-labs/metacraft-github-actions/setup-nix@dev")
        build = job.index("- name: Build the Nix package of this revision")
        self.assertLess(mint, setup)
        self.assertLess(setup, build)
        self.assertIn("gh-token: ${{ steps.ci_token.outputs.token }}", job[setup:build])

    def test_a_missing_cache_credential_fails_the_job(self):
        push = _steps(_job("publish-nix-cache"))["Push the package to Attic"]
        self.assertIn("ATTIC_TOKEN: ${{ secrets.ATTIC_TOKEN }}", push)
        self.assertIn("ATTIC_CACHE: ${{ vars.ATTIC_CACHE }}", push)
        self.assertRegex(push, r"::error::[^\n]*\n\s*exit 1")

    def test_the_cache_job_starts_no_background_watcher(self):
        setup = _steps(_job("publish-nix-cache"))["Setup Nix"]
        self.assertIn("uses: metacraft-labs/metacraft-github-actions/setup-nix@dev", setup)
        self.assertIn("attic-token:", setup)
        self.assertNotIn("attic-cache:", setup)

    def test_a_failed_push_says_how_to_repeat_it(self):
        steps = _steps(_job("publish-nix-cache"))
        say = steps["Say how to repeat the cache publish"]
        self.assertIn("if: failure()", say)
        self.assertIn("GITHUB_STEP_SUMMARY", say)
        self.assertIn("Re-run failed jobs", say)


if __name__ == "__main__":
    unittest.main()
