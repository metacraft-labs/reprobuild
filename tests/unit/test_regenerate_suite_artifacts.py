"""A stale suite description on `dev` must be recovered, not just reported.

WHY THIS FILE EXISTS

`scripts/check_suite_case_counts.sh` refuses a tree whose checked-in suite
description is stale, and after reprobuild-pm issue 2026-10-01 ("suite
case-count baseline is stale on dev") it no longer blocks the audits behind it
and says whose drift it is. But a gate that only reports leaves `dev` stale
until someone volunteers a regeneration: five consecutive `dev` commits carried
the stale baseline, and every pull request opened in that window inherited the
red. The spec's "Mainline recovery" rule (reprobuild-pm
`spec/Test-Designs/Test-Suite-Architecture-Guidelines.md`, "Suite-Artifact
Staleness") requires CI to open -- or update -- ONE pull request into `dev`
carrying the regeneration, with the drift report in its body, a review marker
when coverage was lost, and a note when the judgement checks are still red.

Three parts are covered:

  * `scripts/regenerate_suite_artifacts.py` -- the regeneration and the pull
    request body -- run for real against tiny git repositories;
  * `.github/workflows/suite-case-counts.yml`'s `regenerate-on-dev` job --
    WHEN it runs, what it may write, and where it may push -- asserted
    textually against the real file;
  * the RETIREMENT of that pull request once it is moot -- `dev` went green
    some other way (job `retire-regeneration-on-dev`), or went red for a
    reason the two artifacts do not explain (the regeneration found nothing
    to do) -- through `scripts/retire_regeneration_pr.sh`, asserted textually.
    An open regeneration pull request that nobody needs is a stale proposal
    to rewrite tracked artifacts, and the next stale push would reuse it.

WHAT IS AND IS NOT MOCKED

One script. The fixture is a real git repository with a two-entry
`repro_tests.nim`, two Nim sources, the real scanner, the real gate script and
the artifacts they generate, so each case runs in milliseconds instead of the
minute a scan of the real tree costs.

`scripts/check_bare_skips.py` is replaced in the fixture by a stand-in, and
that is forced rather than chosen: the real lint refuses on purpose to compare
a corpus smaller than its floors (1700 sources, 9800 cases), because a small
scan would report baseline rows as fixed. What these cases need from it is
only that the regeneration RUNS it after regenerating, carries its red output
into the pull request body, and never writes its baseline -- all three are
properties of the regeneration, not of the lint, and the stand-in exercises
them through the same path and exit-status contract. One case also appends
a stand-in regeneration command that writes the bare-skips baseline: the real
commands never do, so without it the guard that restores a judgement file
and refuses would be unexercised. The workflow
half reads the YAML with line/indentation matching rather than a YAML parser,
because PyYAML is not available in every interpreter this suite runs under; it
looks only at the one job it is about and fails rather than guesses when that
job is absent.
"""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
REGENERATE = Path("scripts/regenerate_suite_artifacts.py")
INVENTORY = Path("scripts/reprobuild_suite_inventory.py")
GATE = Path("scripts/check_suite_case_counts.sh")
BARE_SKIPS = Path("scripts/check_bare_skips.py")
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "suite-case-counts.yml"
RETIRE = Path("scripts/retire_regeneration_pr.sh")

STATIC_COUNTS = Path("scripts/reprobuild-suite-static-case-counts.tsv")
SOURCE_INVENTORY = Path(
    "benchmarks/reports/reprobuild-suite-m0-inventory-sources.json"
)
SHAPE_PARITY = Path("scripts/reprobuild-test-shape-parity.tsv")
# Files that record a JUDGEMENT (or are produced by the Nim edge generator)
# rather than a fact a source scan can re-derive. The regeneration must never
# write any of them.
JUDGEMENT_FILES = (
    Path("scripts/bare-skips-baseline.tsv"),
    Path("scripts/uninvoked-shell-tests-baseline.txt"),
    Path("repro_tests.nim"),
    SHAPE_PARITY,
)

STANDING_BRANCH = "automation/regenerate-suite-artifacts"
REVIEW_MARKER = "Needs review: coverage lost"
STILL_RED_HEADING = "Still red after regeneration"
EXIT_CHANGED = 0
EXIT_UNCHANGED = 3

TEST_SPEC = (
    "  TestSpec(\n"
    '    source: "{source}",\n'
    '    binary: "build/test-bin/{stem}",\n'
    "    defines: @[],\n"
    "    requiresReproBinary: false,\n"
    "    extraPassC: @[],\n"
    "    extraPassL: @[],\n"
    "    targetOs: soAny,\n"
    "    selfInterposes: false),\n"
)
SOURCES = ("tests/unit/t_regen_a.nim", "tests/unit/t_regen_b.nim")


# Stand-in for scripts/check_bare_skips.py (see the header for why the real
# lint cannot run on a fixture). Red, with the given message, while the
# sentinel file beside it exists.
BARE_SKIPS_STAND_IN = """\
import pathlib, sys
red = pathlib.Path(__file__).with_name("bare-skips-fixture-red")
if red.exists():
    print(red.read_text(encoding="utf-8"), file=sys.stderr)
    sys.exit(1)
print("check_bare_skips (fixture stand-in): every bare skip is baselined")
"""


def nim_source(cases):
    body = "".join(
        f'  test "case {index}":\n    check {index} + 1 == {index + 1}\n'
        for index in range(cases)
    )
    return 'import std/unittest\n\nsuite "regeneration":\n' + body


class RegenerationFixture(unittest.TestCase):
    """A real (tiny) reprobuild-shaped git repository with a clean commit."""

    def setUp(self):
        self.env = dict(os.environ)
        self.env.update(
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_SYSTEM=os.devnull,
            GIT_AUTHOR_NAME="Regeneration Test",
            GIT_AUTHOR_EMAIL="regeneration@example.invalid",
            GIT_COMMITTER_NAME="Regeneration Test",
            GIT_COMMITTER_EMAIL="regeneration@example.invalid",
            GIT_TERMINAL_PROMPT="0",
            # Every script here resolves `${PYTHON:-python3}`; pin it to this
            # interpreter so the result does not depend on a `python3` being
            # on PATH (it is not, outside the dev shell).
            PYTHON=sys.executable,
        )
        for leaked in (
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "SUITE_CASE_COUNTS_BASE",
            "PRE_COMMIT_FROM_REF",
        ):
            self.env.pop(leaked, None)
        self.root = Path(tempfile.mkdtemp(prefix="suite-regeneration-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.work = self.root / "work"
        self.work.mkdir()
        self.body = self.root / "pr-body.md"
        self.title = self.root / "pr-title.txt"
        self.make_clean_repo()

    def git(self, *args, strip=True):
        result = subprocess.run(
            ["git", *args],
            cwd=str(self.work),
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip() if strip else result.stdout

    def run_python(self, script, *args):
        return subprocess.run(
            [sys.executable, str(script), *args],
            cwd=str(self.work),
            capture_output=True,
            text=True,
            env=self.env,
        )

    def regenerate(self):
        return self.run_python(
            REGENERATE, str(self.body), "--title-file", str(self.title)
        )

    def set_cases(self, source, cases):
        (self.work / source).write_text(nim_source(cases), encoding="utf-8")

    def make_clean_repo(self):
        self.git("init", "-q", "-b", "dev")
        (self.work / "scripts").mkdir()
        for script in (INVENTORY, GATE, SHAPE_PARITY):
            shutil.copy2(REPO_ROOT / script, self.work / script)
        (self.work / BARE_SKIPS).write_text(BARE_SKIPS_STAND_IN, encoding="utf-8")
        (self.work / "scripts" / "bare-skips-baseline.tsv").write_text(
            "# fixture bare-skip baseline\n"
            f"{SOURCES[1]}\tskipped case\t1\n",
            encoding="utf-8",
        )
        # Copied only when it exists, so that BEFORE the fix every case below
        # fails on the missing script -- the defect -- rather than erroring in
        # the fixture.
        if (REPO_ROOT / REGENERATE).is_file():
            shutil.copy2(REPO_ROOT / REGENERATE, self.work / REGENERATE)
        (self.work / "tests" / "unit").mkdir(parents=True)
        (self.work / "repro_tests.nim").write_text(
            "const reprobuildTestSpecs*: seq[TestSpec] = @[\n"
            + "".join(
                TEST_SPEC.format(source=source, stem=Path(source).stem)
                for source in SOURCES
            )
            + "]\nconst pythonTestPaths*: seq[string] = @[\n]\n",
            encoding="utf-8",
        )
        (self.work / "scripts" / "uninvoked-shell-tests-baseline.txt").write_text(
            "# fixture: no uninvoked shell test scripts\n", encoding="utf-8"
        )
        for source in SOURCES:
            self.set_cases(source, 2)
        for flag in ("--write-static-case-counts", "--write-inventory-sources"):
            result = self.run_python(INVENTORY, flag)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.git("add", "-A")
        self.git("commit", "-qm", "clean")
        # Positive control: the fixture starts green on every check the
        # regeneration re-runs, so any red below is what the case changed.
        gate = subprocess.run(
            ["bash", str(GATE)],
            cwd=str(self.work),
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertEqual(gate.returncode, 0, gate.stdout + gate.stderr)
        result = self.run_python(BARE_SKIPS)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def commit_stale(self, source, cases):
        """Land a case-count change WITHOUT regenerating -- the defect."""
        self.set_cases(source, cases)
        self.git("commit", "-qam", "change cases, forget the artifacts")
        return self.git("rev-parse", "--short", "HEAD")

    def changed_paths(self):
        """Every modified or untracked path, not just the expected two."""
        listing = self.git(
            "status", "--porcelain", "-z", "--untracked-files=all", strip=False
        )
        return {entry[3:] for entry in listing.split("\0") if entry}

    def snapshot(self, paths):
        return {path: (self.work / path).read_bytes() for path in paths}


class RegenerationTests(RegenerationFixture):
    def test_a_stale_tree_is_regenerated_and_the_body_names_the_source(self):
        short = self.commit_stale(SOURCES[0], 3)
        result = self.regenerate()
        self.assertEqual(result.returncode, EXIT_CHANGED, result.stdout + result.stderr)
        # Both artifacts were rewritten, and the tree is now green.
        self.assertEqual(
            self.changed_paths(), {str(STATIC_COUNTS), str(SOURCE_INVENTORY)}
        )
        for flag in ("--check-static-case-counts", "--check-inventory"):
            check = self.run_python(INVENTORY, flag)
            self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        body = self.body.read_text(encoding="utf-8")
        self.assertIn(SOURCES[0], body)
        self.assertIn("2 -> 3", body)
        self.assertIn(short, body)
        # The commands it ran are the ones the refusal prints.
        self.assertIn("--write-static-case-counts", body)
        self.assertIn("--write-inventory-sources", body)
        self.assertNotIn(REVIEW_MARKER, body)
        self.assertNotIn(STILL_RED_HEADING, body)
        title = self.title.read_text(encoding="utf-8")
        self.assertEqual(title.count("\n"), 1 if title.endswith("\n") else 0)
        self.assertIn(short, title)
        self.assertRegex(title, r"^[a-z]+(\([a-z-]+\))?: ")

    def test_a_clean_tree_exits_3_and_writes_nothing(self):
        tracked = (STATIC_COUNTS, SOURCE_INVENTORY)
        before = self.snapshot(tracked)
        result = self.regenerate()
        self.assertEqual(
            result.returncode, EXIT_UNCHANGED, result.stdout + result.stderr
        )
        self.assertEqual(self.snapshot(tracked), before)
        self.assertEqual(self.changed_paths(), set())
        self.assertFalse(self.body.exists())

    def test_a_decrease_marks_the_body_as_needing_review(self):
        self.commit_stale(SOURCES[0], 1)
        result = self.regenerate()
        self.assertEqual(result.returncode, EXIT_CHANGED, result.stdout + result.stderr)
        body = self.body.read_text(encoding="utf-8")
        self.assertIn(REVIEW_MARKER, body)
        self.assertIn("COVERAGE LOST", body)
        # Prominent: ahead of the drift report, not buried after it.
        self.assertLess(body.index(REVIEW_MARKER), body.index("COVERAGE LOST"))
        self.assertIn("coverage lost", self.title.read_text(encoding="utf-8").lower())

    def test_an_undeclared_source_is_marked_as_needing_review(self):
        """Dropping an edge is `RECORDED BUT NO LONGER DECLARED` / lost."""
        repro_tests = self.work / "repro_tests.nim"
        text = repro_tests.read_text(encoding="utf-8")
        stem = Path(SOURCES[0]).stem
        repro_tests.write_text(
            text.replace(TEST_SPEC.format(source=SOURCES[0], stem=stem), ""),
            encoding="utf-8",
        )
        (self.work / SOURCES[0]).unlink()
        self.git("commit", "-qam", "drop a test edge, forget the artifacts")
        result = self.regenerate()
        self.assertEqual(result.returncode, EXIT_CHANGED, result.stdout + result.stderr)
        body = self.body.read_text(encoding="utf-8")
        self.assertIn(REVIEW_MARKER, body)
        self.assertIn("RECORDED BUT NO LONGER DECLARED", body)

    def test_the_judgement_baselines_are_never_written(self):
        self.commit_stale(SOURCES[0], 3)
        # A bare skip the baseline does not record, and a Nim test source no
        # edge enrols: both stay red, because fixing them is a judgement
        # (record the skip, enrol or delete the file) the automation must not
        # make on anyone's behalf.
        (self.work / "scripts" / "bare-skips-fixture-red").write_text(
            "new bare skip: tests/unit/t_regen_b.nim: another skip\n",
            encoding="utf-8",
        )
        orphan = "tests/unit/t_regen_orphan.nim"
        (self.work / orphan).write_text(nim_source(1), encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-qm", "an unrecorded bare skip and an orphan")
        before = self.snapshot(JUDGEMENT_FILES)
        result = self.regenerate()
        self.assertEqual(result.returncode, EXIT_CHANGED, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(JUDGEMENT_FILES), before)
        self.assertEqual(
            self.changed_paths(), {str(STATIC_COUNTS), str(SOURCE_INVENTORY)}
        )
        body = self.body.read_text(encoding="utf-8")
        self.assertIn(STILL_RED_HEADING, body)
        self.assertIn(orphan, body)
        self.assertIn("another skip", body)


class JudgementGuardTests(RegenerationFixture):
    """The restore guard, for a regeneration command that oversteps.

    The real regeneration commands never write a judgement file, so the guard
    is driven here through one stand-in command appended to the module's
    REGENERATIONS (justified in the header): a command that writes the
    bare-skips baseline, as a future scanner flag mistakenly could.
    """

    def test_a_judgement_file_written_by_a_regeneration_is_restored(self):
        self.commit_stale(SOURCES[0], 3)
        rogue = self.work / "scripts" / "fixture_rogue_regeneration.py"
        rogue.write_text(
            "import pathlib\n"
            "pathlib.Path('scripts/bare-skips-baseline.tsv').write_text("
            "'silently accepted\\n', encoding='utf-8')\n",
            encoding="utf-8",
        )
        spec = importlib.util.spec_from_file_location(
            "regenerate_suite_artifacts_guard", self.work / REGENERATE
        )
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        # Loading it puts the fixture's scripts/ on sys.path and imports the
        # fixture's scanner by name; undo both so no later case sees them.
        saved_path = list(sys.path)
        saved_scanner = sys.modules.pop("reprobuild_suite_inventory", None)

        def unload():
            sys.path[:] = saved_path
            sys.modules.pop(spec.name, None)
            sys.modules.pop("reprobuild_suite_inventory", None)
            if saved_scanner is not None:
                sys.modules["reprobuild_suite_inventory"] = saved_scanner

        self.addCleanup(unload)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        module.REGENERATIONS = module.REGENERATIONS + (
            (STATIC_COUNTS, "python3 scripts/fixture_rogue_regeneration.py"),
        )
        before = self.snapshot(JUDGEMENT_FILES)
        status = module.main(
            [str(self.body), "--title-file", str(self.title),
             "--repo-root", str(self.work)]
        )
        self.assertEqual(status, module.EXIT_ERROR)
        self.assertEqual(self.snapshot(JUDGEMENT_FILES), before)
        self.assertFalse(self.body.exists())


def job_block(text, job):
    """The lines of `jobs.<job>`, from its key to the next two-space key."""
    lines = text.splitlines()
    try:
        start = lines.index(f"  {job}:")
    except ValueError:
        raise AssertionError(f"job `{job}` not found in {WORKFLOW.name}")
    block = [lines[start]]
    for line in lines[start + 1 :]:
        if re.match(r"^  \S", line) or re.match(r"^\S", line):
            break
        block.append(line)
    return block


def mapping_under(block, key, indent):
    """`key:`'s direct children as {name: value}, for a flat mapping."""
    prefix = " " * indent
    try:
        start = block.index(f"{prefix}{key}:")
    except ValueError:
        raise AssertionError(f"`{key}:` not found at indent {indent}")
    children = {}
    child_prefix = prefix + "  "
    for line in block[start + 1 :]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(child_prefix) or line.startswith(child_prefix + " "):
            if line.startswith(child_prefix + " "):
                raise AssertionError(f"`{key}:` is not a flat mapping: {line!r}")
            break
        name, _, value = line.strip().partition(":")
        children[name] = value.strip()
    return children


def code_lines(block):
    """Block lines with YAML/shell comments dropped, so prose cannot satisfy
    or trip an assertion about what the job DOES."""
    return [line for line in block if not line.lstrip().startswith("#")]


def steps_of(block):
    """`steps:` entries of a job as lists of lines, one list per `- ` item."""
    steps, current = [], None
    for line in block:
        if re.match(r"^      - ", line):
            current = [line]
            steps.append(current)
        elif current is not None and (line.startswith("        ") or not line.strip()):
            current.append(line)
        elif current is not None:
            current = None
    return steps


def assert_acts_only_for_the_dev_tip(case, block):
    """Every step that writes (runs `gh` or a script) waits on the tip check.

    Runs in the shared concurrency group are serialised but not ordered by
    commit, so an older push's job may start after a newer one's. Unguarded,
    it would overwrite the newer regeneration or close the pull request the
    newer red push opened.
    """
    steps = [code_lines(step) for step in steps_of(block)]
    tip = [step for step in steps if any("id: tip" in line for line in step)]
    case.assertEqual(len(tip), 1, "the job has no `tip` step")
    tip_code = "\n".join(tip[0])
    # Captured whole, not piped: under the default `bash -e` (no pipefail) a
    # failed query piped into `cut` would read as "dev moved on" and skip.
    case.assertIn(
        'listing="$(git ls-remote --exit-code origin refs/heads/dev)"', tip_code
    )
    case.assertNotRegex(tip_code, r"ls-remote[^\n]*\|")
    case.assertIn('if [ "${tip}" = "${GITHUB_SHA}" ]; then', tip_code)
    case.assertIn('echo "current=true" >> "${GITHUB_OUTPUT}"', tip_code)
    acting = [
        step
        for step in steps
        if step is not tip[0]
        and any(
            re.search(r"\b(gh|git push|python3|bash) ", line)
            or "steps.regenerate.outputs" in line
            for line in step
        )
    ]
    case.assertTrue(acting, "no acting step found")
    tip_index = steps.index(tip[0])
    for step in acting:
        case.assertGreater(steps.index(step), tip_index, step[0])
        condition = [line for line in step if re.match(r"^        if: ", line)]
        case.assertEqual(len(condition), 1, step[0])
        # Directly, or through a step that is itself gated on the tip.
        case.assertRegex(
            condition[0],
            r"steps\.(tip\.outputs\.current == 'true'|regenerate\.outputs\.changed == 'true')",
        )


class RegenerateJobTests(unittest.TestCase):
    """The recovery job, against the real workflow file."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.block = job_block(cls.text, "regenerate-on-dev")
        cls.code = "\n".join(code_lines(cls.block))

    def test_it_runs_only_when_the_gate_fails_on_a_push_to_dev(self):
        self.assertRegex(self.code, r"(?m)^    needs: suite-case-counts$")
        condition = re.search(r"(?m)^    if: (.+)$", self.code)
        self.assertIsNotNone(condition, "the job has no `if:`")
        terms = {term.strip() for term in condition.group(1).split("&&")}
        self.assertEqual(
            terms,
            {
                "failure()",
                "github.event_name == 'push'",
                "github.ref == 'refs/heads/dev'",
            },
        )

    def test_it_holds_exactly_the_two_write_permissions(self):
        self.assertEqual(
            mapping_under(self.block, "permissions", 4),
            {"contents": "write", "pull-requests": "write"},
        )
        # The workflow default stays read-only, so the GATE job never holds
        # a write token.
        self.assertRegex(self.text, r"(?m)^permissions:\n  contents: read\n")

    def test_it_checks_out_the_failing_commit_and_runs_the_script(self):
        self.assertIn("ref: ${{ github.sha }}", self.code)
        self.assertIn(f"python3 {REGENERATE}", self.code)

    def test_it_pushes_only_the_standing_branch_never_dev(self):
        self.assertRegex(
            self.code, rf"(?m)^      STANDING_BRANCH: {re.escape(STANDING_BRANCH)}$"
        )
        pushes = [
            line.strip() for line in self.code.splitlines() if "git push" in line
        ]
        self.assertTrue(pushes, "the job never pushes")
        for push in pushes:
            self.assertTrue(
                push.endswith('"HEAD:refs/heads/${STANDING_BRANCH}"'), push
            )
            self.assertNotRegex(push, r"\bdev\b")
            self.assertNotRegex(push, r"\bHEAD\s*$")

    def test_it_reuses_one_pull_request_into_dev(self):
        self.assertRegex(
            self.code,
            r'gh pr list --head "\$\{STANDING_BRANCH\}" --base dev --state open',
        )
        self.assertIn("gh pr edit", self.code)
        self.assertRegex(self.code, r"gh pr create --base dev")
        self.assertIn("GH_TOKEN: ${{ github.token }}", self.code)

    def test_it_never_edits_a_fork_s_identically_named_pull_request(self):
        # `--head` matches a branch NAME; the lookup feeding `gh pr edit` must
        # keep only same-repository pull requests from exactly our branch.
        self.assertNotIn("--jq", self.code)
        self.assertIn("isCrossRepository == false", self.code)
        self.assertIn('jq -r --arg branch "${STANDING_BRANCH}"', self.code)
        self.assertRegex(self.code, r"\.headRefName == \$branch")
        # A failed lookup must not read as "none open" and create a second
        # pull request: the step that pipes `gh pr list` sets pipefail first.
        lookup = self.code.index("gh pr list")
        self.assertIn("set -o pipefail", self.code[:lookup].rsplit("run: |", 1)[1])

    def test_it_acts_only_while_its_commit_is_the_tip_of_dev(self):
        assert_acts_only_for_the_dev_tip(self, self.block)

    def test_no_trigger_was_added_on_agents(self):
        # Policy: `agents` has no CI. Its only legitimate mention in `on:` is
        # the pull_request exclusion.
        on_block = self.text.split("\non:\n", 1)[1].split("\n\n", 1)[0]
        for line in on_block.splitlines():
            if "agents" in line:
                self.assertIn("branches-ignore", line)


def without_comments(text):
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def assert_never_pushes_dev(case, code):
    """No `git push` and no ref deletion may name `dev`."""
    for line in code.splitlines():
        if "git push" in line or "--delete" in line:
            case.assertNotRegex(line, r"\bdev\b", line)


class RetireJobTests(unittest.TestCase):
    """The moot-PR retirement job, against the real workflow file."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.block = job_block(cls.text, "retire-regeneration-on-dev")
        cls.code = "\n".join(code_lines(cls.block))

    def test_it_runs_only_when_the_gate_passes_on_a_push_to_dev(self):
        self.assertRegex(self.code, r"(?m)^    needs: suite-case-counts$")
        condition = re.search(r"(?m)^    if: (.+)$", self.code)
        self.assertIsNotNone(condition, "the job has no `if:`")
        terms = {term.strip() for term in condition.group(1).split("&&")}
        self.assertEqual(
            terms,
            {
                "success()",
                "github.event_name == 'push'",
                "github.ref == 'refs/heads/dev'",
            },
        )

    def test_it_holds_exactly_the_two_write_permissions(self):
        self.assertEqual(
            mapping_under(self.block, "permissions", 4),
            {"contents": "write", "pull-requests": "write"},
        )

    def test_it_retires_through_the_script_naming_the_green_sha(self):
        self.assertRegex(
            self.code, rf"(?m)^      STANDING_BRANCH: {re.escape(STANDING_BRANCH)}$"
        )
        self.assertRegex(self.code, rf'bash {re.escape(str(RETIRE))} "\$\{{DEV_SHA\}}"')
        self.assertIn("DEV_SHA: ${{ github.sha }}", self.code)
        self.assertIn("GH_TOKEN: ${{ github.token }}", self.code)

    def test_it_acts_only_while_its_commit_is_the_tip_of_dev(self):
        assert_acts_only_for_the_dev_tip(self, self.block)

    def test_it_never_touches_dev(self):
        self.assertNotIn("git push", self.code)
        assert_never_pushes_dev(self, self.code)

    def test_the_regeneration_retires_when_there_is_nothing_to_regenerate(self):
        regenerate = "\n".join(
            code_lines(job_block(self.text, "regenerate-on-dev"))
        )
        arm = re.search(r"(?ms)^\s*3\)(.*?);;", regenerate)
        self.assertIsNotNone(arm, "the regeneration has no exit-3 arm")
        self.assertIn(f"bash {RETIRE}", arm.group(1))
        self.assertIn("GH_TOKEN: ${{ github.token }}", regenerate)


class RetireScriptTests(unittest.TestCase):
    """What the retirement may close: only OUR standing branch's PRs."""

    @classmethod
    def setUpClass(cls):
        cls.code = without_comments((REPO_ROOT / RETIRE).read_text(encoding="utf-8"))

    def test_it_lists_only_open_prs_from_the_standing_branch_into_dev(self):
        self.assertRegex(
            self.code,
            r'gh pr list --head "\$\{branch\}" --base dev --state open',
        )
        # `--head` matches a branch NAME, so a fork's identically named branch
        # would match too; the filter keeps same-repository PRs whose head is
        # exactly the standing branch.
        self.assertIn("isCrossRepository == false", self.code)
        self.assertRegex(self.code, r'\.headRefName == \$branch')

    def test_the_branch_must_be_the_automation_namespace(self):
        self.assertRegex(self.code, r'STANDING_BRANCH:\?')
        self.assertRegex(self.code, r"(?m)^\s*automation/\*\)")

    def test_it_closes_with_a_comment_and_deletes_only_the_head_branch(self):
        closes = [line for line in self.code.splitlines() if "gh pr close" in line]
        self.assertEqual(len(closes), 1, closes)
        self.assertIn("--delete-branch", closes[0])
        self.assertIn("--comment", self.code)
        self.assertNotIn("git push", self.code)
        assert_never_pushes_dev(self, self.code)

    def test_no_open_pr_is_a_no_op(self):
        self.assertRegex(
            self.code, r'(?ms)if \[ -z "\$\{numbers\}" \]; then.*?exit 0'
        )


class SingleSourceTests(unittest.TestCase):
    """The regeneration runs the commands the refusal prints, not copies."""

    def test_the_gate_prints_the_scanner_s_commands(self):
        spec = importlib.util.spec_from_file_location(
            "reprobuild_suite_inventory_regeneration", REPO_ROOT / INVENTORY
        )
        assert spec is not None and spec.loader is not None
        inventory = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = inventory
        spec.loader.exec_module(inventory)
        gate = (REPO_ROOT / GATE).read_text(encoding="utf-8")
        assignments = dict(re.findall(r'(?m)^(\w+)="([^"]*)"$', gate))
        inventory_path = assignments["inventory"]

        def expand(name):
            return assignments[name].replace("${inventory}", inventory_path)

        self.assertEqual(
            expand("regenerate"), inventory.STATIC_CASE_COUNTS_REGENERATE_COMMAND
        )
        self.assertEqual(
            expand("regenerate_entry_set"),
            inventory.SOURCE_INVENTORY_REGENERATE_COMMAND,
        )
        regenerate = (REPO_ROOT / REGENERATE).read_text(encoding="utf-8")
        self.assertIn("STATIC_CASE_COUNTS_REGENERATE_COMMAND", regenerate)
        self.assertIn("SOURCE_INVENTORY_REGENERATE_COMMAND", regenerate)


if __name__ == "__main__":
    unittest.main()
