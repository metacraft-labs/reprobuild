#!/usr/bin/env python3
"""A build report may only be attributed to the invocation that wrote it.

WHAT THIS PROTECTS
------------------
``repro build --write-report`` writes its post-mortem to a FIXED path under the
project out-dir: ``build-report.json`` on success, ``build-failure-report.json``
on failure. The path carries no identity — nothing in it names the target, the
process or the day — so a file left there by an earlier invocation is, by
existence alone, indistinguishable from one the current invocation produced.

THE DEFECT, MEASURED RATHER THAN IMAGINED
-----------------------------------------
A suite run whose build phase is KILLED never reaches the engine's post-mortem
and writes no failure report at all. ``scripts/run_tests.sh`` nevertheless
found a file at the expected path, printed it under a "Failed actions for
<target>" banner and archived it under that target's name. The file was a day
old and belonged to a different target built by hand in between. What came out
was a confident, well-formatted, entirely fictional failure — a named action,
an exit code, captured stdout — none of it from the run being reported, while
the run's real cause (a timeout, printed two lines earlier) went unread.

An honest absence reported as a specific failure is worse than no report: it
redirects every reader who trusts it. So the absence has to be announced.

WHAT IS ASSERTED, AND WHY IT CANNOT PASS VACUOUSLY
--------------------------------------------------
Cases 1-4 execute the REAL shell library — ``scripts/lib/``
``build_report_attribution.sh``, sourced into a real ``bash`` — against real
files in a temporary directory. Each absence assertion is paired with the
positive case that would be satisfied by the same code doing nothing:

1. a report naming ANOTHER target is neither printed nor archived, and the
   run says plainly that no report was written;
2. a report naming THIS target IS archived and printed — without this, a
   library that archived nothing at all would pass case 1;
3. ``repro_build_report_reset`` removes both reports, which is the one
   mechanism that does not depend on a report's own contents — and (3b) a
   reset that COULD NOT remove them exits non-zero and says so, because
   ``rm -f`` reports success for a file that was never there, and an
   unchecked removal that quietly did nothing would leave "present
   afterwards means written afterwards" resting on nothing;
4. the two together on the killed-build path: reset, no build, collect — the
   stale report is gone before it can be misread, and the absence is
   announced;
5. the SUCCESS report is refused by VALUE too. It does carry a self-naming
   field — ``targetResolution[].selector`` — and the assertion is made
   against the real archived artefact from the run that motivated all of
   this, which names ``test-fixtures`` while sitting under a ``test-builds``
   file name. Believing that field absent is how the second half of the
   defect stayed unfixed.

Case 6 is a COVERAGE check, and it exists because the cases above test a
library that the caller is free to bypass. It asserts that ``run_tests.sh``
both resets and collects through this library, and that no other line of it
names either report file — an inlined second copy of the old logic beside the
call is exactly how this class of fix is usually defeated. Comments are
stripped before matching, because a check satisfied by a commented-out line is
not a check.

Cases 7-9 are why case 6 is not enough on its own. A text scan of the caller
is satisfied by code that is present and never runs: wrapping both calls in
``if false; then … fi`` leaves every assertion in case 6 true, measured. So
these EXTRACT ``repro_build_collection`` from ``run_tests.sh`` and RUN it,
with ``timeout`` shadowed by a shell function standing in for the build, and
assert the outcome rather than the text:

7. against a sandbox holding yesterday's reports, with the build killed:
   nothing archived, the absence announced, yesterday's target never named;
8. the reset fails (a read-only out-dir) and the build MUST NOT run. ``set
   -e`` does not cover this — the caller invokes the function as ``… ||
   exit 1``, which suppresses errexit for the whole body — so the failure has
   to be propagated by hand, and this is what says whether it was;
9. the vacuity control: the stand-in writes reports naming THIS target and
   both must be archived. Without it, a caller that did nothing whatever
   would pass 7 and 8.

NO MOCKS
--------
Real ``bash``, the real library file, the caller's own function extracted from
the real ``run_tests.sh``, real reports on a real filesystem. The one stand-in
is ``timeout``, shadowed so the build can be killed without waiting four hours
for a real one; what is under test is what the caller does around it, and
there is no way to reach the killed-build path without a build that is killed.
"""

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "scripts" / "lib" / "build_report_attribution.sh"
RUN_TESTS = ROOT / "scripts" / "run_tests.sh"

FAILURE_NAME = "build-failure-report.json"
REPORT_NAME = "build-report.json"

# The caller's own function, extracted verbatim so case 7 runs the real thing.
BUILD_COLLECTION_RE = re.compile(
    r"^repro_build_collection\(\) \{\n.*?^\}$", re.MULTILINE | re.DOTALL
)


def _default_out_dir() -> str:
    """The out-dir the library itself names, read from the library.

    Hard-coding it here would let the two drift apart without anything
    saying so, and case 7 would then build its sandbox around a path the
    extracted function never touches — passing while testing nothing.
    """
    found = re.search(
        r'^REPRO_BUILD_REPORT_DIR_DEFAULT="([^"]+)"', LIB.read_text(), re.M
    )
    if found is None:
        raise AssertionError(
            "%s no longer declares REPRO_BUILD_REPORT_DIR_DEFAULT" % LIB
        )
    return found.group(1)


REPRO_OUT_DIR = _default_out_dir()


def write_success_report(path: Path, *selectors: str) -> None:
    """A success report in the shape the engine emits, naming ``selectors``.

    The field is an ARRAY of resolver outcomes, one per selector the CLI was
    given, and it records the bare name rather than the ``.#``-qualified one.
    Both properties are taken from a real report, not from the schema.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "providerInvocations": 1,
                "actions": [],
                "targetResolution": [
                    {
                        "selector": selector,
                        "kind": "resolved",
                        "actionId": "reprobuild.%s.example" % selector,
                        "package": "reprobuild",
                        "targetKind": "collection",
                    }
                    for selector in selectors
                ],
            }
        )
    )


def write_failure_report(path: Path, target: str, action_id: str) -> None:
    """A failure report in the shape the engine emits, naming ``target``."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "schemaId": "reprobuild.build.failure-report.v1",
                "target": target,
                "projectRoot": str(path.parent),
                "exitCode": 1,
                "counts": {"total": 1, "succeeded": 0, "failed": 1},
                "failedActions": [
                    {"id": action_id, "status": "asFailed", "exitCode": 1}
                ],
                "blockedActions": [],
            }
        )
    )


def run_shell(script: str, cwd: Path) -> subprocess.CompletedProcess:
    """Source the real library and run ``script`` against it."""
    body = 'set -uo pipefail\nsource "%s"\n%s' % (LIB, script)
    return subprocess.run(
        ["bash", "-c", body], cwd=str(cwd), capture_output=True, text=True
    )


def strip_shell_comments(text: str) -> str:
    """Drop whole-line and trailing ``#`` comments.

    A check that a file does not MENTION something must not be satisfiable by
    leaving the mention in a comment, nor defeated by one. Quoting is handled
    conservatively: a ``#`` inside single or double quotes is kept.
    """
    out = []
    for line in text.splitlines():
        result = []
        quote = None
        index = 0
        while index < len(line):
            char = line[index]
            if quote is not None:
                result.append(char)
                if char == "\\" and quote == '"' and index + 1 < len(line):
                    index += 1
                    result.append(line[index])
                elif char == quote:
                    quote = None
            elif char in ("'", '"'):
                quote = char
                result.append(char)
            elif char == "#" and (not result or result[-1] in " \t"):
                break
            else:
                result.append(char)
            index += 1
        out.append("".join(result))
    return "\n".join(out)


class BuildReportAttribution(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(LIB.is_file(), "missing library: %s" % LIB)

    # ------------------------------------------------------------------ 1
    def test_a_report_for_another_target_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            logs = root / "logs"
            write_failure_report(
                out / FAILURE_NAME, ".#test-live-tpm-quote", "test-live-tpm-quote"
            )
            done = run_shell(
                'repro_collect_build_reports "%s" ".#test-builds" "%s"'
                % (out, logs),
                root,
            )
            archived = list(logs.glob("build-failure-report-*.json"))
            self.assertEqual(
                archived,
                [],
                "a report belonging to another target was archived as this "
                "target's: %s" % archived,
            )
            self.assertNotIn("Failed actions for", done.stderr)
            self.assertIn("No failure report was written", done.stderr)
            # The refusal must NAME the target the file actually belongs to;
            # a bare "ignored" leaves the reader with no way to find out what
            # they were about to be told.
            self.assertIn(".#test-live-tpm-quote", done.stderr)

    # ------------------------------------------------------------------ 2
    def test_a_report_for_this_target_is_archived(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            logs = root / "logs"
            write_failure_report(
                out / FAILURE_NAME, ".#test-builds", "reprobuild.test.example"
            )
            done = run_shell(
                'repro_collect_build_reports "%s" ".#test-builds" "%s"'
                % (out, logs),
                root,
            )
            archived = sorted(p.name for p in logs.glob("*.json"))
            self.assertEqual(archived, ["build-failure-report-__test_builds.json"])
            self.assertIn("Failed actions for .#test-builds", done.stderr)
            self.assertNotIn("No failure report was written", done.stderr)
            copied = json.loads(
                (logs / "build-failure-report-__test_builds.json").read_text()
            )
            self.assertEqual(copied["target"], ".#test-builds")

    # ----------------------------------------------------------------- 2b
    def test_the_two_spellings_of_one_target_are_one_target(self):
        """``repro build NAME`` records itself as ``.#NAME``; both match.

        Measured: ``repro build test-live-tpm-quote`` and ``repro build
        .#test-live-tpm-quote`` both write ``"target": ".#test-live-tpm-quote"``.
        A caller passing the short spelling must not be told its own report
        belongs to someone else — while a DIFFERENT target still must not
        match, which is the second half below.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            logs = root / "logs"
            write_failure_report(
                out / FAILURE_NAME, ".#test-live-tpm-quote", "test-live-tpm-quote"
            )
            done = run_shell(
                'repro_collect_build_reports "%s" "test-live-tpm-quote" "%s"'
                % (out, logs),
                root,
            )
            self.assertIn("Failed actions for", done.stderr)
            self.assertEqual(len(list(logs.glob("*.json"))), 1)
            # ... and a near-miss is still a miss.
            logs2 = root / "logs2"
            done2 = run_shell(
                'repro_collect_build_reports "%s" "test-live-tpm-quote-2" "%s"'
                % (out, logs2),
                root,
            )
            self.assertIn("No failure report was written", done2.stderr)
            self.assertEqual(list(logs2.glob("*.json")), [])

    # ------------------------------------------------------------------ 3
    def test_reset_removes_both_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            write_failure_report(out / FAILURE_NAME, ".#stale", "stale")
            (out / REPORT_NAME).write_text('{"actions":[]}')
            done = run_shell('repro_build_report_reset "%s"' % out, root)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertFalse((out / FAILURE_NAME).exists())
            self.assertFalse((out / REPORT_NAME).exists())

    # ----------------------------------------------------------------- 3b
    @unittest.skipIf(
        os.geteuid() == 0, "root removes files regardless of directory mode"
    )
    def test_a_reset_that_could_not_clear_says_so(self):
        """``rm -f`` succeeds on a file that was never there.

        So a reset that silently removed nothing would leave the whole
        "present afterwards means written afterwards" argument resting on an
        unchecked command. The postcondition is checked instead.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            write_failure_report(out / FAILURE_NAME, ".#stale", "stale")
            out.chmod(0o500)
            try:
                done = run_shell('repro_build_report_reset "%s"' % out, root)
            finally:
                out.chmod(0o700)
            self.assertNotEqual(done.returncode, 0, done.stderr)
            self.assertIn("Could not clear a previous build report", done.stderr)
            self.assertTrue((out / FAILURE_NAME).exists())

    # ------------------------------------------------------------------ 4
    def test_killed_build_path_end_to_end(self):
        """Reset, run nothing (the killed build), then collect."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            logs = root / "logs"
            write_failure_report(out / FAILURE_NAME, ".#yesterday", "yesterday")
            (out / REPORT_NAME).write_text('{"actions":[]}')
            done = run_shell(
                'repro_build_report_reset "%s"\n'
                'repro_collect_build_reports "%s" ".#test-builds" "%s"'
                % (out, out, logs),
                root,
            )
            self.assertEqual(sorted(p.name for p in logs.glob("*.json")), [])
            self.assertIn("No failure report was written", done.stderr)
            self.assertNotIn("yesterday", done.stderr)

    # ------------------------------------------------------------------ 5
    def test_the_success_report_is_refused_by_value_too(self):
        """The success report DOES name itself, and is checked on it.

        The claim that it carries nothing checkable is what left this half of
        the defect standing. Its ``targetResolution`` array names the
        selectors the invocation was given.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            logs = root / "logs"
            write_success_report(out / REPORT_NAME, "test-fixtures")
            done = run_shell(
                'repro_collect_build_reports "%s" ".#test-builds" "%s"'
                % (out, logs),
                root,
            )
            self.assertEqual(list(logs.glob("build-report-*.json")), [])
            self.assertIn("Ignoring a build report", done.stderr)
            self.assertIn("test-fixtures", done.stderr)
            # The paired positive: the same report, asked for by its own
            # target, IS archived. Without this a library that archived no
            # success report ever would pass the half above.
            logs2 = root / "logs2"
            done2 = run_shell(
                'repro_collect_build_reports "%s" ".#test-fixtures" "%s"'
                % (out, logs2),
                root,
            )
            self.assertEqual(
                sorted(p.name for p in logs2.glob("build-report-*.json")),
                ["build-report-__test_fixtures.json"],
            )
            self.assertNotIn("Ignoring a build report", done2.stderr)

    # ----------------------------------------------------------------- 5b
    def test_the_real_archived_report_from_the_incident_is_refused(self):
        """The artefact that started this, checked rather than described.

        ``test-logs/build-report-__test_builds.json`` was archived under the
        name of a collection whose build was KILLED; the file the suite
        actually copied was the PREVIOUS collection's. The field that says so
        was in it the whole time.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            logs = root / "logs"
            # Reconstructed at the shape and the values the real artefact
            # carries; the real one is 9.6 MB and is not a fixture.
            write_success_report(out / REPORT_NAME, "test-fixtures")
            probe = run_shell(
                'repro_build_report_covers "%s/%s" ".#test-builds" '
                '&& echo COVERS || echo REFUSES' % (out, REPORT_NAME),
                root,
            )
            self.assertIn("REFUSES", probe.stdout)
            self.assertEqual(list(logs.glob("*.json")), [])

    # ------------------------------------------------------------------ 6
    def test_run_tests_sh_has_no_second_answer(self):
        source = strip_shell_comments(RUN_TESTS.read_text())
        # A whole LINE that is a source command, not merely those bytes
        # occurring somewhere: `echo "source scripts/lib/…"` contains the
        # substring and sources nothing.
        self.assertTrue(
            re.search(
                r"^[ \t]*(?:source|\.)[ \t]+"
                r"scripts/lib/build_report_attribution\.sh[ \t]*$",
                source,
                re.M,
            ),
            "%s does not source the attribution library on a line of its own"
            % RUN_TESTS.name,
        )
        self.assertIn("repro_build_report_reset", source)
        self.assertIn("repro_collect_build_reports", source)
        # The reset must precede the collection, or the guard that does not
        # depend on a report's own contents is not in force at the moment the
        # report is read.
        self.assertLess(
            source.index("repro_build_report_reset"),
            source.index("repro_collect_build_reports"),
        )
        # And nothing else in the caller may touch the report paths. This is
        # the assertion an inlined second copy of the old logic defeats.
        for name in (FAILURE_NAME, REPORT_NAME):
            hits = [
                line
                for line in source.splitlines()
                if name in line
            ]
            self.assertEqual(
                hits,
                [],
                "%s names %s directly; report handling must go through "
                "scripts/lib/build_report_attribution.sh so the staleness "
                "guard cannot be bypassed. Offending lines: %s"
                % (RUN_TESTS.name, name, hits),
            )
        # The library must itself be the only place the paths are spelled.
        lib_source = strip_shell_comments(LIB.read_text())
        self.assertTrue(re.search(r"build-failure-report\.json", lib_source))
        self.assertTrue(re.search(r"build-report\.json", lib_source))

    # ------------------------------------------------------------------ 7
    def run_extracted_build_collection(
        self, root: Path, timeout_body: str, selector: str
    ) -> subprocess.CompletedProcess:
        """Run ``run_tests.sh``'s OWN ``repro_build_collection``.

        Case 6 reads the caller as text, and text is satisfied by code that
        never runs: ``if false; then repro_build_report_reset …; fi`` leaves
        every assertion in case 6 true. This executes the function instead,
        so an unreachable call, an inverted order or a deleted one all show
        up as behaviour.
        """
        body = BUILD_COLLECTION_RE.search(RUN_TESTS.read_text())
        self.assertIsNotNone(
            body,
            "could not extract repro_build_collection from %s; the caller's "
            "shape changed and this check must be re-aimed rather than "
            "silently stop testing anything" % RUN_TESTS,
        )
        script = "\n".join(
            [
                "set -uo pipefail",
                'source "%s"' % LIB,
                'exe_ext=""',
                'BUILD_TIMEOUT="4h"',
                # The killed (or failed) build, standing in for a real one.
                "timeout() { %s }" % timeout_body,
                body.group(0),
                'repro_build_collection "%s"' % selector,
                'echo "rc=$?"',
            ]
        )
        return subprocess.run(
            ["bash", "-c", script],
            cwd=str(root),
            capture_output=True,
            text=True,
        )

    def test_the_callers_own_path_refuses_yesterdays_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / REPRO_OUT_DIR
            write_failure_report(out / FAILURE_NAME, ".#yesterday", "yesterday")
            write_success_report(out / REPORT_NAME, "yesterday")
            done = self.run_extracted_build_collection(
                root, "return 124;", ".#test-builds"
            )
            # The function really ran and really took the killed-build path:
            # without this the assertions below are satisfied by nothing
            # having happened at all.
            self.assertIn("rc=124", done.stdout)
            self.assertIn("Timed out building .#test-builds", done.stderr)
            logs = root / "test-logs"
            self.assertEqual(
                sorted(p.name for p in logs.glob("*.json")) if logs.is_dir() else [],
                [],
                "a killed build archived a report it did not write",
            )
            self.assertIn("No failure report was written", done.stderr)
            self.assertNotIn("yesterday", done.stderr)

    @unittest.skipIf(
        os.geteuid() == 0, "root removes files regardless of directory mode"
    )
    def test_the_callers_own_path_stops_when_it_cannot_clear(self):
        """A reset that failed must stop the build, not precede it.

        ``set -e`` does NOT cover this: the caller invokes the function as
        ``… || exit 1``, which suppresses errexit for the whole body, so an
        unpropagated failure would print a warning and then build anyway —
        four hours to produce a report nobody can attribute.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / REPRO_OUT_DIR
            write_failure_report(out / FAILURE_NAME, ".#yesterday", "yesterday")
            out.chmod(0o500)
            try:
                done = self.run_extracted_build_collection(
                    root, 'touch "%s/the-build-ran"; return 124;' % root,
                    ".#test-builds",
                )
            finally:
                out.chmod(0o700)
            self.assertIn("Could not clear a previous build report", done.stderr)
            self.assertNotIn("rc=0", done.stdout)
            self.assertFalse(
                (root / "the-build-ran").exists(),
                "the build ran after a reset that could not clear the reports",
            )

    def test_the_callers_own_path_keeps_the_reports_it_did_write(self):
        """The vacuity control for the case above."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # The stand-in build writes the reports a real failing build
            # writes, naming THIS target, after the reset has run.
            staging = root / "written-by-the-build"
            write_failure_report(
                staging / FAILURE_NAME, ".#test-builds", "an-action"
            )
            write_success_report(staging / REPORT_NAME, "test-builds")
            writer = (
                'mkdir -p "%s"; cp "%s"/*.json "%s"/; return 1;'
                % (REPRO_OUT_DIR, staging, REPRO_OUT_DIR)
            )
            done = self.run_extracted_build_collection(
                root, writer, ".#test-builds"
            )
            self.assertIn("rc=1", done.stdout)
            logs = root / "test-logs"
            self.assertEqual(
                sorted(p.name for p in logs.glob("*.json")),
                [
                    "build-failure-report-__test_builds.json",
                    "build-report-__test_builds.json",
                ],
                done.stderr,
            )
            self.assertIn("Failed actions for .#test-builds", done.stderr)
            self.assertNotIn("No failure report was written", done.stderr)


if __name__ == "__main__":
    unittest.main()
