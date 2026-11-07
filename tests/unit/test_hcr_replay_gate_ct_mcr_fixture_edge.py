#!/usr/bin/env python3
"""The replay gate's `ct-mcr` is a build-graph edge its execute edge depends on.

Regression test for reprobuild-pm issue
`2026-09-25-hcr-replay-gate-needs-a-ct-mcr-no-edge-builds`:
`tests/e2e/hcr-linux-direct/t_e2e_hcr_linux_replay_of_patched_recording.nim`
records and replays with `ct-mcr`, and read it from a hard-coded sibling path
(`../codetracer-native-recorder/ct_cli/ct_cli`) that nothing in this
repository's build graph produced. Every host that had not built the recorder
by hand failed the gate at `require fileExists(ctMcr)` -- a red HCR gate for a
reason that has nothing to do with HCR.

`Test-Fixtures-In-Build-Graph.md`, Principles 1-3, is the expectation this
holds the tree to:

  1. the binary the test needs at run time is produced by a build-graph edge;
  2. the test's EXECUTE edge depends on that edge -- in this repository that
     is a `testFixtureArtifacts` row in `repro.nim`, which the build block
     turns into the execute edge's `requiredBinaries` (the path, a typed
     input) and `deps` (the action id, an ordering contract);
  3. the test resolves the artifact where that edge puts it and, when it is
     missing, names the edge.

Plus the cross-repo half (metacraft-dev-guidelines
`policies/cross-repo-builds.md` §2.3 / §5): the edge builds the recorder with
the RECORDER'S recipe in the RECORDER'S dev shell, locates the checkout
through `$CT_CODETRACER_NATIVE_RECORDER_SIBLING`, and the HCR lane -- which
runs the gate through its Justfile recipe, not through the graph -- builds the
same fixture first.

HOW IT GOES RED ON THE UNFIXED TREE. At reprobuild bfe4d3f8, `repro.nim` has no
`testFixtureArtifacts` row for the gate, so
`test_the_gate_execute_edge_depends_on_an_edge_that_produces_ct_mcr` fails
with "depends on no edge that produces ct-mcr"; the gate resolves the
hard-coded sibling path, so the lookup arms fail too.

WHY A SOURCE-LEVEL CHECK. The lowered graph is the stronger witness, but
lowering this repository's `repro.nim` compiles a provider over ~1,800 test
specs, and on the host where this issue was first worked that provider died
with exit 139 on the clean and the patched tree alike, so a graph-based check
could not tell the two apart. The table `repro.nim` lowers from is read here
instead, by the same text-parsing approach
`tests/unit/test_graph_owned_test_artifacts.py` uses for the same table. Every
assertion is parameterised on the TEXT it checks, and each has a mutation arm
that re-runs it against a copy with the property removed and requires it to
fail -- an assertion that cannot go red proves nothing.

NO MOCKS: the inputs are the real `repro.nim`, the real gate source, the real
fixture script and the real Justfile.
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

GATE_SOURCE = (
    "tests/e2e/hcr-linux-direct/t_e2e_hcr_linux_replay_of_patched_recording.nim"
)
GATE_RECIPE = "e2e_hcr_linux_replay_of_patched_recording"
FIXTURE_SCRIPT = "scripts/build_hcr_ct_mcr_fixture.sh"


def read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


# --------------------------------------------------------------------------
# repro.nim, read as text
# --------------------------------------------------------------------------


def string_consts(text: str) -> dict[str, str]:
    """`name* = "value"` (value possibly on the next line) -> {name: value}."""
    return dict(re.findall(r'\b(\w+)\*?\s*=\s*\n?\s*"([^"\n]*)"', text))


def array_consts(text: str) -> dict[str, list[str]]:
    """`name* = [ "a", "b", ... ]` -> {name: [a, b, ...]}."""
    return {
        name: re.findall(r'"([^"\n]*)"', body)
        for name, body in re.findall(r"\b(\w+)\*?\s*=\s*\[(.*?)\]", text, re.S)
    }


def resolve_strings(expr: str, strings: dict, arrays: dict) -> list[str]:
    """Every string an expression names: literals, string consts, and the
    elements of array consts it mentions."""
    values = re.findall(r'"([^"\n]*)"', expr)
    for name in re.findall(r"\b([A-Za-z_]\w*)\b", expr):
        if name in strings:
            values.append(strings[name])
        if name in arrays:
            values.extend(arrays[name])
    return values


def balanced_call(text: str, open_index: int) -> str:
    """The text from `open_index` (an opening parenthesis) to its match."""
    depth = 0
    for index in range(open_index, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[open_index : index + 1]
    return text[open_index:]


def fixture_rows_for(text: str, source: str) -> list[str]:
    """Each `TestGraphArtifacts(...)` row whose `source:` resolves to `source`."""
    strings, arrays = string_consts(text), array_consts(text)
    rows = []
    for match in re.finditer(r"TestGraphArtifacts\(", text):
        row = balanced_call(text, match.end() - 1)
        source_expr = re.search(r"source:\s*(.*?),\s*\n?\s*artifacts:", row, re.S)
        if not source_expr:
            continue
        if "".join(resolve_strings(source_expr.group(1), strings, arrays)) == source:
            rows.append(row)
    return rows


def row_dependencies(text: str, row: str) -> tuple[list[str], list[str]]:
    """(artifact paths, producing action ids) a fixture row declares."""
    strings, arrays = string_consts(text), array_consts(text)
    artifacts = row[row.find("artifacts:") :]
    action_ids = []
    for expr in re.findall(r"actionId:\s*([^,)\n]+)", artifacts):
        action_ids.extend(resolve_strings(expr, strings, arrays))
    paths = [
        value
        for value in resolve_strings(artifacts, strings, arrays)
        if value.startswith("build/") and value not in action_ids
    ]
    return paths, sorted(set(action_ids))


def producing_edges(text: str, action_id: str) -> list[str]:
    """The typed-tool calls (`shell(` / `nim.c(` / `gcc(`) declaring `action_id`."""
    strings, arrays = string_consts(text), array_consts(text)
    edges = []
    for match in re.finditer(r"\b(?:shell|nim\.c|gcc)\(", text):
        call = balanced_call(text, match.end() - 1)
        declared = re.search(r"\bactionId\s*=\s*([^,)\n]+)", call)
        if declared and action_id in resolve_strings(declared.group(1), strings, arrays):
            edges.append(call)
    return edges


def edge_outputs(text: str, edge: str) -> list[str]:
    strings, arrays = string_consts(text), array_consts(text)
    outputs = []
    for expr in re.findall(
        r"\b(?:extraOutputs|binary|output)\s*=\s*(@\[.*?\]|[^,\n]+)", edge, re.S
    ):
        outputs.extend(resolve_strings(expr, strings, arrays))
    return outputs


# --------------------------------------------------------------------------
# The three assertions, each over the text it is handed
# --------------------------------------------------------------------------


def gate_ct_mcr_path(gate_text: str) -> str:
    """Where the gate looks for `ct-mcr` when `CT_MCR_TEST_BINARY` is unset."""
    bundle_dir = re.search(r'\bCtMcrBundleDir\s*=\s*"([^"]+)"', gate_text)
    assert bundle_dir and re.search(
        r'ctMcrBundle\s*=\s*repoRoot\s*/\s*CtMcrBundleDir', gate_text
    ) and re.search(r'else:\s*ctMcrBundle\s*/\s*"ct_cli"', gate_text), (
        "the gate does not resolve ct-mcr inside a graph-built bundle "
        "directory (CtMcrBundleDir); it still reads it from somewhere no "
        "edge in repro.nim writes"
    )
    return bundle_dir.group(1) + "/ct_cli"


def assert_execute_edge_depends_on_ct_mcr(repro_nim: str, gate_text: str) -> str:
    """Principles 1 and 2. Returns the producing action id."""
    rows = fixture_rows_for(repro_nim, GATE_SOURCE)
    assert rows, (
        f"repro.nim declares no testFixtureArtifacts row for {GATE_SOURCE}, so "
        "the gate's execute edge depends on no edge that produces ct-mcr; the "
        "recorder has to be built by hand before the gate can pass"
    )
    ct_mcr = gate_ct_mcr_path(gate_text)
    for row in rows:
        paths, action_ids = row_dependencies(repro_nim, row)
        if ct_mcr not in paths:
            continue
        for action_id in action_ids:
            for edge in producing_edges(repro_nim, action_id):
                if ct_mcr in edge_outputs(repro_nim, edge):
                    missing = sorted(set(paths) - set(edge_outputs(repro_nim, edge)))
                    assert not missing, (
                        f"edge {action_id} does not declare these typed inputs of "
                        f"the gate as outputs: {missing}"
                    )
                    return action_id
    raise AssertionError(
        f"the gate's execute edge depends on no edge that produces ct-mcr "
        f"({ct_mcr}): no testFixtureArtifacts row of {GATE_SOURCE} names that "
        "path together with an edge whose declared outputs include it"
    )


def assert_gate_names_the_edge(gate_text: str, action_id: str) -> None:
    """Principle 3: a missing artifact names the edge that should have built it."""
    edge = re.search(r'\bCtMcrBundleEdge\s*=\s*"([^"]+)"', gate_text)
    assert edge and edge.group(1) == action_id, (
        f"the gate's CtMcrBundleEdge is {edge and edge.group(1)!r}, but the "
        f"edge that builds its ct-mcr is {action_id!r}"
    )
    missing = re.search(
        r'if not fileExists\(ctMcr\):(.*?)require fileExists\(ctMcr\)', gate_text, re.S
    )
    assert missing and "CtMcrBundleEdge" in missing.group(1), (
        "the gate's missing-ct-mcr diagnostic does not name the producing edge"
    )
    assert "CT_MCR_TEST_BINARY" in gate_text, (
        "the CT_MCR_TEST_BINARY override (exported by the recorder's own HX-S-2 "
        "gate) is gone"
    )
    assert not re.search(
        r'"codetracer-native-recorder"\s*/\s*"ct_cli"', gate_text
    ), "the gate still reads ct-mcr from a hard-coded sibling checkout path"


# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------


class GateExecuteEdgeDependsOnCtMcr(unittest.TestCase):
    def setUp(self):
        self.repro_nim = read("repro.nim")
        self.gate = read(GATE_SOURCE)

    def test_the_gate_execute_edge_depends_on_an_edge_that_produces_ct_mcr(self):
        action_id = assert_execute_edge_depends_on_ct_mcr(self.repro_nim, self.gate)
        # The edge is in its own `test-cross-repo-fixtures` collection, which
        # `scripts/run_tests.sh` builds before it runs any test binary -- and
        # NOT in `test-fixtures`, whose failure stops the whole suite: a
        # workspace without the recorder sibling must lose this one gate,
        # not every case.
        edges = producing_edges(self.repro_nim, action_id)
        self.assertEqual(len(edges), 1, f"{action_id} is declared {len(edges)} times")
        variable = re.search(
            r"let\s+(\w+)\s*=\s*(?:shell|nim\.c|gcc)" + re.escape(edges[0][:40]),
            self.repro_nim,
        )
        self.assertIsNotNone(variable, "the producing edge is not bound to a name")
        self.assertRegex(
            self.repro_nim,
            r'collect\("test-cross-repo-fixtures",\s*@\[' + variable.group(1) + r"\]\)",
            "the producing edge is not in the test-cross-repo-fixtures collection",
        )
        self.assertNotRegex(
            self.repro_nim,
            r"reprobuildTestFixturesActions\.add\(" + variable.group(1) + r"\)",
            "the producing edge is in test-fixtures, whose failure stops every test",
        )
        run_tests = read("scripts/run_tests.sh")
        self.assertRegex(
            run_tests,
            r'repro_build_collection "\.#test-cross-repo-fixtures" \|\| '
            r"cross_repo_fixtures_status=\$\?",
            "run_tests.sh does not build the cross-repo fixture collection",
        )
        self.assertRegex(
            run_tests,
            r'suite_status="\$\{cross_repo_fixtures_status\}"',
            "run_tests.sh does not re-raise a failed cross-repo fixture build",
        )

    def test_the_gate_names_the_producing_edge_when_ct_mcr_is_missing(self):
        action_id = assert_execute_edge_depends_on_ct_mcr(self.repro_nim, self.gate)
        assert_gate_names_the_edge(self.gate, action_id)

    def test_removing_the_fixture_row_makes_the_dependency_check_fail(self):
        """MUTATION: the realistic regression -- the row is dropped."""
        stripped, removed = re.subn(
            r"TestGraphArtifacts\(\s*source:\s*hcrReplayGateSource,.*?bundle\)",
            "TestGraphArtifacts(source: \"removed\", artifacts: @[])",
            self.repro_nim,
            count=1,
            flags=re.S,
        )
        self.assertEqual(removed, 1, "mutation did not apply")
        with self.assertRaises(AssertionError) as caught:
            assert_execute_edge_depends_on_ct_mcr(stripped, self.gate)
        self.assertIn("depends on no edge that produces ct-mcr", str(caught.exception))

    def test_an_edge_that_stops_producing_ct_cli_makes_the_check_fail(self):
        """MUTATION: the row survives but no edge declares ct_cli any more --
        the shape of depending on `codetracer-native-recorder.ct-cli`'s
        output in another checkout, which this graph does not produce."""
        mutated = self.repro_nim.replace(
            '"build/test-fixtures/hcr-ct-mcr/ct_cli",', "", 1
        )
        self.assertNotEqual(mutated, self.repro_nim, "mutation did not apply")
        with self.assertRaises(AssertionError):
            assert_execute_edge_depends_on_ct_mcr(mutated, self.gate)

    def test_a_gate_reading_the_sibling_checkout_fails_the_checks(self):
        """MUTATION: the pre-fix lookup, restored."""
        mutated = re.sub(
            r'else:\s*ctMcrBundle\s*/\s*"ct_cli"',
            'else: repoRoot / ".." / "codetracer-native-recorder" / "ct_cli" / "ct_cli"',
            self.gate,
            count=1,
        )
        self.assertNotEqual(mutated, self.gate, "mutation did not apply")
        with self.assertRaises(AssertionError):
            assert_execute_edge_depends_on_ct_mcr(self.repro_nim, mutated)

    def test_a_diagnostic_that_does_not_name_the_edge_fails(self):
        """MUTATION for Principle 3."""
        action_id = assert_execute_edge_depends_on_ct_mcr(self.repro_nim, self.gate)
        mutated = self.gate.replace('"build-graph edge \'" & CtMcrBundleEdge &', '"', 1)
        self.assertNotEqual(mutated, self.gate, "mutation did not apply")
        with self.assertRaises(AssertionError):
            assert_gate_names_the_edge(mutated, action_id)


class TheEdgeBuildsTheRecorderTheRecorderWay(unittest.TestCase):
    """cross-repo-builds.md §2.3 and §5, and the three spellings agreeing."""

    def setUp(self):
        self.repro_nim = read("repro.nim")
        self.gate = read(GATE_SOURCE)
        self.script = read(FIXTURE_SCRIPT)
        self.action_id = assert_execute_edge_depends_on_ct_mcr(self.repro_nim, self.gate)
        self.edge = producing_edges(self.repro_nim, self.action_id)[0]

    def test_the_edge_runs_the_fixture_script(self):
        self.assertIn(f"bash {FIXTURE_SCRIPT}", self.edge)
        self.assertIn(FIXTURE_SCRIPT, self.edge.split("extraInputs", 1)[1])

    def test_the_script_runs_the_recorder_recipe_in_the_recorder_shell(self):
        self.assertRegex(
            self.script,
            r'sibling="\$\{CT_CODETRACER_NATIVE_RECORDER_SIBLING:-\$\{REPO_ROOT\}/\.\./'
            r'codetracer-native-recorder\}"',
        )
        self.assertRegex(self.script, r'nix develop "\$\{sibling\}"')
        self.assertIn("--no-update-lock-file", self.script)
        self.assertIn("--ignore-environment", self.script)
        self.assertIn("just build-ct-mcr", self.script)
        # A failed build leaves no stale bundle behind for the gate to pass
        # with: the suite carries on past a failed cross-repo fixture.
        die = re.search(r"^die\(\) \{\n(.*?)^\}", self.script, re.S | re.M)
        self.assertIsNotNone(die)
        self.assertIn('rm -rf "${OUT_DIR}"', die.group(1))
        # §5 pattern 2: no open-coded build of the recorder's parts.
        for forbidden in ("nimble build", "cargo build", "nim c "):
            self.assertNotIn(forbidden, self.script)

    def test_the_script_and_the_graph_agree_on_the_bundle(self):
        strings, arrays = string_consts(self.repro_nim), array_consts(self.repro_nim)
        bundle = arrays["hcrCtMcrBundle"]
        root = strings["hcrCtMcrFixtureRoot"]
        self.assertTrue(all(path.startswith(root + "/") for path in bundle), bundle)
        script_bundle = re.search(r"readonly BUNDLE=\((.*?)\)", self.script, re.S)
        self.assertIsNotNone(script_bundle)
        self.assertEqual(
            sorted(Path(p).name for p in script_bundle.group(1).split()),
            sorted(Path(p).name for p in bundle),
        )
        self.assertIn(f'readonly OUT_REL="{root}"', self.script)
        self.assertIn(f'readonly EDGE_ID="{self.action_id}"', self.script)
        self.assertEqual(gate_ct_mcr_path(self.gate), root + "/ct_cli")

    def test_the_hcr_lane_recipe_builds_the_fixture_first(self):
        justfile = read("Justfile")
        recipe = re.search(rf"^{GATE_RECIPE}:([^\n]*)$", justfile, re.M)
        self.assertIsNotNone(recipe)
        self.assertIn("hcr_ct_mcr_fixture", recipe.group(1).split())
        fixture = re.search(r"^hcr_ct_mcr_fixture:\n((?:[ \t]+.*\n)+)", justfile, re.M)
        self.assertIsNotNone(fixture)
        self.assertIn(FIXTURE_SCRIPT, fixture.group(1))


# --------------------------------------------------------------------------
# A prebuilt bundle: the script RUN, not read
# --------------------------------------------------------------------------


@unittest.skipUnless(
    platform.system() == "Linux" and platform.machine() in ("x86_64", "amd64"),
    "the fixture script stages a bundle on Linux x86-64 only (elsewhere it "
    "exits 0 having staged nothing, which these cases cannot tell apart)",
)
class PrebuiltBundle(unittest.TestCase):
    """`CT_CODETRACER_NATIVE_RECORDER_PREBUILT=1` stages the named recorder
    checkout's existing bundle without building it.

    The recorder's own HX-S-2 gate builds the tree it tests and then runs this
    gate's recipe from it; the fixture's build runs in a cleared environment,
    so it is not incremental over the gate's and cost that row most of a full
    recorder build (64 s against the 30 s limit).

    The script is copied into a temporary repository root (it stages into
    `<its root>/build/test-fixtures/hcr-ct-mcr`) and pointed at a temporary
    recorder checkout holding the bundle files. `nix` on PATH is a stand-in
    that records that it ran and fails. Justification: the property is that
    the build is NOT run, so the build must be observable and cheap; the real
    build is the recorder's `just build-ct-mcr`, which the gate exercises.
    HOW IT GOES RED ON THE UNFIXED SCRIPT: the variable is ignored, the
    stand-in `nix` runs and fails, and the script exits non-zero.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hcr-prebuilt-"))
        self.root = self.tmp / "reprobuild"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy2(REPO_ROOT / FIXTURE_SCRIPT, self.root / FIXTURE_SCRIPT)
        self.recorder = self.tmp / "recorder"
        script = read(FIXTURE_SCRIPT)
        bundle = re.search(r"readonly BUNDLE=\((.*?)\)", script, re.S)
        marker = re.search(r'readonly HXS2_MARKER="([^"]+)"', script)
        self.assertIsNotNone(bundle)
        self.assertIsNotNone(marker)
        self.bundle = bundle.group(1).split()
        for rel in ["Justfile", "flake.nix", marker.group(1)] + self.bundle:
            path = self.recorder / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("content of " + rel + "\n", encoding="utf-8")
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.nix_ran = self.tmp / "nix-ran"
        nix = self.bin / "nix"
        nix.write_text(f"#!/bin/sh\ntouch '{self.nix_ran}'\nexit 1\n", encoding="utf-8")
        nix.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, prebuilt: bool) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = str(self.bin) + os.pathsep + env.get("PATH", "")
        env["CT_CODETRACER_NATIVE_RECORDER_SIBLING"] = str(self.recorder)
        env.pop("CT_CODETRACER_NATIVE_RECORDER_PREBUILT", None)
        if prebuilt:
            env["CT_CODETRACER_NATIVE_RECORDER_PREBUILT"] = "1"
        return subprocess.run(
            ["bash", str(self.root / FIXTURE_SCRIPT)],
            env=env, capture_output=True, text=True, timeout=60,
        )

    def staged(self) -> Path:
        return self.root / "build" / "test-fixtures" / "hcr-ct-mcr"

    def test_a_prebuilt_bundle_is_staged_without_building(self):
        result = self.run_script(prebuilt=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.nix_ran.exists(), "the recorder was built anyway")
        for rel in self.bundle:
            staged = self.staged() / Path(rel).name
            self.assertTrue(staged.is_file(), f"{rel} was not staged")
            self.assertEqual(
                staged.read_text(encoding="utf-8"),
                (self.recorder / rel).read_text(encoding="utf-8"),
            )

    def test_without_the_variable_the_recorder_is_built(self):
        # The control: the same checkout without the variable runs the build
        # (the stand-in fails it), so the case above is not passing because
        # the build never runs at all.
        result = self.run_script(prebuilt=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.nix_ran.exists(), "the build did not run")

    def test_a_prebuilt_bundle_missing_a_file_is_refused(self):
        (self.recorder / self.bundle[0]).unlink()
        result = self.run_script(prebuilt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CT_CODETRACER_NATIVE_RECORDER_PREBUILT", result.stderr)
        self.assertFalse(self.nix_ran.exists())
        self.assertFalse(self.staged().exists(), "a partial bundle was left staged")


if __name__ == "__main__":
    unittest.main()
