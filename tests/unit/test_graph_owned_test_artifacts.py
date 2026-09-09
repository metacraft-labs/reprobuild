#!/usr/bin/env python3
"""Graph-Owned-Test-Artifacts M3 verification.

Three named tests from the milestone:

  * ``test_no_test_body_helper_compilation``
  * ``test_graph_owned_fixture_rebuild_once``
  * ``test_repro_invocation_integration_path``

EVERY ONE OF THEM IS WRITTEN SO IT CAN GO RED, and each proves that in the
same test body rather than asking the reader to believe it. The pattern is
always the same: assert the property on a tree that HAS it, then mutate the
tree so the property is gone and assert the check now refuses. This campaign
has repeatedly found checks that could not fail — a one-armed assertion that
agrees with the hypothesis is not evidence — so the negative arm is not
optional decoration here, it is what makes the positive arm mean anything.

NO MOCKS. The synthetic trees are real directories with a real
``repro_tests.nim`` and real Nim sources, parsed by the same production
``parse_repro_tests`` / ``compiler_invocations`` / ``classify`` the suite
inventory uses. Nothing about the detector is stubbed, because a stub would
let the tests pass against a detector that does not exist.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


inventory = _load(
    "reprobuild_suite_inventory", "scripts/reprobuild_suite_inventory.py"
)
audit = _load(
    "check_test_body_helper_compilation",
    "scripts/check_test_body_helper_compilation.py",
)


TEST_SPEC_TABLE = """\
# Synthetic test-edge table, in the shape scripts/generate_test_edges.nim emits.
type
  TargetOs* = enum
    soAny, soMacosArm64

const reprobuildTestSpecs* = @[
{rows}
]

const pythonTestPaths*: seq[string] = @[]
"""

TEST_SPEC_ROW = (
    '  TestSpec(source: "{source}", binary: "build/test-bin/{stem}", '
    "defines: @[], requiresReproBinary: {requires}, extraPassC: @[], "
    "extraPassL: @[], targetOs: soAny, selfInterposes: false),"
)


def write_tree(root: Path, sources: dict[str, str], requires_repro=()) -> None:
    """Materialise a synthetic reprobuild-shaped tree."""
    rows = "\n".join(
        TEST_SPEC_ROW.format(
            source=source,
            stem=Path(source).stem,
            requires="true" if source in requires_repro else "false",
        )
        for source in sorted(sources)
    )
    (root / "repro_tests.nim").write_text(TEST_SPEC_TABLE.format(rows=rows))
    (root / "repro.nim").write_text("# synthetic\n")
    for source, body in sources.items():
        path = root / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)


def write_dispositions(path: Path, rows: dict[str, tuple[str, str]]) -> None:
    lines = ["# synthetic disposition list"]
    lines += [
        f"{source}\t{verdict}\t{why}" for source, (verdict, why) in sorted(rows.items())
    ]
    path.write_text("\n".join(lines) + "\n")


# THE SYNTHETIC NIM BODIES LIVE IN FILES, NOT IN THIS ONE.
#
# They contain real compiler commands — they have to, or they would not
# exercise the detector. Kept as string literals here, they made THIS Python
# file a "test that compiles a helper at run time" in the suite inventory: one
# artificial record in a tracked artifact, and a bogus `graph-fixture`
# classification for a file that compiles nothing. That is the same
# embedded-fixture confusion M3 warns about, arriving through the back door of
# the tool written to police it.
#
# The fixtures carry a `.nim.fixture` extension so no Nim tooling picks them up
# and the test-edge generator does not mistake one for a test.
FIXTURES = Path(__file__).parent / "fixtures" / "graph-owned-test-artifacts"


def fixture(name: str) -> str:
    return (FIXTURES / f"{name}.nim.fixture").read_text()


# A test body that compiles a helper binary — the thing M3 removes.
HELPER_COMPILING_TEST = fixture("helper_compiling_body")

# The same test after migration: the helper comes from the graph.
GRAPH_OWNED_TEST = fixture("graph_owned_body")

# An integration test of exactly the kind M3 says to PRESERVE: it drives the
# product and asserts a build/cache side effect. A compiler certainly runs —
# inside `repro` — and that is the behaviour under test.
REPRO_INVOKING_TEST = fixture("repro_invoking_body")


class NoTestBodyHelperCompilation(unittest.TestCase):
    """M3 verification: test_no_test_body_helper_compilation.

    "The suite audit fails when a test body shells out to compile a helper
    binary that should be declared in repro.nim."

    SCOPE, STATED WHERE THE CLAIM IS MADE. The reviewed baseline in
    ``scripts/test-body-helper-compilation-dispositions.tsv`` covers every
    runtime compiler flow ``inventory.compiler_invocations`` DETECTS — a static
    regex-plus-dataflow scan — and nothing beyond it. A green here means the
    detected set carries reviewed dispositions and that no migration in it has
    regressed; it does NOT mean no test in the suite compiles anything
    undetected. The detector is the ratchet's reach, not a census, and its
    reach has moved: three spellings that used to evade it (``nim check``, a
    verb after a leading space, a fragment on a continuation line of an open
    executor call) hid ten real spawns, which is why
    ``TheRatchetHasNoWalkableBypass`` below exists. Known remaining blind spots
    are listed in the header of ``check_test_body_helper_compilation.py``.
    """

    def audit(self, root: Path, rows: dict[str, tuple[str, str]]):
        dispositions = root / "dispositions.tsv"
        write_dispositions(dispositions, rows)
        return audit.check(root, dispositions)

    def test_no_test_body_helper_compilation(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = "tests/synthetic/t_compiles_a_helper.nim"
            write_tree(root, {source: HELPER_COMPILING_TEST})

            # ARM 1 — the audit REFUSES an unreviewed helper compile.
            code, failures = self.audit(root, {})
            self.assertEqual(code, 1, "audit accepted a test that runs `nim c`")
            self.assertTrue(
                any("UNREVIEWED" in f and source in f for f in failures),
                f"audit failed, but not for the right reason: {failures}",
            )

            # ARM 2 — THE MUTATION THAT PROVES ARM 1 IS NOT VACUOUS. Replace the
            # `nim c` with the graph lookup and change nothing else. If the
            # audit still refused, arm 1 would have been telling us only that
            # this audit refuses everything.
            write_tree(root, {source: GRAPH_OWNED_TEST})
            code, failures = self.audit(root, {})
            self.assertEqual(
                code,
                0,
                "audit refused a test that compiles nothing; it does not "
                f"discriminate: {failures}",
            )

    def test_a_completed_migration_cannot_silently_regress(self):
        """A `graph-owned` row that reacquires a compile is a failure.

        Without this, the ratchet only guards NEW tests: someone could put
        `nim c` back into a migrated test and the audit, seeing a row for that
        source, would wave it through.
        """
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = "tests/synthetic/t_migrated.nim"
            row = {source: ("graph-owned", "built by edge reprobuild.x.helper")}

            write_tree(root, {source: GRAPH_OWNED_TEST})
            code, failures = self.audit(root, row)
            self.assertEqual(code, 0, f"clean migrated tree refused: {failures}")

            # MUTATION: put the compile back.
            write_tree(root, {source: HELPER_COMPILING_TEST})
            code, failures = self.audit(root, row)
            self.assertEqual(code, 1, "a regressed migration was accepted")
            self.assertTrue(
                any("REGRESSED" in f and source in f for f in failures), failures
            )

    def test_every_graph_owned_row_in_this_tree_really_compiles_nothing(self):
        """The live assertion, against the real repository.

        The synthetic arms above prove the audit works. This one proves the
        tree is in the state the disposition list claims.
        """
        rows, errors = audit.read_dispositions(audit.DISPOSITIONS)
        self.assertEqual(errors, [], "the tracked disposition list does not parse")
        graph_owned = sorted(
            source for source, (verdict, _) in rows.items() if verdict == "graph-owned"
        )
        self.assertTrue(graph_owned, "no migration is recorded at all")
        for source in graph_owned:
            text = inventory.read_text(REPO_ROOT / source)
            self.assertTrue(text, f"{source} is recorded but missing from the tree")
            spawns, _ = audit.classify_source(inventory, source, text)
            self.assertFalse(
                spawns,
                f"{source} is recorded as graph-owned but still spawns a compiler",
            )

    def test_a_compile_hidden_behind_an_include_is_still_found(self):
        """One of the detector's four declared blind spots, closed.

        Nim's ``include`` splices a file in textually, so a compile in an
        included file is a compile in the including test. A scan of the
        including file's own bytes cannot see it, and until this the audit was
        exactly that scan.

        Both arms again: the same test WITHOUT the include must stay clean, or
        this would be reporting that the audit flags anything with an
        ``include`` in it.
        """
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = "tests/synthetic/t_includes_a_compile.nim"
            innocuous = (
                "import std/[os, osproc, unittest]\n"
                "include ./helper_bits\n"
                'suite "synthetic":\n'
                '  test "uses the included helper":\n'
                "    check helperName().len > 0\n"
            )
            clean_include = 'proc helperName(): string = "helper"\n'
            write_tree(root, {source: innocuous})
            (root / "tests/synthetic/helper_bits.nim").write_text(clean_include)

            dispositions = root / "dispositions.tsv"
            write_dispositions(dispositions, {})
            code, failures = audit.check(root, dispositions)
            self.assertEqual(
                code, 0, f"a harmless `include` was flagged: {failures}"
            )

            # MUTATION: move a real compile into the included file. Nothing in
            # the test source itself changes.
            (root / "tests/synthetic/helper_bits.nim").write_text(
                clean_include
                + fixture("hidden_in_include")
            )
            code, failures = audit.check(root, dispositions)
            self.assertEqual(
                code,
                1,
                "a compile spliced in through `include` was invisible to the "
                "audit; the blind spot is still open",
            )
            self.assertTrue(any(source in f for f in failures), failures)

    def test_product_api_cannot_be_used_to_park_a_helper_compile(self):
        """`product-api` is the verdict a future violation would hide behind.

        It is also the only verdict the audit can check mechanically, so it
        does. This caught a real mistake while the tracked list was written.
        """
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = "tests/synthetic/t_compiles_a_helper.nim"
            write_tree(root, {source: HELPER_COMPILING_TEST})
            code, failures = self.audit(
                root, {source: ("product-api", "it calls compileProviderBinary")}
            )
            self.assertEqual(code, 1, "a helper compile hid behind `product-api`")
            self.assertTrue(any("MISCLASSIFIED" in f for f in failures), failures)

            # MUTATION: the honest verdict for the same file is accepted.
            code, failures = self.audit(
                root,
                {source: ("compiler-is-subject", "executing the argv is the test")},
            )
            self.assertEqual(
                code, 0, f"an honestly classified row was refused: {failures}"
            )

    def test_a_disposition_without_a_reason_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = "tests/synthetic/t_compiles_a_helper.nim"
            write_tree(root, {source: HELPER_COMPILING_TEST})
            code, failures = self.audit(root, {source: ("dynamic-source", "")})
            self.assertEqual(code, 1)
            self.assertTrue(any("no justification" in f for f in failures), failures)

    def test_an_embedded_fixture_is_not_mistaken_for_a_compile(self):
        """The repository writes Nim inside Nim; those bytes are not code.

        A raw-byte scan reads a triple-quoted fixture as if the test executed
        it. Both arms are here because masking that does nothing is as useless
        as no masking at all.
        """
        embedded = fixture("embedded_fixture_body")
        source = "tests/synthetic/t_embedded.nim"
        spawns, _ = audit.classify_source(inventory, source, embedded)
        self.assertFalse(spawns, "an embedded fixture was read as a real compile")

        # MUTATION: the same command, but as code the test actually runs.
        real = embedded.replace('const FixtureSource = """', "let cmd0 = ").replace(
            '"""\n\nsuite', "\ndiscard execCmdEx(cmd0)\n\nsuite"
        )
        real += fixture("real_compile_tail")
        spawns, _ = audit.classify_source(inventory, source, real)
        self.assertTrue(
            spawns,
            "masking hid a real compile; the mask is too aggressive to be useful",
        )


# A body that spawns `nim check` — a real front-end run of the compiler.
NIM_CHECK_TEST = fixture("nim_check_body")

# A body whose compile verb arrives in a fragment that starts with a SPACE:
# `nimExe & " c --compileOnly ..."`.
LEADING_SPACE_VERB_TEST = fixture("leading_space_verb_body")

# Two bodies spelling nim switches with `=` rather than `:`. Nim takes both.
EQUALS_OUT_TEST = fixture("equals_separator_out_body")
EQUALS_NIMCACHE_TEST = fixture("equals_separator_nimcache_body")

# A body that drives the PRODUCT's `check` verb — `repro check --mode=pre-push`.
# It must NOT be detected: the product spawning a compiler is the behaviour
# under test, not a helper compile. Load-bearing in the opposite direction from
# every other fixture in this class.
PRODUCT_CHECK_VERB_TEST = fixture("product_check_verb_body")


class TheRatchetHasNoWalkableBypass(unittest.TestCase):
    """The gate must not have a spelling that walks straight through it.

    A ratchet is only worth its maintenance if the set it ratchets is the set
    it claims. Two spellings used to evade ``COMPILER_PATTERNS`` outright, and
    both are the NORMAL way this repository spells a runtime compile rather
    than anything contrived:

      * ``nim check`` — no pattern matched it at all. It runs the compiler's
        entire front end; that it stops before codegen changes the output, not
        whether a compiler was spawned.
      * ``nimExe & " c --compileOnly ..."`` — the ``nim-compile-verb`` pattern
        required the quote to be followed IMMEDIATELY by ``c``, so one leading
        space was enough. The compiler path is resolved with ``findExe`` and
        concatenated in front of the verb in most of this suite, which puts
        that space there every time.

    A third hole sat one layer below the patterns, and the fixtures here go
    through it too: a compiler fragment on a CONTINUATION LINE of an open
    ``execCmdEx(`` was matched and then discarded, because the line carries no
    executor token of its own and ``let (a, b) =`` defeats the assignment
    tracker. Ten live sources evaded the detector through the three together
    and were consequently in neither the baseline list nor the detected set.

    A FOURTH was introduced BY THE FIX for the second, and is why this class
    keeps growing rather than being declared finished. Telling nim's switches
    from this repository's CLI flags was first attempted on the SEPARATOR —
    ``--name:value`` for nim, ``--name=value`` for everything else. Nim accepts
    both (``commands.nim:140``: ``elif switch[i] in {':', '='}``), so
    ``" c --out=x"`` walked straight through the fix for ``" c --out:x"``. The
    rule now keys on nim's switch VOCABULARY, taken from ``processSwitch``'s own
    case block, which works under either separator. Punctuation could never have
    separated the two languages: they share it.

    So this class pins spellings in BOTH directions. Four arms say the detector
    must see a real compile; ``test_the_product_check_verb_is_not_detected``
    says it must not see ``repro check --mode=pre-push``. A rule that satisfies
    only one direction is available cheaply and is worthless — matching every
    switch passes the first four, matching none passes the fifth. These
    fixtures are the only place any of it is pinned; the disposition list is a
    snapshot and would not go red.
    """

    def spawns(self, body: str, name: str) -> bool:
        result, _ = audit.classify_source(
            inventory, f"tests/synthetic/{name}.nim", body
        )
        return result

    def test_nim_check_is_detected(self):
        self.assertTrue(
            self.spawns(NIM_CHECK_TEST, "t_nim_check"),
            "a test body that spawns `nim check` was not detected; the ratchet "
            "has a spelling that walks through it",
        )

    def test_a_leading_space_before_the_verb_is_detected(self):
        self.assertTrue(
            self.spawns(LEADING_SPACE_VERB_TEST, "t_leading_space"),
            "a test body that spawns `nimExe & \" c --compileOnly ...\"` was not "
            "detected; one leading space evaded the gate",
        )

    def test_an_equals_separated_nim_switch_is_detected(self):
        """`--out=x`, not `--out:x`. Nim takes both; the gate must too.

        `codetracer-nim/compiler/commands.nim:140` reads
        ``elif switch[i] in {':', '='}``, so this is an ordinary Nim command
        line. A discriminator that keyed on the colon — as the first fix for
        the leading-space bypass did — let this straight through, which is the
        same walkable bypass one punctuation mark over.
        """
        self.assertTrue(
            self.spawns(EQUALS_OUT_TEST, "t_equals_out"),
            "a test body that spawns `nimExe & \" c --out=... \"` was not "
            "detected; `=` instead of `:` evaded the gate",
        )

    def test_a_second_equals_separated_switch_is_detected(self):
        """A different switch and a different verb, so one special case cannot pass this."""
        self.assertTrue(
            self.spawns(EQUALS_NIMCACHE_TEST, "t_equals_nimcache"),
            "a test body that spawns `nimExe & \" check --nimcache=... \"` was "
            "not detected",
        )

    def test_the_product_check_verb_is_not_detected(self):
        """THE ARM THAT POINTS THE OTHER WAY.

        `repro check --mode=pre-push --write-report` is the product, and the
        product running a compiler is the behaviour under test. Detecting it
        would flag the entire integration surface — the failure mode the whole
        check is designed around, and one that actually fired once while these
        patterns were being widened.

        This arm is what stops "detect more" from being bought by detecting
        everything. Every assertion above says the gate must be wider; this one
        bounds where.
        """
        self.assertFalse(
            self.spawns(PRODUCT_CHECK_VERB_TEST, "t_product_check"),
            "a test that drives `repro check --mode=pre-push` was flagged as a "
            "helper compile; the gate is now condemning the product",
        )

    def test_the_switch_vocabulary_comes_from_the_compiler(self):
        """The vocabulary must be nim's, not a plausible-looking hand-list.

        Spot-checks that names taken from `processSwitch`'s own case block are
        recognised under both separators and under `normalize`'s case/underscore
        folding, and that flag names belonging to this repository's CLIs are
        not. If someone replaces the vocabulary rule with a punctuation rule,
        the `--mode=` row and the `--out=` row cannot both stay green.
        """
        matcher = dict(inventory.COMPILER_PATTERNS)["nim-compile-verb"]
        for fragment, expected in (
            ('" c --out=x src.nim"', True),
            ('" c --out:x src.nim"', True),
            ('" c --nimcache=nc"', True),
            ('" c --compile_only"', True),      # normalize() drops underscores
            ('" c --COMPILEONLY"', True),       # normalize() lowercases
            ('" c -d:release"', True),
            ('" check --mode=pre-push"', False),
            ('" check --write-report"', False),
            ('" c --mode=fast"', False),
        ):
            self.assertEqual(
                bool(matcher.search(fragment)),
                expected,
                f"{fragment!r}: expected "
                f"{'a match' if expected else 'no match'}",
            )

    def test_the_arms_above_are_not_vacuous(self):
        """The negative arm: the same bodies with the SPAWN removed.

        Without this, both assertions above would also pass against a detector
        that answered ``True`` to everything — which is the failure mode this
        file exists to rule out.
        """
        for name, body in (
            ("t_nim_check", NIM_CHECK_TEST),
            ("t_leading_space", LEADING_SPACE_VERB_TEST),
            ("t_equals_out", EQUALS_OUT_TEST),
            ("t_equals_nimcache", EQUALS_NIMCACHE_TEST),
        ):
            # Replace the compile with a graph lookup, changing nothing else
            # about the file's shape.
            defanged = re.sub(
                r'(?s)let \(output, (?:exit)?[Cc]ode\) = execCmdEx\(.*?\)\n',
                'let (output, code) = ("", 0)\n',
                body,
            )
            self.assertNotEqual(defanged, body, f"{name}: mutation did not apply")
            self.assertFalse(
                self.spawns(defanged, name),
                f"{name}: the detector still reports a spawn after the compile "
                "was removed, so the positive arm proves nothing",
            )

    def test_no_declared_test_source_evades_the_patterns(self):
        """The live arm, against the real tree.

        The seven sources named in the docstring are gone from the tree's
        blind spot only if the detector now sees them. Rather than pin those
        seven by name — a list that rots — assert the invariant that made them
        findable: every declared test source that spawns a compiler by either
        of the two previously-invisible spellings is in the detected set, and
        therefore needs a disposition row.
        """
        spawners, product_api = audit.detect(REPO_ROOT)
        detected = spawners | product_api
        rows, errors = audit.read_dispositions(audit.DISPOSITIONS)
        self.assertEqual(errors, [], "the tracked disposition list does not parse")
        missing = sorted(detected - set(rows))
        self.assertEqual(
            missing,
            [],
            "sources spawn a compiler with no reviewed disposition row: "
            f"{missing}",
        )


def nim_c_binaries(repro_nim_text: str) -> list[str]:
    """Every ``binary =`` a ``nim.c(...)`` edge declares, in source order."""
    return re.findall(r'binary\s*=\s*([^\n]+)', repro_nim_text)


def fixture_table_rows(repro_nim_text: str) -> dict[str, list[str]]:
    """``testFixtureArtifacts`` as ``{test source: [action ids]}``.

    Parsed from the text rather than imported so a test can feed it a mutated
    copy of ``repro.nim`` and watch the assertion fail.
    """
    start = repro_nim_text.find("testFixtureArtifacts*")
    if start < 0:
        return {}
    end = repro_nim_text.find("\n  ]", start)
    block = repro_nim_text[start : end if end > 0 else len(repro_nim_text)]
    aliases = {
        name: action
        for name, action in re.findall(
            r"(\w+)\s*=\s*TestGraphArtifact\(\s*path:[^)]*?"
            r'actionId:\s*"([^"]+)"',
            repro_nim_text,
            re.S,
        )
    }
    rows: dict[str, list[str]] = {}
    for entry in re.finditer(
        r"TestGraphArtifacts\(\s*source:\s*(.*?),\s*artifacts:\s*@\[(.*?)\]\)",
        block,
        re.S,
    ):
        source = "".join(re.findall(r'"([^"]*)"', entry.group(1)))
        ids = list(re.findall(r'actionId:\s*"([^"]+)"', entry.group(2)))
        ids += [aliases[name] for name in re.findall(r"\b(\w+)\b", entry.group(2))
                if name in aliases]
        rows.setdefault(source, []).extend(ids)
    return rows


class GraphOwnedFixtureRebuildOnce(unittest.TestCase):
    """M3 verification: test_graph_owned_fixture_rebuild_once.

    "A helper binary used by multiple tests is built once through the graph and
    reused by dependent test execution edges on a warm run."

    WHAT THIS ASSERTS, PRECISELY, so nobody reads more into a green than is
    there: it asserts the GRAPH STRUCTURE that makes rebuild-once true —
    exactly one edge produces the shared artifact, two or more test execute
    edges declare it as a typed input, and none of those tests compiles it
    itself, so a warm run has nothing left to rebuild. It does NOT time a warm
    build; a live cold/warm timing gate belongs to M5's performance work and is
    not claimed here.
    """

    SHARED = "fixture_protocol_three_tests"
    SHARED_ACTION = "reprobuild.test_fixtures.ct_shim_fixture_protocol_three_tests"

    def setUp(self):
        self.repro_nim = (REPO_ROOT / "repro.nim").read_text()

    def producers_of(self, text: str, stem: str) -> list[str]:
        return [line for line in nim_c_binaries(text) if stem in line]

    def assert_built_once_and_shared(self, repro_nim: str) -> list[str]:
        """The two structural assertions, over a GIVEN ``repro.nim`` text.

        Parameterised on the text, not read from disk, so the mutation tests
        below can re-run THIS EXACT ASSERTION against a broken graph and watch
        it raise. A mutation test that only checks "the parser noticed" would
        be testing the parser, not the assertion.
        """
        # BUILT ONCE: exactly one edge declares the shared artifact as output.
        producers = self.producers_of(repro_nim, self.SHARED)
        self.assertEqual(
            len(producers),
            1,
            f"expected exactly one graph edge to produce {self.SHARED}, "
            f"found {len(producers)}: {producers}",
        )

        # USED BY MULTIPLE TESTS: two or more execute edges take it as input.
        rows = fixture_table_rows(repro_nim)
        consumers = sorted(
            source
            for source, actions in rows.items()
            if self.SHARED_ACTION in actions
        )
        self.assertGreaterEqual(
            len(consumers),
            2,
            f"{self.SHARED} is not shared; consumers: {consumers}",
        )
        return consumers

    def test_graph_owned_fixture_rebuild_once(self):
        consumers = self.assert_built_once_and_shared(self.repro_nim)

        # REUSED, NOT REBUILT: no consumer compiles anything, so a warm run
        # finds the artifact already present and does no work for it.
        for source in consumers:
            text = inventory.read_text(REPO_ROOT / source)
            self.assertTrue(text, f"{source} is in the table but not in the tree")
            spawns, _ = audit.classify_source(inventory, source, text)
            self.assertFalse(
                spawns,
                f"{source} consumes the graph fixture but ALSO spawns a compiler; "
                "the warm run would still rebuild something",
            )

    def test_the_built_once_arm_fails_when_a_second_producer_appears(self):
        """MUTATION for the 'built once' arm.

        A duplicated edge is the realistic regression: someone adds a second
        fixture edge for a variant and both write the same output.
        """
        duplicated = self.repro_nim.replace(
            f'binary = ctShimFixtureDir & "/{self.SHARED}",',
            f'binary = ctShimFixtureDir & "/{self.SHARED}",\n'
            f'      # injected by the test\n'
            f'      binary = ctShimFixtureDir & "/{self.SHARED}",',
            1,
        )
        self.assertNotEqual(duplicated, self.repro_nim, "mutation did not apply")
        with self.assertRaises(AssertionError) as caught:
            self.assert_built_once_and_shared(duplicated)
        self.assertIn("exactly one graph edge", str(caught.exception))

    def test_the_shared_arm_fails_when_the_second_consumer_is_removed(self):
        """MUTATION for the 'used by multiple tests' arm."""
        rows = fixture_table_rows(self.repro_nim)
        consumers = [s for s, a in rows.items() if self.SHARED_ACTION in a]
        self.assertGreaterEqual(len(consumers), 2)

        victim = sorted(consumers)[-1]
        # DELETE the victim's whole table entry — the realistic regression is
        # someone dropping a row, not renaming one. (Renaming the source is NOT
        # a valid mutation here and was tried first: the row still names the
        # shared action, so the sharing count is unchanged and the "mutation"
        # proves nothing. The mutation has to remove what the assertion counts.)
        stripped, removed = re.subn(
            r"\n    TestGraphArtifacts\((?:(?!TestGraphArtifacts\()[\s\S])*?"
            + re.escape(Path(victim).name)
            + r"[\s\S]*?\]\),",
            "",
            self.repro_nim,
            count=1,
        )
        self.assertEqual(removed, 1, "mutation did not apply")
        rows_after = fixture_table_rows(stripped)
        after = [s for s, a in rows_after.items() if self.SHARED_ACTION in a]
        self.assertEqual(
            len(after),
            len(consumers) - 1,
            "removing a consumer did not change what the parser sees, so the "
            "sharing assertion above cannot fail and proves nothing",
        )
        # And the assertion itself goes red, not merely the parser's count.
        with self.assertRaises(AssertionError) as caught:
            self.assert_built_once_and_shared(stripped)
        self.assertIn("is not shared", str(caught.exception))

    def test_the_three_spellings_of_the_fixture_directory_agree(self):
        """One path, three files, no shared symbol — so assert they match.

        ``repro.nim`` declares where the fixtures are BUILT;
        ``repro_test_support`` says where the tests LOOK. The two cannot share
        a constant (the support library must not import ``repro.nim``), which
        is precisely the situation in which a path silently drifts and every
        migrated test starts failing on a missing file.
        """
        declared = re.search(
            r'ctShimFixtureRoot\s*=\s*"([^"]+)"', self.repro_nim
        )
        self.assertIsNotNone(declared, "ctShimFixtureRoot not found in repro.nim")
        support = re.search(
            r'CtShimFixtureDir\*\s*=\s*"([^"]+)"',
            (REPO_ROOT / "libs/repro_test_support/src/repro_test_support.nim")
            .read_text(),
        )
        self.assertIsNotNone(support, "CtShimFixtureDir not found in the support lib")
        self.assertEqual(
            declared.group(1),
            support.group(1),
            "the graph builds the ct-shim fixtures in one directory and the "
            "tests look for them in another",
        )

    def test_every_declared_fixture_artifact_has_a_producing_edge(self):
        """A typed input nothing produces is a build that cannot succeed."""
        rows = fixture_table_rows(self.repro_nim)
        self.assertTrue(rows, "testFixtureArtifacts did not parse")
        declared_actions = set(
            re.findall(r'actionId\s*=\s*"([^"]+)"', self.repro_nim)
        )
        for source, actions in sorted(rows.items()):
            self.assertTrue(actions, f"{source} lists no artifacts")
            for action in actions:
                self.assertIn(
                    action,
                    declared_actions,
                    f"{source} depends on action {action}, which no edge in "
                    "repro.nim declares",
                )


class ReproInvocationIntegrationPath(unittest.TestCase):
    """M3 verification: test_repro_invocation_integration_path.

    "A test that intentionally invokes `repro` remains valid and is classified
    as an integration test rather than a runtime-compilation violation."

    This is the discrimination M3's third outstanding task calls the hard part.
    `repro build` runs compilers — that is its job — so an audit that fired on
    "a compiler ran somewhere downstream" would condemn the entire integration
    surface the milestone explicitly says to preserve.
    """

    SOURCE = "tests/integration/t_synthetic_repro_invocation.nim"

    def spec(self, source: str):
        return inventory.TestSpec(
            source=source,
            binary="build/test-bin/" + Path(source).stem,
            defines=[],
            requires_repro_binary=True,
            target_os="soAny",
        )

    def test_repro_invocation_integration_path(self):
        # NOT A VIOLATION: the test spawns the product, not a compiler.
        spawns, product_api = audit.classify_source(
            inventory, self.SOURCE, REPRO_INVOKING_TEST
        )
        self.assertFalse(
            spawns,
            "a test that invokes `repro` was reported as compiling a helper; "
            "this audit would condemn the integration suite",
        )
        self.assertFalse(product_api)

        # CLASSIFIED AS INTEGRATION, not as a runtime-compilation entry.
        verdict, reason = inventory.classify(
            self.spec(self.SOURCE), REPRO_INVOKING_TEST, [], REPO_ROOT
        )
        self.assertEqual(verdict, "integration", reason)

        # And the audit accepts a whole tree of such tests with an EMPTY
        # disposition list — no exemption row is needed, because there is
        # nothing to exempt.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            write_tree(root, {self.SOURCE: REPRO_INVOKING_TEST},
                       requires_repro=(self.SOURCE,))
            dispositions = root / "dispositions.tsv"
            write_dispositions(dispositions, {})
            code, failures = audit.check(root, dispositions)
            self.assertEqual(
                code, 0, f"a pure `repro`-invoking test was refused: {failures}"
            )

    def test_the_same_test_IS_refused_once_it_compiles_a_helper(self):
        """MUTATION that proves the arm above is discrimination, not silence.

        Same file, same `repro` invocations, plus one `nim c`. If this still
        passed, the check would simply be blind rather than discriminating.
        """
        mutated = REPRO_INVOKING_TEST + fixture(
            "repro_invoking_plus_compile_tail"
        )
        spawns, _ = audit.classify_source(inventory, self.SOURCE, mutated)
        self.assertTrue(
            spawns,
            "adding a real `nim c` to a repro-invoking test changed nothing; "
            "the audit cannot see helper compilation at all",
        )

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            write_tree(root, {self.SOURCE: mutated},
                       requires_repro=(self.SOURCE,))
            dispositions = root / "dispositions.tsv"
            write_dispositions(dispositions, {})
            code, failures = audit.check(root, dispositions)
            self.assertEqual(code, 1)
            self.assertTrue(any("UNREVIEWED" in f for f in failures), failures)

    def test_the_live_integration_surface_is_not_condemned(self):
        """Against the real tree, not a synthetic one.

        The tracked disposition list must not have swept the integration suite
        into itself: `product-api` rows are recorded as legitimate, and the
        overwhelming majority of tests that invoke `repro` carry no row at all
        because they never trip the audit.
        """
        rows, errors = audit.read_dispositions(audit.DISPOSITIONS)
        self.assertEqual(errors, [])
        nim_specs, _ = inventory.parse_repro_tests(REPO_ROOT)
        integration = [
            spec
            for spec in nim_specs
            if spec.source.startswith("tests/integration/")
            or spec.source.startswith("tests/e2e/")
        ]
        self.assertGreater(len(integration), 100, "no integration suite found")
        flagged = [spec.source for spec in integration if spec.source in rows]
        self.assertLess(
            len(flagged),
            len(integration) // 4,
            "more than a quarter of the integration suite needs a disposition "
            "row; the audit is flagging normal product invocations",
        )


if __name__ == "__main__":
    unittest.main()
