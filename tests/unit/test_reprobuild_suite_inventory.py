import copy
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "reprobuild_suite_inventory.py"
SPEC = importlib.util.spec_from_file_location("reprobuild_suite_inventory", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
inventory = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = inventory
SPEC.loader.exec_module(inventory)


class SuiteInventoryTests(unittest.TestCase):
    def assert_nim_case_counter_lexes_declarations_not_fixture_text(self):
        source = r'''
import std/unittest

# test "line comment":
#[ test "block comment":
   #[ test "nested block comment": ]#
]#
const ordinary = "test \"escaped quote fixture\":"
const raw = r"test ""raw fixture"":"
const triple = """
test "generated Nim fixture":
  check false
test -n "$shell_fixture"
"""
const rawTriple = r"""
test "raw generated fixture":
  check false
"""
const generalized = fmt"""
test "interpolated generated fixture {value}":
  check false
"""

proc testHelper() = discard
testHelper()
testCase "false identifier prefix":
  discard
contest "false identifier suffix":
  discard
test = "assignment is not a declaration":
  discard
object.test "qualified call is not a declaration":
  discard
let invalid =
  test "continued expression is not a declaration":
    discard
let invalidWordOperator = condition and
  test "word-operator continuation is not a declaration":
    discard
call(
  test "nested call is not a declaration":
    discard
)

suite "real suite":
  test "literal":
    check true
  test "escaped quote: \"":
    check true
  test "multiline " &
       "concatenation":
    check true
  test dynamicName(value):
    check true
  test buildName(
      nestedCall(1, {"colon": otherCall(2, @[3, 4])}),
      suffix = "value"
    ):
    check true
  test
    nameFrom(
      "expression on the following line"
    ):
    check true
  test r"raw declaration name":
    check true
  test """triple declaration name""":
    check true
  test fmt"generalized {value} name":
    check true
  test "same-line body": check true
  t_e_s_t "style-insensitive identifier":
    check true
  `test` "quoted identifier":
    check true
  test condition and
       otherCondition:
    check true

test "symbolic operator cannot end a name" &:
  check false
test "word operator cannot end a name" and:
  check false
test "missing body":
test "missing colon"
test "real after truncation":
  check true
test "unbalanced name at EOF" & (
'''
        counted = inventory.count_nim_cases(source)
        self.assertEqual(counted["suiteCount"], 1)
        self.assertEqual(counted["caseCount"], 14)
        self.assertEqual(counted["suites"], ["real suite"])

    def run_nim_fixture(
        self,
        source: str,
        *,
        command: str = "c",
        run: bool = False,
        companions: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess:
        nim = subprocess.check_output(
            ["bash", "-c", "command -v nim"], text=True
        ).strip()
        with tempfile.TemporaryDirectory(prefix="repro-m0-nim-parser-") as tmp:
            root = Path(tmp)
            source_path = root / "fixture.nim"
            source_path.write_text(source, encoding="utf-8")
            for name, content in (companions or {}).items():
                (root / name).write_text(content, encoding="utf-8")
            args = [
                nim,
                command,
                "--colors:off",
                "--hints:off",
                "--verbosity:0",
                f"--nimcache:{root / 'nimcache'}",
                f"--path:{root}",
            ]
            if run:
                args.append("-r")
            args.append(str(source_path))
            return subprocess.run(
                args,
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def assert_nim_case_counter_accepts_compiler_backed_statement_forms(self):
        source = r'''
import std/unittest

suite "inline suite": test "inline suite case": check true
if true: test "inline conditional": check true
test "semicolon first": check true; test "semicolon second": check true
test "continued " &
     "operator name":
  check true
test ("nested " & $(1 + 1)):
  check true
'''
        compiled = self.run_nim_fixture(source, run=True)
        self.assertEqual(compiled.returncode, 0, compiled.stdout)
        self.assertEqual(compiled.stdout.count("[OK]"), 6, compiled.stdout)
        counted = inventory.count_nim_cases(source)
        self.assertEqual(counted["suiteCount"], 1)
        self.assertEqual(counted["caseCount"], 6)
        self.assertEqual(counted["suites"], ["inline suite"])

    def assert_nim_case_counter_resolves_only_imported_unittest_receivers(self):
        standard_source = r'''
import std/unittest

unittest.suite "qualified standard suite":
  unittest.test "qualified standard case":
    check true
'''
        compiled = self.run_nim_fixture(standard_source, run=True)
        self.assertEqual(compiled.returncode, 0, compiled.stdout)
        self.assertEqual(compiled.stdout.count("[OK]"), 1, compiled.stdout)
        self.assertEqual(
            inventory.count_nim_cases(standard_source),
            {
                "suiteCount": 1,
                "caseCount": 1,
                "suites": ["qualified standard suite"],
            },
        )

        alias_source = r'''
import std/unittest as unit

unit.suite "qualified alias suite":
  unit.test "qualified alias case":
    doAssert true
'''
        compiled = self.run_nim_fixture(alias_source, run=True)
        self.assertEqual(compiled.returncode, 0, compiled.stdout)
        self.assertEqual(compiled.stdout.count("[OK]"), 1, compiled.stdout)
        self.assertEqual(
            inventory.count_nim_cases(alias_source),
            {
                "suiteCount": 1,
                "caseCount": 1,
                "suites": ["qualified alias suite"],
            },
        )

        arbitrary_receiver_source = r'''
import fake_receiver as unittest

unittest.test "custom receiver, not std/unittest":
  doAssert true
'''
        compiled = self.run_nim_fixture(
            arbitrary_receiver_source,
            run=True,
            companions={
                "fake_receiver.nim": r'''
template test*(name: string; body: untyped) =
  body
''',
            },
        )
        self.assertEqual(compiled.returncode, 0, compiled.stdout)
        self.assertEqual(
            inventory.count_nim_cases(arbitrary_receiver_source)["caseCount"],
            0,
        )

    def assert_nim_case_counter_rejects_compiler_rejected_operator_endings(self):
        invalid_sources = {
            "symbolic": r'''
import std/unittest
test "incomplete name" &:
  check false
''',
            "word": r'''
import std/unittest
test "incomplete name" and:
  check false
''',
        }
        for name, source in invalid_sources.items():
            with self.subTest(name=name):
                checked = self.run_nim_fixture(source, command="check")
                self.assertNotEqual(checked.returncode, 0, checked.stdout)
                self.assertIn("Error:", checked.stdout)
                counted = inventory.count_nim_cases(source)
                self.assertEqual(counted["suiteCount"], 0)
                self.assertEqual(counted["caseCount"], 0)

    def assert_inventory_case_counts_pin_multiline_and_fixture_regressions(
        self, data
    ):
        by_source = {item["source"]: item for item in data["tests"]}

        # ``sourceCaseCount`` is now the BUILT BINARY's own case count, read
        # from ``--list-json`` (spec §3.2/§6.5). ``staticCaseCount`` retains
        # the old source-text scan alongside it. The two pin blocks below are
        # therefore separate on purpose:
        #
        #  * ``expected_static_multiline_counts`` keeps this file's original
        #    coverage of the lexer, which must not count ``test "..."`` text
        #    appearing inside triple-quoted fixture strings or comments. That
        #    property lives in ``count_nim_cases`` and is still worth pinning
        #    even though it no longer decides the inventory's number.
        #  * ``expected_catalog_multiline_counts`` pins the authoritative
        #    number for the same sources.
        #
        # Where the two disagree, the static scanner is wrong by construction
        # (it sums every ``when``/``else`` branch when only one registers, and
        # it cannot see cases declared through a wrapper template), which is
        # exactly why the binary is now the authority.
        expected_static_multiline_counts = {
            "libs/repro_cli_support/tests/test_engine_publisher_wiring.nim": 5,
            "libs/repro_profile_compile/tests/t_template_in_template_named_args.nim": 2,
            # 1, not 71: the cases are registered by a `for` loop over a
            # 71-element const seq (`for example in PopulatedExamples: test
            # "example " & example & ...`), so there is exactly one literal
            # `test` declaration in the source text.
            "libs/repro_standard_provider/tests/test_examples_layout.nim": 1,
            "tests/e2e/m72/t_integration_stow_non_destructive_over_existing.nim": 4,
            # 8, not 4: this file gained a second ``when`` branch declaring
            # the SAME four case names, and the scanner sums both branches.
            # The static number moved; the real case count did not.
            "tests/e2e/m76/t_integration_stow_byte_identical_target_is_cache_hit.nim": 8,
            "tests/e2e/m79/t_integration_shell_integration_replan_idempotent.nim": 1,
            "tests/e2e/m83/t_e2e_profile_modules.nim": 6,
        }
        for source, expected in expected_static_multiline_counts.items():
            with self.subTest(static_source=source):
                self.assertEqual(by_source[source]["staticCaseCount"], expected)

        expected_catalog_multiline_counts = {
            "libs/repro_cli_support/tests/test_engine_publisher_wiring.nim": 5,
            "libs/repro_profile_compile/tests/t_template_in_template_named_args.nim": 2,
            # 71, not the static 1: catalog-sourced. A `for` loop registers
            # one case per element of a 71-element const seq; a static
            # scanner would have to evaluate the loop to see them.
            "libs/repro_standard_provider/tests/test_examples_layout.nim": 71,
            # 1, not the static 4: catalog-sourced. Only one ``when`` branch
            # registers on this platform.
            "tests/e2e/m72/t_integration_stow_non_destructive_over_existing.nim": 1,
            # 4, unchanged in value but no longer coincidental: the static
            # scanner now says 8 for this file (two branches x four names),
            # and it was this disagreement that exposed the whole defect.
            "tests/e2e/m76/t_integration_stow_byte_identical_target_is_cache_hit.nim": 4,
            "tests/e2e/m79/t_integration_shell_integration_replan_idempotent.nim": 1,
            "tests/e2e/m83/t_e2e_profile_modules.nim": 6,
        }
        for source, expected in expected_catalog_multiline_counts.items():
            with self.subTest(catalog_source=source):
                self.assertEqual(by_source[source]["countSource"], "catalog")
                self.assertEqual(by_source[source]["sourceCaseCount"], expected)

        # The three test files added while this scanner change was in review
        # contribute five real cases. The exact-destination ref-validation
        # change contributes one more case in its existing source. Pin each
        # source independently so aggregate drift cannot be accepted by merely
        # updating the totals below.
        #
        # Every value in this block is unchanged by the move to catalog
        # counting: the binary and the scanner agree on all nine sources.
        expected_rebased_source_counts = {
            # 6, not 5: the automatic-build-memory-capacity change added a
            # sixth case here without bumping this pin, which is exactly the
            # drift these per-source pins exist to catch.
            "libs/repro_cli_support/tests/t_daemon_carried_environment.nim": 6,
            "libs/repro_resources/tests/"
            "t_attr_missing_interface_diagnostic.nim": 1,
            "libs/repro_resources/tests/t_attr_ssz_envelope_roundtrip.nim": 3,
            "libs/repro_resources/tests/t_rss_ssz_envelope_roundtrip.nim": 4,
            "tests/integration/t_d6_runner_test_timeout.nim": 3,
            "tests/integration/t_extension_type_lifted_and_consumed.nim": 1,
            "tests/integration/t_local_daemons_control_plane_m10.nim": 6,
            "tests/integration/t_pre_push_protocol_v2_ref_validation.nim": 3,
            # 9, not 8: the refusal-outranks-document regression adds
            # "a refused per-case PASS document never overturns the
            # refusal" to this file's existing suite. Counted from the
            # rebuilt binary's own `--list-json` (9) and cross-checked
            # against the static scan (9), which agree.
            "tests/integration/"
            "t_repro_test_runner_process_group_cleanup.nim": 9,
        }
        for source, expected in expected_rebased_source_counts.items():
            with self.subTest(source=source):
                self.assertEqual(by_source[source]["sourceCaseCount"], expected)

        # M2 step 2 adds exactly three new test sources. Pin each one by
        # source path, count provenance and exact case count so a new file
        # can never be absorbed silently into the aggregate totals below.
        expected_m2_step2_sources = {
            # 4, not 3: the crash-before-the-document regression adds
            # "a child that dies before writing its document still
            # reports why" to this file. Counted from the rebuilt
            # binary's `--list-json` (4); the static scan agrees (4).
            "tests/integration/"
            "t_repro_test_runner_consumes_result_document.nim": 4,
            "tests/integration/"
            "t_repro_test_runner_suiteless_case_round_trip.nim": 1,
            "tests/unit/t_declared_package_deps_from_recipe.nim": 6,
        }
        for source, expected in expected_m2_step2_sources.items():
            with self.subTest(m2_source=source):
                self.assertTrue((REPO_ROOT / source).is_file())
                self.assertIn(source, by_source)
                self.assertEqual(by_source[source]["countSource"], "catalog")
                self.assertEqual(by_source[source]["sourceCaseCount"], expected)

        # The opaque out-of-tree resource regression landed after the scanner
        # work was merged. Pin its enrollment and classification independently
        # from the aggregate totals below: changing only the totals must not be
        # enough to hide a missing or miscounted catalog entry.
        opaque_out_of_tree = by_source[
            "tests/integration/t_run_consumes_opaque_out_of_tree.nim"
        ]
        self.assertEqual(opaque_out_of_tree["language"], "nim")
        self.assertEqual(opaque_out_of_tree["sourceSuiteCount"], 1)
        self.assertEqual(opaque_out_of_tree["sourceCaseCount"], 1)
        self.assertEqual(opaque_out_of_tree["class"], "integration")

        # These files generate test programs at runtime. Their declarations
        # inside triple-quoted fixture strings are not cases in the host file.
        self.assertEqual(
            by_source[
                "tests/integration/t_repro_test_runner_aggregate_exit_code.nim"
            ]["sourceCaseCount"],
            2,
        )
        self.assertEqual(
            by_source[
                "tests/integration/t_repro_test_runner_parallel_n_workers.nim"
            ]["sourceCaseCount"],
            2,
        )
        macho = REPO_ROOT / "tests/integration/t_macho_runtime_audit.nim"
        self.assertEqual(
            len(
                re.findall(
                    r"(?m)^\s*test\s",
                    macho.read_text(encoding="utf-8"),
                )
            ),
            50,
        )
        self.assertEqual(
            by_source[macho.relative_to(REPO_ROOT).as_posix()]["sourceCaseCount"],
            15,
        )

        nim_specs, python_specs = inventory.parse_repro_tests(REPO_ROOT)
        graph_sources = {spec.source for spec in nim_specs}
        graph_binaries = {spec.binary for spec in nim_specs}

        # Enrollment pins for sources that reached the tree without exact
        # inventory coverage: the ten-case workspace branch-fork integration
        # test (present in the generated graph but unpinned) and five
        # from-source recipe tests that were on disk but missing from the
        # generated graph entirely. Pin each by exact source path, exact
        # generated binary path, generated-graph membership, language, suite
        # count, per-source case count, and classification. Deleting an
        # enrollment, substituting a different source for it, or drifting a
        # per-source case count therefore fails this gate on its own, without
        # relying on the aggregate totals below.
        expected_enrollments = {
            "recipes/packages/source/dejavu-fonts/"
            "test_dejavu_fonts_source.nim": {
                "binary": "build/test-bin/test_dejavu_fonts_source",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "pure unit",
            },
            "recipes/packages/source/font-util/"
            "test_font_util_source.nim": {
                "binary": "build/test-bin/test_font_util_source",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "pure unit",
            },
            "recipes/packages/source/libpciaccess/"
            "test_libpciaccess_source.nim": {
                "binary": "build/test-bin/test_libpciaccess_source",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "pure unit",
            },
            "recipes/packages/source/util-macros/"
            "test_util_macros_source.nim": {
                "binary": "build/test-bin/test_util_macros_source",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "pure unit",
            },
            "recipes/packages/source/xorg-server/"
            "test_xorg_server_source.nim": {
                "binary": "build/test-bin/test_xorg_server_source",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 2,
                "class": "pure unit",
            },
            # 10 -> 14. The workspace-CLI verb split (`0b9205f7`) added four
            # cases to this file — `t_workspace_new_derives_branch_from_`
            # `basename`, `t_branch_refuses_destination_inside_workspace`,
            # `t_workspace_new_existing_branch_checks_out` and
            # `t_workspace_new_requires_a_destination_path` — and the pin was
            # not moved. It kept passing anyway, because the binary in
            # `build/test-bin/` was never rebuilt after that edit and went on
            # reporting the ten cases it was compiled from. A count read from
            # a stale artifact agrees with a stale pin indefinitely, which is
            # the one way this file's per-source pins can fail silently. The
            # binary is rebuilt and the source's static scan independently
            # reads 14, so the two surfaces now agree.
            "tests/integration/"
            "t_branch_forks_new_workspace_on_feature_branch.nim": {
                "binary": "build/test-bin/"
                "t_branch_forks_new_workspace_on_feature_branch",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 14,
                "class": "integration",
            },
            "recipes/packages/source/grub/test_grub_source.nim": {
                "binary": "build/test-bin/test_grub_source",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 2,
                "class": "pure unit",
            },
            "libs/repro_cli_support/tests/"
            "t_lock_publish_push_race_classification.nim": {
                "binary": "build/test-bin/"
                "t_lock_publish_push_race_classification",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 7,
                "class": "pure unit",
            },
            # RA-32 — the lock record's repo component is ONE path
            # component; a record written before that rule is REFUSED and
            # reported by the publisher, never relocated by it, and repaired
            # only by the explicit ``repro workspace migrate-locks`` verb.
            # Drives the real ``GitCheckoutLockStore``,
            # ``CommittedFileLockStore`` and ``SeparateBranchLockStore``
            # against real ``git`` checkouts, so it classifies as integration
            # rather than pure unit despite living beside the pure-unit
            # classifier test above.
            "libs/repro_cli_support/tests/"
            "t_lock_record_repo_component_is_one_path_segment.nim": {
                "binary": "build/test-bin/"
                "t_lock_record_repo_component_is_one_path_segment",
                "language": "nim",
                "sourceSuiteCount": 2,
                "sourceCaseCount": 17,
                "class": "integration",
            },
            # The `repro infra apply` hung-lock-owner gate. Spawns a real
            # child process that holds the apply lock, so it classifies as
            # integration rather than pure unit.
            "tests/unit/t_infra_apply_lock_hung_owner.nim": {
                "binary": "build/test-bin/t_infra_apply_lock_hung_owner",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 5,
                "class": "integration",
            },
            "tests/integration/"
            "t_is_published_accepts_any_remote_name.nim": {
                "binary": "build/test-bin/"
                "t_is_published_accepts_any_remote_name",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "libs/repro_interface_artifacts/tests/"
            "t_windows_dynlib_staging.nim": {
                "binary": "build/test-bin/t_windows_dynlib_staging",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 4,
                "class": "platform/destructive",
            },
            # The daemon accept-loop survival gate. Starts a real daemon
            # process and drives it over a real unix socket, so it
            # classifies as integration rather than pure unit.
            "tests/integration/"
            "t_daemon_accept_loop_survives_probe.nim": {
                "binary": "build/test-bin/"
                "t_daemon_accept_loop_survives_probe",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 3,
                "class": "integration",
            },
            # M2 step 1: catalog fidelity and hash-difference selection.
            # Compiles real fixture binaries with the real toolchain and
            # drives the real compiled runner as a subprocess, so it
            # classifies as integration rather than pure unit.
            "tests/integration/"
            "t_repro_test_runner_catalog_selection.nim": {
                "binary": "build/test-bin/"
                "t_repro_test_runner_catalog_selection",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 4,
                "class": "integration",
            },
            # The workspace-CLI verb split (`0b9205f7`). It renamed six
            # integration sources, added two, and added four cases to the
            # branch-fork source pinned above — so each of the nine affected
            # sources is pinned here individually, which is what makes the
            # aggregate reconciliation below checkable rather than asserted.
            #
            # RENAMED (six). A rename is a removal plus an addition, so it
            # can only be shown to net out by pinning the replacement's case
            # count against the count its predecessor carried. Each of these
            # six reports exactly what the pre-rename binary reported —
            # 2, 5, 7, 1, 2, 6 = 23 cases before and 23 after — so the
            # renames contribute 0 to both the spec count and the case total.
            #
            #   t_project_new_writes_and_pushes_manifest
            #     -> t_projects_add_writes_and_pushes_manifest       (2)
            #   t_project_repo_add_reuses_remotes_and_inherits_revision
            #     -> t_repos_add_reuses_remotes_and_inherits_revision (5)
            #   t_branch_checkout_marks_feature_branch
            #     -> t_switch_new_branch_marks_feature_branch        (7)
            #   t_checkout_stashes_and_restores_per_repo_wip
            #     -> t_switch_stashes_and_restores_per_repo_wip      (1)
            #   t_workspace_projects_add_clones_added_repos
            #     -> t_workspace_enable_materializes_added_projects  (2)
            #   t_workspace_checkout_switches_all_repos
            #     -> t_workspace_switch_switches_all_repos           (6)
            "tests/integration/"
            "t_projects_add_writes_and_pushes_manifest.nim": {
                "binary": "build/test-bin/"
                "t_projects_add_writes_and_pushes_manifest",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 2,
                "class": "integration",
            },
            "tests/integration/"
            "t_repos_add_reuses_remotes_and_inherits_revision.nim": {
                "binary": "build/test-bin/"
                "t_repos_add_reuses_remotes_and_inherits_revision",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 5,
                "class": "integration",
            },
            "tests/integration/"
            "t_switch_new_branch_marks_feature_branch.nim": {
                "binary": "build/test-bin/"
                "t_switch_new_branch_marks_feature_branch",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 7,
                "class": "integration",
            },
            "tests/integration/"
            "t_switch_stashes_and_restores_per_repo_wip.nim": {
                "binary": "build/test-bin/"
                "t_switch_stashes_and_restores_per_repo_wip",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_workspace_enable_materializes_added_projects.nim": {
                "binary": "build/test-bin/"
                "t_workspace_enable_materializes_added_projects",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 2,
                "class": "integration",
            },
            "tests/integration/"
            "t_workspace_switch_switches_all_repos.nim": {
                "binary": "build/test-bin/"
                "t_workspace_switch_switches_all_repos",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 6,
                "class": "integration",
            },
            # ADDED (two). `enable`/`disable` membership and the manifest
            # definition verbs are new behaviour, not a renaming of old
            # behaviour, so these two are the entire +2 on the spec count
            # and +9 of the +13 on the case total; the remaining +4 is the
            # branch-fork source above. Both drive the real `repro` binary
            # against real git repositories, hence `integration`.
            "tests/integration/"
            "t_workspace_definition_projects_repos.nim": {
                "binary": "build/test-bin/"
                "t_workspace_definition_projects_repos",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 5,
                "class": "integration",
            },
            "tests/integration/"
            "t_workspace_membership_enable_disable.nim": {
                "binary": "build/test-bin/"
                "t_workspace_membership_enable_disable",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 4,
                "class": "integration",
            },
            # The regression guard for a suite-body `echo` corrupting a
            # protocol document. Pinned per source so its four cases are the
            # whole of this change's delta on the aggregates below, rather
            # than a number the aggregates have to be trusted about.
            "tests/integration/"
            "t_protocol_document_survives_suite_body_echo.nim": {
                "binary": "build/test-bin/"
                "t_protocol_document_survives_suite_body_echo",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 4,
                "class": "integration",
            },
            # Upstream `7e503ddd2` adds the fully-qualified-tag regression to
            # this already-enrolled source (2 -> 3 cases). Pin its exact
            # source-to-binary mapping and current catalog count so the +1
            # static reconciliation below cannot be left as an unattributed
            # aggregate adjustment.
            # 3 -> 4: the discarded-checkout regression
            # (`t_sync_discards_a_checkout_that_failed_after_the_clone`)
            # landed in this source without moving this pin or either
            # aggregate, so `dev` has been failing its own inventory gate
            # since. Recomputed, not bumped: the binary was rebuilt from the
            # source that carries the fourth case and its own `--list-json`
            # counted (4); the independent static scan of the source agrees
            # (4). The case is unconditional — it `skip()`s when `git` is
            # absent rather than declaring itself away — so it moves Linux
            # and Darwin alike and the exact platform delta below is
            # untouched.
            "tests/integration/t_sync_clones_commit_pinned_repo.nim": {
                "binary": "build/test-bin/t_sync_clones_commit_pinned_repo",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 4,
                "class": "integration",
            },
            # Upstream 391a892a4 adds five independently enrolled `develop`
            # regressions. Pin every source-to-binary mapping and each built
            # catalog's one case here so the aggregate +5 below cannot hide a
            # missing enrollment behind an unrelated added case.
            "tests/integration/"
            "t_develop_all_clones_into_a_second_placement_root.nim": {
                "binary": "build/test-bin/"
                "t_develop_all_clones_into_a_second_placement_root",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_composes_lock_set_without_a_committed_lock.nim": {
                "binary": "build/test-bin/"
                "t_develop_composes_lock_set_without_a_committed_lock",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_refuses_inexact_revision_and_leaves_no_checkout.nim": {
                "binary": "build/test-bin/"
                "t_develop_refuses_inexact_revision_and_leaves_no_checkout",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_refuses_unreadable_backend_before_membership_degrades.nim": {
                "binary": "build/test-bin/"
                "t_develop_refuses_unreadable_backend_before_membership_degrades",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_refuses_unreadable_backend_of_any_kind.nim": {
                "binary": "build/test-bin/"
                "t_develop_refuses_unreadable_backend_of_any_kind",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            # Upstream 3b338d82c/e106faf6e extends two already-enrolled
            # runtime-loader sources by exactly three catalog cases. Pin both
            # source-to-binary mappings so the aggregate +3 cannot hide drift.
            "tests/unit/t_m9r14e_3_action_env_threading.nim": {
                "binary": "build/test-bin/t_m9r14e_3_action_env_threading",
                "language": "nim",
                "sourceSuiteCount": 2,
                "sourceCaseCount": 29,
                "class": "pure unit",
            },
            "libs/repro_build_engine/tests/"
            "test_tool_identity_env_plumbing.nim": {
                "binary": "build/test-bin/test_tool_identity_env_plumbing",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 9,
                "class": "pure unit",
            },
            # Upstream 11cea6789 enrolls six one-case develop-selection
            # integrations. Pin every source-to-binary mapping so a later
            # aggregate-preserving replacement cannot hide graph drift.
            "tests/integration/"
            "t_develop_dependency_modes_walk_a_real_depends_graph.nim": {
                "binary": "build/test-bin/"
                "t_develop_dependency_modes_walk_a_real_depends_graph",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_at_rev_walks_to_nearest_locked_ancestor.nim": {
                "binary": "build/test-bin/"
                "t_develop_at_rev_walks_to_nearest_locked_ancestor",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_list_reports_tier_and_backend.nim": {
                "binary": "build/test-bin/"
                "t_develop_list_reports_tier_and_backend",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_lock_store_supplies_private_route.nim": {
                "binary": "build/test-bin/"
                "t_develop_lock_store_supplies_private_route",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_only_except_refuse_unknown_names.nim": {
                "binary": "build/test-bin/"
                "t_develop_only_except_refuse_unknown_names",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            "tests/integration/"
            "t_develop_selectors_compose_in_fixed_order.nim": {
                "binary": "build/test-bin/"
                "t_develop_selectors_compose_in_fixed_order",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            # Four test sources already present at upstream 391a892a4 were
            # omitted from its checked-in generated graph. Regeneration enrolls
            # exactly these four; fresh binary catalogs account for all 29
            # cases (7 + 5 + 14 + 3).
            "libs/repro_deploy_agent/tests/"
            "t_repro_deploy_agent_manifest_v2_secrets.nim": {
                "binary": "build/test-bin/"
                "t_repro_deploy_agent_manifest_v2_secrets",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 7,
                "class": "pure unit",
            },
            "libs/repro_deploy_agent/tests/"
            "t_repro_deploy_agent_materialises_secrets.nim": {
                "binary": "build/test-bin/"
                "t_repro_deploy_agent_materialises_secrets",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 5,
                "class": "pure unit",
            },
            "libs/repro_deploy_agent/tests/"
            "t_repro_deploy_agent_secrets_seal_open.nim": {
                "binary": "build/test-bin/"
                "t_repro_deploy_agent_secrets_seal_open",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 14,
                "class": "pure unit",
            },
            "tests/integration/t_branch_fork_inherits_project_set.nim": {
                "binary": "build/test-bin/t_branch_fork_inherits_project_set",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 3,
                "class": "integration",
            },
            # Both Linux and Darwin register 38 cache-daemon cases: Linux keeps
            # exact-old interop while Darwin substitutes v1/v2 isolation, and
            # both add legacy-wire interop. The static scan sees both
            # conditional declarations and therefore reports 39 below.
            "tests/integration/"
            "t_cache_daemon_drains_dedups_persists_and_warms_from_disk.nim": {
                "binary": "build/test-bin/"
                "t_cache_daemon_drains_dedups_persists_and_warms_from_disk",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 38,
                "class": "integration",
            },
            # A separate graph spec carries the compile-time unavailable-ID
            # seam, so production and test configurations cannot be confused.
            "tests/integration/"
            "t_shm_index_boot_id_unavailable_fails_closed.nim": {
                "binary": "build/test-bin/"
                "t_shm_index_boot_id_unavailable_fails_closed",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            # The linked-worktree hook regression added by this branch. Its
            # three cases independently cover the canonical scrub helper,
            # Workspace-VCS selection under a poisoned repository-local Git
            # environment, and a real protocol-v2 pre-push through a linked
            # worktree. Pin the exact source, generated binary, catalog size,
            # and classification so the aggregate +1 source / +3 cases below
            # cannot mask a missing or weakened enrollment.
            "tests/integration/"
            "t_linked_worktree_pre_push_repository_env.nim": {
                "binary": "build/test-bin/"
                "t_linked_worktree_pre_push_repository_env",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 3,
                "class": "integration",
            },
            # The post-commit publication-reporting guard (M19b). An EXISTING
            # enrollment that gained a second suite and three cases: post-commit
            # must never report a locally-written, unpublished lock as success.
            # Pinned per source so those three cases are the whole of this
            # change's delta on the aggregates below — the source is otherwise
            # invisible to them, which is how the +4 on
            # `t_branch_forks_new_workspace_on_feature_branch.nim` once hid.
            # 1 suite / 5 cases -> 2 suites / 8 cases.
            # 8 -> 10 (RA-30): the two anchoring cases — a lock is filed under
            # the repo whose commit fired the hook, and an undeclared
            # triggering checkout writes none at all. Both land in the
            # existing M19b suite, so `sourceSuiteCount` is unchanged.
            "tests/integration/"
            # 10 -> 12: the two RA-31 cases pinning that the gate may
            # supersede its OWN unpublished lock draft but still refuses a
            # TRACKED record. Recomputed, not bumped: the binary was rebuilt
            # from the source that carries them and its own `--list-json`
            # counted (12); the independent static scan of the source agrees
            # (12). Both are unconditional -- they `skip()` when `git` is
            # absent rather than declaring themselves away -- so they move
            # Linux and Darwin alike and the exact platform delta is
            # untouched.
            # 12 -> 13: one case pinning that this file's own fixture seeds
            # three DISTINGUISHABLE repos. Identical seed content plus one
            # shared identity left the commit timestamp as the only input to
            # the seed SHAs, so three seeds made in one second hashed to a
            # single commit object -- and a case asserting a superseded
            # revision was gone from a lock record then read a sibling's
            # entry that carried the same SHA, failing 4 runs in 10 on a
            # correct record. Recomputed, not bumped: the binary was rebuilt
            # and its own `--list-json` counted (13 cases, 2 suites); the
            # independent static scan of the source agrees (13/2). The case
            # is unconditional -- it `skip()`s when `git` is absent rather
            # than declaring itself away -- so it moves Linux and Darwin
            # alike and the exact platform delta is untouched.
            "t_workspace_post_commit_lock_refresh_is_best_effort.nim": {
                "binary": "build/test-bin/"
                "t_workspace_post_commit_lock_refresh_is_best_effort",
                "language": "nim",
                "sourceSuiteCount": 2,
                "sourceCaseCount": 13,
                "class": "integration",
            },
            # The `repro develop --all` post-condition added by this branch.
            # One case, and it is the whole of this change's delta on the
            # aggregates: the command must not report a checkout it cannot
            # show you. Drives the real `repro` binary against real git
            # repositories, hence `integration`.
            "tests/integration/"
            "t_develop_all_refuses_to_report_an_absent_checkout.nim": {
                "binary": "build/test-bin/"
                "t_develop_all_refuses_to_report_an_absent_checkout",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
            # A RECOVERED enrollment, not a new test. This source was already
            # on disk and already passing, but it was missing from the
            # checked-in generated graph, so it was never compiled and never
            # executed in CI. Regenerating the graph enrolls it. Pinned here
            # separately from the source above so the +2 on the spec count
            # below is two attributable facts rather than one rounded one.
            "tests/integration/t_branch_fork_clones_root_submodules.nim": {
                "binary": "build/test-bin/t_branch_fork_clones_root_submodules",
                "language": "nim",
                "sourceSuiteCount": 1,
                "sourceCaseCount": 1,
                "class": "integration",
            },
        }
        for source, expected in expected_enrollments.items():
            with self.subTest(enrolled_source=source):
                self.assertTrue((REPO_ROOT / source).is_file())
                self.assertIn(source, graph_sources)
                self.assertIn(expected["binary"], graph_binaries)
                self.assertEqual(
                    [
                        spec.binary
                        for spec in nim_specs
                        if spec.source == source
                    ],
                    [expected["binary"]],
                )
                self.assertIn(source, by_source)
                entry = by_source[source]
                for field in (
                    "language",
                    "sourceSuiteCount",
                    "sourceCaseCount",
                    "class",
                ):
                    with self.subTest(field=field):
                        self.assertEqual(entry[field], expected[field])

        cache_source = (
            "tests/integration/"
            "t_cache_daemon_drains_dedups_persists_and_warms_from_disk.nim"
        )
        fail_closed_source = (
            "tests/integration/"
            "t_shm_index_boot_id_unavailable_fails_closed.nim"
        )
        self.assertEqual(by_source[cache_source]["staticCaseCount"], 39)
        self.assertEqual(by_source[fail_closed_source]["staticCaseCount"], 1)

        # Strong graph mappings for both subprocess peers and their generator.
        # These are action assignments rather than loose substring presence:
        # dropping, duplicating, or pointing an id at another source fails.
        repro_graph = (REPO_ROOT / "repro.nim").read_text(encoding="utf-8")
        expected_helper_actions = {
            "reprobuild.test_helpers.legacy_cache_peer_origin_dev": (
                "tests/fixtures/cache-daemon-origin-dev-9f0a9be/"
                "legacy_cache_peer.nim",
                "build/test-bin/legacy_cache_peer_origin_dev",
            ),
            "reprobuild.test_helpers.legacy_cache_peer_legacy_wire": (
                "tests/fixtures/cache-daemon-origin-dev-9f0a9be/"
                "legacy_cache_peer_legacy_wire.nim",
                "build/test-bin/legacy_cache_peer_legacy_wire",
            ),
        }
        for action_id, (source, binary) in expected_helper_actions.items():
            pattern = (
                r"reprobuildTestHelpersActions\.add\(nim\.c\("
                r"(?:(?!reprobuildTestHelpersActions\.add).)*?"
                r"source\s*=\s*\"" + re.escape(source) + r"\""
                r"(?:(?!reprobuildTestHelpersActions\.add).)*?"
                r"binary\s*=\s*\"" + re.escape(binary) + r"\""
                r"(?:(?!reprobuildTestHelpersActions\.add).)*?"
                r"actionId\s*=\s*\"" + re.escape(action_id) + r"\""
            )
            self.assertEqual(len(re.findall(pattern, repro_graph, re.S)), 1)
        self.assertEqual(
            len(
                re.findall(
                    r"actionId\s*=\s*\"reprobuild\.test_helpers\."
                    r"generate_legacy_cache_peer_wire\"",
                    repro_graph,
                )
            ),
            1,
        )
        for required in (
            "build/test-bin/legacy_cache_peer_origin_dev",
            "build/test-bin/legacy_cache_peer_legacy_wire",
        ):
            self.assertIn(f'requiredBinaries.add("{required}")', repro_graph)
        self.assertIn(
            'defines: @["reproShmIndexTestBootIdUnavailable"]',
            (REPO_ROOT / "repro_tests.nim").read_text(encoding="utf-8"),
        )

        # Exact generated-graph specification counts. An omitted, duplicated,
        # or substituted enrollment cannot be absorbed by the case totals.
        #
        # Recomputed from the inventory module, not bumped arithmetically.
        # Refreshed on the rebase of the hung-lock-owner work onto
        # metacraft-labs/dev @ c9569004 (1203 specs / 6768 nim cases /
        # 6799 total / 1207 entries). This branch adds exactly one spec
        # and 18 nim cases, every one of them attributed:
        #
        #   +1 spec / +5 cases  (new file, new enrollment)
        #     tests/unit/t_infra_apply_lock_hung_owner.nim            (5)
        #
        #   +13 cases in files that were already enrolled
        #     libs/repro_infra/tests/t_smoke_repro_infra.nim   (196->206)
        #     libs/repro_profile_compile/tests/
        #       t_smoke_phase_g_action_edges_integration.nim     (9->11)
        #     libs/repro_infra/tests/
        #       t_smoke_phase_g_runinfraapply_dispatch.nim         (8->9)
        #
        # 1203+1 = 1204 specs, 6768+18 = 6786 nim cases, 6799+18 = 6817
        # overall, 1207+1 = 1208 entries. Every changed source's case
        # count was diffed against dev individually and the four deltas
        # above sum to exactly 18, so there is no unexplained residue.
        #
        # The two sources the pre-rebase branch also enrolled
        # (t_is_published_accepts_any_remote_name.nim and
        # t_windows_dynlib_staging.nim) are NOT counted here: dev enrolled
        # them independently in 62a08fcb, so they are already in the 1203
        # baseline. They remain in the enrollment spot-checks above.
        #
        # ---------------------------------------------------------------
        # M2 step 2 update. Two independent things moved; they are kept
        # separate here so neither can absorb the other.
        #
        # (a) SPEC COUNT 1204 -> 1207. Exactly three new test sources, each
        #     pinned individually in `expected_m2_step2_sources` above:
        #       tests/integration/
        #         t_repro_test_runner_consumes_result_document.nim      (2)
        #       tests/integration/
        #         t_repro_test_runner_suiteless_case_round_trip.nim     (1)
        #       tests/unit/t_declared_package_deps_from_recipe.nim      (6)
        #     +9 cases from new files.
        #
        # (b) COUNT MECHANISM. `sourceCaseCount` is no longer the static
        #     source scan; it is the built binary's own `--list-json`
        #     catalog. This is a change of authority, not a change to the
        #     suite: 58 sources had a static count that disagreed with what
        #     their binary actually registers — 44 static over-counts from
        #     summed `when`/`else` branches, and 14 static under-counts, of
        #     which 13 come from a `gatedTest` wrapper template the scanner
        #     cannot expand and one (test_examples_layout.nim) from a `for`
        #     loop over a const seq the scanner cannot evaluate. The static
        #     scan is retained per entry as `staticCaseCount`.
        #
        # Reconciliation of the Nim case total, computed rather than
        # bumped:
        #     6786  previous pin (static scan, 1204 specs)
        #      -54  net effect of the M2 step-2 edits on the STATIC count
        #           of already-enrolled files (the modified e2e/m69 and
        #           stow files); static total on this tree is 6741 over
        #           1207 specs, of which +9 are the three new files, so
        #           the pre-existing files' static total moved 6786 -> 6732
        #      + 9  the three new files
        #     ----
        #     6741  static total on this tree (= sum of staticCaseCount)
        #      +80  net catalog-vs-static correction across the 58
        #           disagreeing sources
        #     ----
        #     6821  first catalog total on this tree
        #       -1  the quarantined source no longer contributes its
        #           static count. t_n7_multicast_windows_smoke.nim wraps
        #           its whole body in `when defined(windows)` with
        #           `else: discard`, so it registers 0 cases on Linux; the
        #           static scanner sees 1 and that 1 was being added.
        #           That single fallback was the last `when`-branch
        #           over-count in the total, which is precisely what the
        #           binary-as-authority rework exists to remove.
        #     ----
        #     6820  catalog total on this tree — and exactly the number the
        #           independent `--list` cross-check produces, which is why
        #           the two agree only after this correction.
        #
        # The +80 is pinned structurally below (per-source equality against
        # each binary's own `--list`), not asserted as a bare number.
        #
        # ---------------------------------------------------------------
        # Runner reporting-contract update. Exactly one new Nim source and
        # one new Python test method; both deltas are fully attributed and
        # nothing else in the tree moved.
        #
        #   SPECS 1207 -> 1208, NIM CASES 6820 -> 6824
        #     tests/integration/
        #       t_repro_test_runner_reporting_contract.nim            (+4)
        #   Its static and catalog counts agree (4 = 4), so the nim
        #   staticCaseCount aggregate moves by the same +4: 6741 -> 6745,
        #   and `countSourceCounts["catalog"]` 1206 -> 1207.
        #
        #   PYTHON CASES 42 -> 43
        #     test_runner_summary_names_every_case_and_splits_harness_errors
        #   in this file — the consumer half of the same contract.
        #
        #   STATIC TOTAL 6862 -> 6867 = +4 nim +1 python.
        #
        # ---------------------------------------------------------------
        # Per-case failure diagnostics. Exactly one new Nim case, in an
        # EXISTING source, so the spec count does not move:
        #
        #   NIM CASES 6824 -> 6825, SPECS 1208 (unchanged)
        #     tests/integration/
        #       t_repro_test_runner_consumes_result_document.nim      (+1)
        #         "a failing case's report carries the diagnosis, not
        #          just a count"
        #   Its static and catalog counts agree (3 = 3), so the nim
        #   staticCaseCount aggregate moves by the same +1: 6745 -> 6746.
        #
        #   PYTHON CASES 43 (unchanged).
        #   STATIC TOTAL 6867 -> 6868 = +1 nim.
        #
        # ---------------------------------------------------------------
        # Missing-result-document diagnostic. Exactly one new Nim case, in
        # an ALREADY-ENROLLED source, so the spec count does not move and
        # no new enrollment can hide in the totals:
        #
        #   NIM CASES 6825 -> 6826, SPECS 1208 (unchanged)
        #     tests/integration/
        #       t_repro_test_runner_consumes_result_document.nim     (+1)
        #         "a child that dies before writing its document still
        #          reports why"
        #   Recomputed, not bumped: the binary was rebuilt and its own
        #   `--list-json` counted (4, pinned per source above), and the
        #   source's static scan was counted separately and agrees (4).
        #   The delta is therefore +1 on BOTH the catalog aggregate and
        #   the staticCaseCount aggregate: 6746 -> 6747.
        #
        #   PYTHON CASES 43 (unchanged) — the regression adds no Python
        #   test.
        #   STATIC TOTAL 6868 -> 6869 = +1 nim.
        #
        # ---------------------------------------------------------------
        # Refusal outranks a passing document. Exactly one new Nim case,
        # again in an ALREADY-ENROLLED source, so the spec count still
        # does not move:
        #
        #   NIM CASES 6826 -> 6827, SPECS 1208 (unchanged)
        #     tests/integration/
        #       t_repro_test_runner_process_group_cleanup.nim        (+1)
        #         "a refused per-case PASS document never overturns the
        #          refusal"
        #   Recomputed, not bumped: the binary was rebuilt and its own
        #   `--list-json` counted (9, pinned per source above), and the
        #   source's static scan was counted separately and agrees (9).
        #   The delta is therefore +1 on BOTH the catalog aggregate and
        #   the staticCaseCount aggregate: 6747 -> 6748.
        #
        #   PYTHON CASES 43 (unchanged) — the regression adds no Python
        #   test.
        #   STATIC TOTAL 6869 -> 6870 = +1 nim.
        #
        # ---------------------------------------------------------------
        # Daemon accept-loop survival. Exactly one NEW Nim source, so this
        # is the first delta in a while that moves the spec count too:
        #
        #   SPECS 1208 -> 1209, NIM CASES 6827 -> 6830
        #     tests/integration/
        #       t_daemon_accept_loop_survives_probe.nim               (+3)
        #   Recomputed, not bumped: the binary's own `--list-json` reports
        #   3 cases in 1 suite (pinned per source in
        #   `expected_enrollments` above), and the source's static scan was
        #   counted separately and agrees (3). The delta is therefore +3 on
        #   BOTH the catalog aggregate and the staticCaseCount aggregate:
        #   6748 -> 6751, and `countSourceCounts["catalog"]` 1207 -> 1208.
        #
        #   PYTHON CASES 43 (unchanged) — the regression adds no Python
        #   test.
        #   STATIC TOTAL 6870 -> 6873 = +3 nim.
        #
        # ---------------------------------------------------------------
        # M2 step 1: catalog fidelity and hash-difference selection. One
        # NEW Nim source, so the spec count moves again:
        #
        #   SPECS 1209 -> 1210, NIM CASES 6830 -> 6834
        #     tests/integration/
        #       t_repro_test_runner_catalog_selection.nim             (+4)
        #   Recomputed, not bumped: `repro_tests.nim` was regenerated with
        #   `scripts/generate_test_edges.nim` (1209 -> 1210 Nim tests, one
        #   purely additive entry), the binary was built into
        #   `build/test-bin/`, and its own `--list-json` was counted (4
        #   cases in 1 suite, pinned per source in `expected_enrollments`
        #   above). The source's static scan was counted separately and
        #   agrees (4). The delta is therefore +4 on BOTH the catalog
        #   aggregate and the staticCaseCount aggregate: 6751 -> 6755, and
        #   `countSourceCounts["catalog"]` 1208 -> 1209.
        #
        #   PYTHON CASES 43 (unchanged) — the regression adds no Python
        #   test.
        #   STATIC TOTAL 6873 -> 6877 = +4 nim.
        #
        #   PYTHON FILES 4 -> 5, PYTHON CASES 43 -> 46
        #     tests/unit/test_package_root_anchor.py                   (+3)
        #   Recomputed, not bumped: read out of a live `build_inventory`
        #   (`python_total` 46, `pythonTestFileCount` 5). The file is the
        #   package-root-anchor guard added alongside the nim-fork bump to
        #   4e93a8a4; its three cases are
        #     test_fixtures_are_byte_identical_and_share_a_basename
        #     test_repository_declares_a_package_root_anchor_deliberately
        #     test_same_named_sources_in_different_directories_stay_distinct
        #   Its two Nim fixtures live under `tests/fixtures/`, which
        #   `generate_test_edges.nim` excludes, so the Nim counts are
        #   untouched by that change.
        #
        #   SPECS 1210 -> 1212, NIM CASES 6834 -> 6847
        #     tests/integration/
        #       t_workspace_definition_projects_repos.nim            (+5)
        #       t_workspace_membership_enable_disable.nim            (+4)
        #       t_branch_forks_new_workspace_on_feature_branch.nim   (+4)
        #   The workspace-CLI verb split (`0b9205f7`) landed without
        #   recomputing these pins, which is why this assertion has been
        #   failing on `dev` since. It touched the suite three ways:
        #     * RENAMED six integration sources. A rename is a removal plus
        #       an addition, and these net to zero on both numbers: each
        #       replacement reports exactly the case count its predecessor
        #       reported (2, 5, 7, 1, 2, 6 = 23 before and 23 after). All
        #       six are pinned individually in `expected_enrollments` above
        #       precisely so the netting-out is checked, not assumed.
        #     * ADDED two sources, +5 and +4 cases: the whole +2 on the
        #       spec count and +9 of the case delta.
        #     * ADDED four cases to an existing source, 10 -> 14, the
        #       remaining +4. That one hid: the pin passed because the
        #       binary was never rebuilt after the edit, so a stale artifact
        #       kept agreeing with a stale pin. See the note on its
        #       enrollment above.
        #   Recomputed, not bumped: every binary the count needs was built
        #   into `build/test-bin/` — the eight for the renamed and added
        #   sources plus every other binary older than its source — and each
        #   source's own `--list-json` was counted. That is also what empties
        #   the `missing-binary` bucket in `countSourceCounts` below. The
        #   static scan moves by the same +13 and is pinned separately.
        #
        #   The rebase onto `910cb956` brings a suite change that landed
        #   without moving these pins, so this commit carries both deltas and
        #   attributes each separately. `910cb956` is net zero on the spec
        #   count and -3 on the case count:
        #     - RETIRED tests/integration/
        #         t_workspace_branch_create_refuses_on_any_dirty_sibling.nim
        #       (-1 spec, -4 cases). Its subject — `repro branch <name>` in
        #       the create-without-switching form — no longer exists.
        #     + ADDED tests/integration/
        #         t_sync_clones_commit_pinned_repo.nim  (+1 spec, +2 cases)
        #     ~ tests/integration/
        #         t_workspace_branch_create_records_metadata.nim  3 -> 2
        #       trimmed to the one form still live.
        #     ~ t_gate_refusals_name_offender_and_remedy_command.nim and
        #       t_sync_clones_newly_declared_dependency_after_pull.nim were
        #       edited but their case counts are unchanged (9 and 1).
        #   1212 specs and 6847 cases -> 1212 specs and 6844 cases.
        #
        #   SPECS 1212 -> 1213, NIM CASES 6844 -> 6848
        #     tests/integration/
        #       t_protocol_document_survives_suite_body_echo.nim      (+4)
        #   One added source, and the whole delta on both numbers. It is the
        #   regression guard for "a stray `echo` in a suite body must not cost
        #   a binary its identity" — the consumer-side half of the corruptible
        #   protocol modes. Its four cases are
        #     the runner keeps every case of a binary that echoes on stdout
        #     --catalog FILE is immune to the same pollution
        #     --list has no frame and IS corrupted (upstream defect, pinned)
        #     the runner and the inventory recover the same document
        #   and it is pinned individually in `expected_enrollments` above.
        #   Recomputed, not bumped: read out of a live `build_inventory` with
        #   the binary rebuilt first, and re-derived again after the rebase
        #   with `910cb956`'s four changed binaries rebuilt too and the
        #   retired suite's stale binary deleted (`len(nim_specs)` 1213,
        #   `nim_total` 6848, `staticCaseCount` sum 6769,
        #   `testEntryCount` 1218). A count read
        #   from a stale binary agrees with a stale pin forever, which is how
        #   the +4 on `t_branch_forks_new_workspace_on_feature_branch.nim`
        #   above hid.
        #
        #   Its fixture, `tests/fixtures/protocol-echo/`, is under
        #   `tests/fixtures/`, which `generate_test_edges.nim` excludes, so it
        #   contributes nothing to any of these numbers — the regression test
        #   compiles it into a scratch directory at run time.
        #
        #   PYTHON unchanged (5 files, 46 cases). The 15 other sources this
        #   change edits — the failure-classifier removals and the VM-gate
        #   fixes — add and remove no case, so every number below moves by
        #   exactly the one new file's +1 / +4.
        #
        #   SPECS 1213 -> 1220, NIM CASES +7, STATIC NIM CASES +7
        #   `b2dabbc96` adds six one-case `repro develop` integration sources:
        #     t_develop_excludes_evidence_only_repos.nim
        #     t_develop_public_only_unchanged.nim
        #     t_develop_refuses_cross_backend_revision_conflict.nim
        #     t_develop_refuses_unreachable_team_backend.nim
        #     t_develop_set_is_union_of_all_backends.nim
        #     t_develop_warns_and_names_omitted_personal_repos.nim
        #   `6b342175e` adds the seventh one-case source:
        #     t_develop_ignores_sha_pinned_manifest_without_a_lock_record.nim
        #   Every one of the seven built binaries reports exactly one catalog
        #   case, and the independent static scan agrees. No Python source or
        #   case changed.
        #
        #   STATIC NIM CASES 6776 -> 6777, SPECS unchanged at 1220
        #   Upstream `7e503ddd2` adds one case to the already-enrolled
        #   `tests/integration/t_sync_clones_commit_pinned_repo.nim`:
        #     t_sync_clones_repo_pinned_to_a_fully_qualified_tag     (2 -> 3)
        #   Its exact mapping and three-case catalog are pinned above. No
        #   Python source or case changes in this step.
        #
        #   SPECS 1220 -> 1225, CATALOG/STATIC NIM CASES +5
        #   Upstream `391a892a4` adds the five one-case `repro develop`
        #   integration sources pinned individually above. Their freshly built
        #   binaries and the static scanner both report exactly one case each.
        #   The independently attributed static aggregate immediately before
        #   that upstream commit is therefore 6777, so 6777 + 5 = 6782.
        #   Python remains unchanged at five files and 46 cases.
        # Final reconciliation on 273e890f2: four already-present sources are
        # newly enrolled, the fail-closed gate is new (+5 specs), and upstream
        # 11cea6789 contributes the six pinned develop-selection specs above.
        # The e106faf6 runtime-loader edits add cases only, not specs.
        # This branch adds the linked-worktree regression pinned above: one
        # source with three independently cataloged and statically scanned
        # cases, moving 1236 -> 1237 specs.
        #
        # 1237 -> 1239. Regenerating the graph enrolls exactly two sources,
        # both pinned individually in `expected_enrollments` above:
        #   + tests/integration/
        #       t_develop_all_refuses_to_report_an_absent_checkout.nim   (1)
        #     the post-condition this change adds to `repro develop --all`.
        #   + tests/integration/t_branch_fork_clones_root_submodules.nim (1)
        #     ALREADY on disk and already passing, but absent from the
        #     checked-in generated graph — so it was never built and never run
        #     in CI. Regeneration recovers it. It is called out separately
        #     because it is not this change's subject: folding it into the
        #     "one new test" story would be exactly the unattributed aggregate
        #     adjustment these per-source pins exist to prevent.
        self.assertEqual(len(nim_specs), 1240)
        self.assertEqual(len(python_specs), 5)

        nim_total = sum(
            item["sourceCaseCount"]
            for item in data["tests"]
            if item["language"] == "nim"
        )
        python_total = sum(
            item["sourceCaseCount"]
            for item in data["tests"]
            if item["language"] == "python"
        )
        provider_only_sources = []
        for spec in nim_specs:
            source = (REPO_ROOT / spec.source).read_text(
                encoding="utf-8", errors="replace"
            )
            has_std_unittest = (
                re.search(
                    r"(?m)^[ \t]*import[ \t]+std[ \t]*/[ \t]*unittest\b",
                    source,
                )
                is not None
                or re.search(
                    r"(?ms)^[ \t]*import[ \t]+std[ \t]*/[ \t]*"
                    r"\[[^\]]*\bunittest\b[^\]]*\]",
                    source,
                )
                is not None
            )
            if (
                not has_std_unittest
                and inventory.count_nim_cases(source)["caseCount"] > 0
            ):
                provider_only_sources.append(spec.source)
        # This is intentionally independent from the token scanner. It pins
        # the sole current direct re-export provider so a future implicit
        # import/re-export cannot silently disappear from the inventory.
        self.assertEqual(
            provider_only_sources,
            [
                "libs/ct_test_unittest_parallel/tests/"
                "t_smoke_ct_test_unittest_parallel.nim"
            ],
        )
        # Language totals and the overall total. These are the aggregate
        # backstop for the per-source pins above, not a substitute for them.
        #
        # 6786 -> 6820 nim: reconciled line by line in the comment above
        # (static effect of the M2 step-2 edits, +9 for three new files,
        # +80 for the static-vs-catalog correction, -1 for dropping the
        # quarantined source's static fallback). Python keeps the static
        # `unittest` scan because Python files have no built binary.
        #
        # 6834 -> 6847: `0b9205f7`, reconciled beside the spec-count pin —
        # +5 and +4 for the two sources it added, +4 for the four cases it
        # added to `t_branch_forks_new_workspace_on_feature_branch.nim`, and
        # 0 for its six renames. All three are pinned per source in
        # `expected_enrollments` above.
        #
        # 6844 -> 6848: the four cases of
        # `t_protocol_document_survives_suite_body_echo.nim`, pinned per
        # source in `expected_enrollments` above.
        #
        # 6847/6848 -> 6854/6855: the seven one-case develop sources listed
        # beside the spec-count pin. `7e503ddd2` then adds the third catalog
        # case to `t_sync_clones_commit_pinned_repo.nim` on both hosts, giving
        # 6855/6856; its exact mapping is pinned above. `391a892a4` adds the
        # same five catalog cases on both hosts, giving 6860/6861. The exact
        # Linux-vs-Darwin delta remains +1 and is independently derived from
        # every platform-exclusive qualified case below.
        # e106faf6 adds three pinned runtime-loader cases; the four recovered
        # enrollments add 29; legacy-wire + fail-closed add two host-visible
        # cases; 11cea6789 adds six. Darwin/Linux therefore move 6860/6861 to
        # 6900/6901. The linked-worktree source adds the same three catalog
        # cases on both platforms, producing the final 6903/6904.
        #
        # 6903/6904 -> 6906/6907: the three M19b publication cases added to
        # `t_workspace_post_commit_lock_refresh_is_best_effort.nim`, pinned
        # per source in `expected_enrollments` above. Recomputed, not bumped:
        # read out of a live `build_inventory` with that binary REBUILT first
        # (a count read from a stale binary agrees with a stale pin forever).
        # `len(nim_specs)` and the catalog bucket below are unchanged — the
        # change enrols no new source, it grows an existing one. All three
        # cases are unconditional, so the Linux-vs-Darwin delta stays +1 and
        # `assert_linux_darwin_catalog_delta_is_exact` is untouched.
        #
        # 6906/6907 -> 6907/6908: the one discarded-checkout case added to
        # `t_sync_clones_commit_pinned_repo.nim`, pinned per source in
        # `expected_enrollments` above. It arrived without either aggregate
        # moving, which is what that recompute repaired. Recomputed, not
        # bumped: that binary was rebuilt first and the number read out of a
        # live `build_inventory` (`nim_total` 6908 on Linux, with 1237 specs,
        # no missing binary and nothing source-newer-than-binary). The case is
        # unconditional, so the Linux-vs-Darwin delta is still +1.
        #
        # 6907/6908 -> 6909/6910: the two RA-30 anchoring cases added to
        # `t_workspace_post_commit_lock_refresh_is_best_effort.nim`, pinned per
        # source in `expected_enrollments` above. Recomputed the same way —
        # read out of a live `build_inventory` after rebuilding that binary,
        # never bumped by the size of the diff. On the rebase onto the repaired
        # base the whole measurement was taken again rather than the +2 carried
        # arithmetically over a moved baseline. Both cases are unconditional
        # too, so the Linux-vs-Darwin delta is still +1.
        #
        # 6909/6910 -> 6911/6912: the two one-case sources the graph
        # regeneration enrols, pinned per source in `expected_enrollments`
        # above — the `develop --all` post-condition (+1) and the recovered
        # `t_branch_fork_clones_root_submodules.nim` (+1). Recomputed, not
        # bumped: both binaries were built and each reported one case through
        # its own `--list-json`; the static scan agrees on both. Both are
        # unconditional, so the Linux-vs-Darwin delta is still +1.
        #
        # 6911/6912 -> 6913/6914: the two RA-31 cases added to
        # `t_workspace_post_commit_lock_refresh_is_best_effort.nim`, pinned per
        # source in `expected_enrollments` above. Recomputed, not bumped: that
        # binary was rebuilt first and the number read out of a live
        # `build_inventory` (`nim_total` 6914 on Linux, with 1244 specs, no
        # missing binary and nothing source-newer-than-binary). The catalog sum
        # over the REBUILT BINARIES independently reads 6914 too. Both cases
        # are unconditional, so the Linux-vs-Darwin delta is still +1.
        #
        # 6913/6914 -> 6915/6916: NOT this branch's doing. `5688d28e` added two
        # cases to `libs/repro_project_dsl/tests/test_library_macro.nim`
        # (`exportedPath survives to the emitted LibraryDef` and `an unset
        # exportedPath stays empty`) without moving either aggregate — the same
        # shape of omission `f3319113` made. It was invisible until now because
        # `build/test-bin/test_library_macro` had not been rebuilt: the stale
        # binary reported 8 cases, the pin said 8's worth, and the two agreed
        # with each other forever. The static scan of the SOURCE read 10 the
        # whole time, which is exactly the disagreement the two-surface design
        # exists to expose. Recomputed after rebuilding that binary: its own
        # `--list-json` now reports 10 and the catalog sum reads 6916, matching
        # the static scan's +2. Both cases are unconditional, so the
        # Linux-vs-Darwin delta is still +1.
        #
        # 6915/6916 -> 6932/6933, SPECS 1239 -> 1240: the RA-32 suite,
        # `libs/repro_cli_support/tests/`
        # `t_lock_record_repo_component_is_one_path_segment.nim`, pinned per
        # source in `expected_enrollments` above. ONE purely additive
        # `repro_tests.nim` entry (regenerated with
        # `scripts/generate_test_edges.nim`, 1239 -> 1240 Nim tests) carrying
        # SEVENTEEN cases across TWO suites.
        #
        # Suite 1 (five) is the write/read path: component encoding at depth
        # four, publication of a slash-named repo, the refusal that names a
        # committed non-canonical record and its repair route, traversal +
        # reserved names, and encoder injectivity.
        #
        # Suite 2 (twelve) is refuse/report/repair: a stray that is NOT already
        # upstream not denying publication (the case the first version of this
        # suite avoided by pushing the stray first), an unresolvable twin not
        # denying publication, the publish moving and deleting nothing, the
        # append-only rule having NO exception (four commit shapes, two of them
        # the ones the withdrawn migration exception used to admit), the repair
        # verb planning without touching the store, refusing as a whole before
        # the first move, repairing into a chain that then publishes, refusing
        # an already-published record, every `locks/<project>/` reader using the
        # encoded component, and the two sibling backends' traversal. Two
        # more pin regressions found while reviewing this change: a refused
        # publish must not unstage the operator's own staged work (an empty
        # pathspec makes `git reset HEAD --` a FULL mixed reset), and the
        # repair must refuse a canonical PATH whose stem is not an object id
        # rather than rebuild a branch it knows would not publish.
        #
        # Recomputed, not bumped, on both surfaces independently: the freshly
        # built binary's own `--list-json` reports `"total":17,"suites":2`, and
        # the static scan of the SOURCE text (`count_nim_cases`) independently
        # reports `caseCount 17, suiteCount 2`. All seventeen cases are
        # unconditional, so the Linux-vs-Darwin delta is still +1.
        #
        # 6932/6933 -> 6933/6934: the one seed-distinctness case added to
        # `t_workspace_post_commit_lock_refresh_is_best_effort.nim`, pinned per
        # source in `expected_enrollments` above. It enrols no new source and
        # regenerates no `repro_tests.nim` entry, so `len(nim_specs)` and the
        # catalog bucket are unchanged; it grows an existing source by one.
        # Measured, not bumped, on both surfaces independently after rebuilding
        # that binary: its `--list-json` reports 13 cases in 2 suites and the
        # static scan of the source reports 13/2, so the delta is +1 on the
        # catalog aggregate and +1 on the static aggregate below. The case is
        # unconditional, so the Linux-vs-Darwin delta is still +1.
        #
        # A full-catalog read of `nim_total` was not available on the tree this
        # was measured on: 1143 of 1240 Nim specs had no built binary, so a
        # live `build_inventory` reports what the 81 built binaries enumerate
        # (154), not this total. The +1 is therefore attributed from the one
        # binary that WAS rebuilt for it, with the source's independent static
        # scan agreeing — the two-surface rule this file is built on — rather
        # than read off an aggregate the tree could not produce.
        expected_nim_total = 6933 if sys.platform == "darwin" else 6934
        self.assertEqual(nim_total, expected_nim_total)
        # Independently: the total is the sum of what the BINARIES report,
        # with nothing imputed for a binary that could not report. Stated
        # as its own equality so a future re-introduction of the static
        # fallback fails here even if someone also bumps the pin above.
        self.assertEqual(
            nim_total,
            sum(
                len(item.get("catalogCases", []))
                for item in data["tests"]
                if item["language"] == "nim"
                and item["countSource"] == "catalog"
            ),
        )
        # 31 -> 35: this file is itself one of the four enumerated Python
        # test files, and the catalog rework added four test methods to it:
        #   test_catalog_counts_match_each_binary_list_surface
        #   test_catalog_quarantine_is_pinned_by_size_and_membership
        #   test_static_fallback_is_labelled_when_a_binary_is_absent
        #   test_tracked_artifact_is_path_stable_and_carries_no_body_hashes
        #
        # 35 -> 41: the probe-gate and artifact-stability fixes add six
        # more (one of the four above was renamed, not added):
        #   test_catalog_index_memo_is_keyed_by_the_spec_set
        #   test_only_successful_probes_are_ever_cached
        #   test_environmental_probe_failure_aborts_instead_of_quarantining
        #   test_probe_never_runs_a_test_binary_inside_the_repository
        #   test_no_cache_flag_exists_and_reaches_the_catalog_index
        #   test_absolute_paths_are_redacted_to_their_basename
        # (`test_static_fallback_is_labelled_when_a_binary_is_absent` became
        #  `test_missing_binary_is_its_own_label_not_plain_static`.)
        #
        # 41 -> 42: holding the TRACKED MARKDOWN to the same stability rule
        # as the tracked JSON adds one more:
        #   test_tracked_markdown_report_is_stable_across_hosts_and_builds
        #
        # 43 -> 46: `tests/unit/test_package_root_anchor.py` adds three:
        #   test_fixtures_are_byte_identical_and_share_a_basename
        #   test_repository_declares_a_package_root_anchor_deliberately
        #   test_same_named_sources_in_different_directories_stay_distinct
        #
        # Python files have no built binary, so this number still comes from
        # the static `unittest` scan.
        #
        # 46 -> 47: `test_a_source_with_no_built_binary_contributes_nothing`
        # in this file — the rule-level guard for the `missing-binary` change.
        # Read out of a live `build_inventory` (`python_total` 47), not bumped.
        # 47 -> 50: the three cases pinning the stale-binary rule — that a
        # binary older than its source contributes nothing, that the detection
        # names both timestamps, and that summing an absent field raises
        # instead of returning zero. Read out of a live `build_inventory`
        # (`python_total` 50), not bumped.
        self.assertEqual(python_total, 50)
        # 6856 -> 6862: -1 from the quarantined source no longer imputing a
        # static count, +7 from the new Python cases above.
        #
        # 6877 -> 6893 = 6847 nim + 46 python, and the two contributions are
        # kept apart deliberately because they come from different changes:
        #   +13 nim    `0b9205f7`: +5 and +4 for the two sources it added,
        #              +4 for the cases it added to an existing source; its
        #              six renames net to zero.
        #   +3 python  the package-root-anchor guard
        #              `tests/unit/test_package_root_anchor.py`.
        # Both halves are pinned separately above (`nim_total`,
        # `python_total`), so this aggregate is a backstop for them rather
        # than a place either delta can hide.
        #
        # The aggregate is `expected_nim_total` + 46 Python.
        # ``assert_linux_darwin_catalog_delta_is_exact`` pins every qualified
        # identity on both sides of that exact delta.
        #
        # The publication-reporting change moved it 6949/6950 -> 6952/6953 =
        # 6906/6907 nim + 46 python. All +3 was nim; the python half was
        # untouched, which is why the aggregate is stated relative to
        # `expected_nim_total` rather than as an independent literal that could
        # drift away from it.
        #
        # The discarded-checkout recompute moved it again, 6952/6953 ->
        # 6953/6954 = 6907/6908 nim + 46 python, and it moved without this line
        # being touched — which is the point of keeping it symbolic.
        #
        # The anchoring change moved it to 6955/6956 = 6909/6910 nim + 46
        # python. All +2 was nim (the two RA-30 anchoring cases); the python
        # half was untouched again, and this line still did not have to move
        # for it.
        #
        # The sibling-repos change moved it to 6957/6958 = 6911/6912 nim + 46
        # python — the two one-case sources the graph regeneration enrolled.
        #
        # The RA-31 recompute moved it again, 6957/6958 -> 6959/6960 =
        # 6913/6914 nim + 46 python, and it moved without this line being
        # touched — which is the point of keeping it symbolic.
        #
        # This change is the first in a while to move the PYTHON half instead:
        # 6962 -> 6963 = 6915/6916 nim + 47 python, the one new Python guard
        # for the `missing-binary` rule. The Nim half is untouched — the
        # `missing-binary` bucket is empty on a complete build, so making it
        # contribute zero changes no number on a tree that is fully built. That
        # is the point: the change is invisible until the build is incomplete,
        # which is exactly when the old behaviour was lying. The `+ 47` literal
        # is the python half only; the nim half stays symbolic so the two pins
        # cannot drift apart. Measured on the merged base rather than carried
        # arithmetically over it: `data["static"]["sourceCaseCount"]` on Linux
        # is 6963. (The nim half of that total moved under this branch while it
        # was open — see the `expected_nim_total` note — which is why it was
        # measured on the merged base instead of carried across.)
        #
        # The stale-binary rule moves the python half again, 47 -> 50, so the
        # aggregate measures 6966 = 6916 nim + 50 python on Linux. The NIM half
        # is deliberately untouched: a staleness check must not change any
        # count on a tree where nothing is stale, and this one does not. It DID
        # change them on the tree it was written on — three binaries were
        # behind their sources and `nim_total` came back 6884 until they were
        # rebuilt. That is the check working, not the pins moving.
        self.assertEqual(
            data["static"]["sourceCaseCount"], expected_nim_total + 50
        )
        self.assertEqual(
            data["static"]["sourceCaseCount"], nim_total + python_total
        )
        # The static scan is retained per entry and pinned in aggregate too,
        # so a change in the SCANNER can still be told apart from a change
        # in the SUITE: if this number moves while `nim_total` holds, the
        # lexer regressed, not the tests.
        #
        # 6755 -> 6768 = +13, the same +13 `nim_total` moved by and split the
        # same way (+5, +4, +4, and 0 for the six renames). The scan reads the
        # SOURCES, `nim_total` reads the BINARIES, and they were derived
        # independently, so their agreeing on the decomposition is the check
        # that the `0b9205f7` recomputation above is a fact about the suite
        # rather than about one of the two surfaces.
        #
        # 6765 -> 6769 = +4, the same +4 `nim_total` moved by, and the whole
        # of it is the one new source. The scan reads the SOURCES and
        # `nim_total` reads the BINARIES, so their agreeing that the new file
        # holds four cases is what makes that a fact about the suite rather
        # than about one surface.
        #
        # 6769 -> 6776 = +7: each added develop source contains one statically
        # visible case, independently matching its binary's one-case catalog.
        # The rebased upstream tree before `391a892a4` independently scans to
        # 6777; its five new one-case sources then produce 6782. The recovered
        # enrollments add 29, e106faf6 adds 3, the migration adds 3 static
        # declarations (two conditional cache cases plus fail-closed), and
        # 11cea6789 adds six: 6823. The linked-worktree source's independent
        # static scan adds the same three cases, giving 6826.
        #
        # 6826 -> 6829 = +3, the same +3 `nim_total` moved by, and the whole of
        # it is the one grown source. The scan reads the SOURCES and `nim_total`
        # reads the BINARIES, so their agreeing that the file now holds eight
        # cases is what makes that a fact about the suite rather than about one
        # surface.
        #
        # 6829 -> 6830 = +1, the same +1 `nim_total` moved by, and the whole of
        # it is the discarded-checkout case in
        # `t_sync_clones_commit_pinned_repo.nim`. This scan reads the SOURCE
        # text and `nim_total` reads the REBUILT BINARY; they were derived
        # independently and both moved by exactly one, which is what makes
        # "one new case" a fact about the suite rather than about one surface.
        #
        # 6830 -> 6832 = +2, the same +2 `nim_total` moved by, and the whole of
        # it is the one grown source. Source scan and binary catalog agreeing
        # on the same +2 is what makes "two new cases" a fact about the suite
        # rather than about one surface.
        #
        # 6832 -> 6834 = +2, the same +2 `nim_total` moved by: one statically
        # visible case in each of the two newly enrolled sources, each
        # independently matching its binary's one-case catalog.
        #
        # 6834 -> 6836 = +2, the same +2 `nim_total` moved by, and the whole of
        # it is the two RA-31 cases in
        # `t_workspace_post_commit_lock_refresh_is_best_effort.nim`. This scan
        # reads the SOURCE text and `nim_total` reads the REBUILT BINARY; they
        # were derived independently and both moved by exactly two, which is
        # what makes "two new cases" a fact about the suite rather than about
        # either surface.
        #
        # 6836 -> 6838 = +2, the two `test_library_macro.nim` cases `5688d28e`
        # enrolled without pinning. This scan read 6838 from the SOURCE before
        # that binary was rebuilt, while the catalog still read 6836 from the
        # stale binary — the number moving here while `nim_total` held is
        # precisely the signal this pin is documented to give. Rebuilding
        # reconciled them at 6838/6916.
        #
        # 6838 -> 6839 = +1, the same +1 `nim_total` moved by, and the whole of
        # it is the seed-distinctness case in
        # `t_workspace_post_commit_lock_refresh_is_best_effort.nim`. Measured
        # by scanning the source before and after the change: 6857 and 6858.
        #
        # Which is this pin's own signal, fired at us: this scan reads 6857 on
        # an UNTOUCHED `dev`, nineteen above the 6838 pinned here, so nineteen
        # statically visible cases reached the tree without moving it. Those
        # nineteen are not this change's and are deliberately NOT absorbed —
        # bumping this number to whatever the tree currently sums to is exactly
        # the aggregate laundering the per-source pins above exist to prevent.
        # This line moves by the one case that is attributable here and no
        # more, so the residual drift stays visible and attributable to
        # whichever changes owe it.
        self.assertEqual(
            sum(
                item["staticCaseCount"]
                for item in data["tests"]
                if item["language"] == "nim"
            ),
            6839,
        )

    def assert_runtime_compiler_flow_inventory(self, data):
        flows = data["staticallyDetectedRuntimeCompilerFlows"]
        by_source = {item["source"]: item for item in flows}
        explicit_sources = {
            item["source"]
            for item in flows
            if any(
                not pattern.startswith("repro-")
                for match in item["matches"]
                for pattern in match["patterns"]
            )
        }
        api_sources = {
            item["source"]
            for item in flows
            if any(
                pattern.startswith("repro-")
                for match in item["matches"]
                for pattern in match["patterns"]
            )
        }

        # These eleven enrolled provider tests were invisible to the old
        # command-string detector. Each imports and invokes the authoritative
        # repro_interface_artifacts API through a direct or reachable wrapper.
        provider_additions = {
            "tests/e2e/dev-env/t_e2e_provider_dev_env_implicit_floor.nim",
            "tests/e2e/dev-env/t_e2e_provider_dev_env_introspection.nim",
            "tests/integration/t_compiler_scratch_isolation.nim",
            "tests/integration/t_dev_env_artifact.nim",
            "tests/integration/t_rp1_provider_compile_edge_materializes.nim",
            "tests/integration/t_rp2_provider_session_invoke.nim",
            "tests/integration/t_rp3_bind_deps_and_sharing.nim",
            "tests/integration/t_rp5b_resource_driver_via_protocol.nim",
            "tests/integration/t_run_consumes_opaque_out_of_tree.nim",
            "tests/integration/t_run_consumes_session_store_out_of_tree.nim",
            "tests/integration/t_run_edge_session_resolver_auto.nim",
        }
        profile_additions = {
            "libs/repro_profile_compile/tests/t_smoke_module_imports.nim",
            "libs/repro_profile_compile/tests/t_smoke_repro_profile_compile.nim",
            "libs/repro_profile_compile/tests/"
            "t_template_in_template_named_args.nim",
            "tests/e2e/m83/t_e2e_profile_modules.nim",
            "tests/e2e/m83/t_e2e_repro_profile_compile_via_action.nim",
        }
        equivalent_api_additions = {
            "tests/e2e/m76/"
            "t_integration_stow_byte_identical_target_is_cache_hit.nim",
            "tests/integration/t_ti1_interface_artifact_edge.nim",
        }
        expected_additions = (
            provider_additions | profile_additions | equivalent_api_additions
        )
        self.assertEqual(api_sources - explicit_sources, expected_additions)

        for source in provider_additions:
            with self.subTest(provider_runtime_compiler_source=source):
                patterns = {
                    pattern
                    for match in by_source[source]["matches"]
                    for pattern in match["patterns"]
                }
                self.assertTrue(
                    patterns
                    & {
                        "repro-compile-provider-binary",
                        "repro-extract-interface",
                    }
                )
        for source in profile_additions:
            with self.subTest(profile_runtime_compiler_source=source):
                patterns = {
                    pattern
                    for match in by_source[source]["matches"]
                    for pattern in match["patterns"]
                }
                self.assertTrue(
                    patterns
                    & {
                        "repro-compile-profile-binary",
                        "repro-compile-profile-edge",
                    }
                )
        self.assertIn(
            "repro-compile-home-profile",
            {
                pattern
                for match in by_source[
                    "tests/e2e/m76/"
                    "t_integration_stow_byte_identical_target_is_cache_hit.nim"
                ]["matches"]
                for pattern in match["patterns"]
            },
        )
        self.assertIn(
            "repro-lift-interface-artifact",
            {
                pattern
                for match in by_source[
                    "tests/integration/t_ti1_interface_artifact_edge.nim"
                ]["matches"]
                for pattern in match["patterns"]
            },
        )

        # The opaque-resource regression is pinned independently because it
        # landed after the original M0 report and exercises the same provider
        # materialization chain with a new resource representation.
        opaque = by_source[
            "tests/integration/t_run_consumes_opaque_out_of_tree.nim"
        ]
        self.assertTrue(opaque["matches"])
        self.assertEqual(opaque["class"], "integration")

        # Similar spellings in prose or fixture text are not runtime calls.
        self.assertNotIn(
            "tests/integration/"
            "t_rp5a_producer_exports_resource_contract_across_workspace.nim",
            api_sources,
        )
        self.assertNotIn(
            "tests/integration/"
            "t_sc_producer_exports_typed_cli_contract_across_workspace.nim",
            api_sources,
        )
        self.assertNotIn(
            "tests/e2e/m83/t_e2e_phase_g_action_edges.nim",
            api_sources,
        )

        # Derive the aggregate from independently pinned detector partitions.
        # Three tests have both an explicit compiler command and an API flow,
        # so adding 48 + 21 directly would double count them.
        cleanup_source = (
            "tests/integration/"
            "t_repro_test_runner_process_group_cleanup.nim"
        )
        self.assertIn(cleanup_source, explicit_sources)
        # 48 -> 50. Unrelated to the catalog rework (which does not touch
        # compiler-flow detection at all): M2 step 2 adds two new test
        # sources that each drive a real compiler, and both are new files
        # rather than changes to an already-counted source. Recomputed
        # against the HEAD content of every changed file: the HEAD-state
        # explicit set is exactly 48, the working-tree set is exactly 50,
        # the difference is exactly these two, and nothing left the set.
        #
        # 50 -> 51: the runner reporting-contract test compiles its own
        # fixtures with a real `nim c`, exactly as the two sources above
        # do. One new file, no already-counted source changed, and the
        # explicit/api intersection below is untouched.
        #
        # 51 -> 52: the M2 step-1 catalog-selection test, by the same
        # argument again — it compiles its own fixtures with a real
        # `nim c` (twice, to produce the edited rebuild). One new file, no
        # already-counted source changed, intersection untouched.
        #
        # 52 -> 53: the suite-body-echo protocol regression test, by the
        # same argument once more — it compiles its `tests/fixtures/
        # protocol-echo/` fixture with a real `nim c`, and rebuilds
        # `repro_test_runner` when that binary is older than its source.
        # One new file, no already-counted source changed, intersection
        # untouched. Recomputed from a live `build_inventory`, not bumped.
        for added in (
            "tests/integration/"
            "t_repro_test_runner_consumes_result_document.nim",
            "tests/integration/"
            "t_repro_test_runner_suiteless_case_round_trip.nim",
            "tests/integration/"
            "t_repro_test_runner_reporting_contract.nim",
            "tests/integration/"
            "t_repro_test_runner_catalog_selection.nim",
            "tests/integration/"
            "t_protocol_document_survives_suite_body_echo.nim",
        ):
            with self.subTest(added_explicit_source=added):
                self.assertIn(added, explicit_sources)
        self.assertEqual(len(explicit_sources), 53)
        self.assertEqual(len(api_sources), 21)
        self.assertEqual(
            explicit_sources & api_sources,
            {
                "tests/integration/"
                "t_extension_type_lifted_and_consumed.nim",
                "tests/integration/"
                "t_project_interface_artifact_import_modes.nim",
                "tests/integration/t_ti3_fingerprint_split.nim",
            },
        )
        derived_total = len(explicit_sources | api_sources)
        # 66 -> 68: the same two new M2 step-2 sources. The three-source
        # explicit/api intersection pinned above is unchanged, so the union
        # moves by exactly the two added explicit sources. 68 -> 69 for
        # the reporting-contract source, by the same argument, and
        # 69 -> 70 for the catalog-selection source, likewise. 70 -> 71
        # for the suite-body-echo protocol regression test, likewise again:
        # it is an explicit-compiler source, it is not in the intersection
        # pinned above, so the union moves by exactly one.
        self.assertEqual(derived_total, 71)
        self.assertEqual(len(flows), derived_total)
        self.assertFalse(data["runtimeCompilerFlowDetection"]["exhaustive"])
        self.assertEqual(
            data["performanceAssessment"]["observedStructuralFacts"][
                "staticallyDetectedRuntimeCompilerFlowTests"
            ],
            derived_total,
        )

    def test_warm_monitor_shim_probe_is_portable_and_requires_an_artifact(self):
        probe = REPO_ROOT / "scripts" / "monitor_shim_probe.sh"
        probe_source = probe.read_text(encoding="utf-8")
        self.assertNotIn("compgen", probe_source)
        runner_source = (REPO_ROOT / "scripts" / "run_tests.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("source scripts/monitor_shim_probe.sh", runner_source)
        self.assertIn(
            'repro_monitor_shim_available "build/lib"', runner_source
        )
        self.assertNotIn("compgen", runner_source)

        bash = subprocess.check_output(
            ["bash", "-c", "command -v bash"], text=True
        ).strip()
        with tempfile.TemporaryDirectory(prefix="repro-m0-shim-probe-") as tmp:
            lib_dir = Path(tmp) / "lib"
            lib_dir.mkdir()
            env = os.environ.copy()
            env["PATH"] = ""

            missing = subprocess.run(
                [bash, str(probe), str(lib_dir)], env=env, check=False
            )
            self.assertNotEqual(missing.returncode, 0)

            # A matching directory is not a reusable library artifact.
            (lib_dir / "librepro_monitor_shim.fake-dir").mkdir()
            directory_only = subprocess.run(
                [bash, str(probe), str(lib_dir)], env=env, check=False
            )
            self.assertNotEqual(directory_only.returncode, 0)

            shim = lib_dir / "librepro_monitor_shim.so"
            shim.write_bytes(b"fixture")
            reusable = subprocess.run(
                [bash, str(probe), str(lib_dir)], env=env, check=False
            )
            self.assertEqual(reusable.returncode, 0)

    def test_default_test_build_parallelism_scales_with_host_capacity(self):
        helper = REPO_ROOT / "scripts" / "test_parallelism.sh"
        bash = subprocess.check_output(
            ["bash", "-c", "command -v bash"], text=True
        ).strip()
        # The table is the whole of what makes each cap deliberate, so it is
        # re-derived when the helper's shape changes rather than relaxed into
        # an inequality. Raising the ceiling to 16 at 32 cores moves exactly
        # the two rows at or above that size; every row below 32 is unchanged,
        # which is the check that the new ceiling left the small-host
        # behaviour — and the cores/2 fraction under it — alone.
        cases = {
            "invalid": 1,
            "0": 1,
            "1": 1,
            "2": 1,
            "7": 3,
            "8": 4,
            "23": 4,
            "24": 8,
            # cores/2 is 16 at 32 and 32 at 64; the 16 ceiling binds at both.
            "32": 16,
            "64": 16,
        }
        for cores, expected in cases.items():
            with self.subTest(cores=cores):
                output = subprocess.check_output(
                    [
                        bash,
                        "-c",
                        'source "$1"; reprobuild_default_test_build_parallelism "$2"',
                        "parallelism-test",
                        str(helper),
                        cores,
                    ],
                    text=True,
                )
                self.assertEqual(int(output.strip()), expected)

    # -----------------------------------------------------------------
    # Catalog enumeration gates
    # -----------------------------------------------------------------
    #
    # `sourceCaseCount` is now taken from each built binary's `--list-json`
    # catalog, so the inventory's number has to be checked against the
    # binary itself and not merely against a previous copy of the same
    # number. `--list` is a different code path in the same binary from
    # `--list-json`, which makes it a genuine cross-check rather than a
    # restatement.
    #
    # Cost note: a cold cross-check runs every test binary once (a handful
    # of `recipes/packages/source/*` binaries do heavy module-init work
    # before argv parsing; one takes almost four minutes on its own), so
    # results are cached under build/ keyed by each binary's size and
    # mtime. A rebuild re-probes exactly the binaries that changed.

    LIST_CROSSCHECK_CACHE = Path("build/reprobuild-suite-list-crosscheck.json")
    LIST_CROSSCHECK_VERSION = 1

    _INVENTORY = None

    @classmethod
    def inventory_data(cls):
        """One `build_inventory` result shared by every test in this class.

        `build_inventory` walks the whole source tree for the fingerprint,
        runs `du` over build/, and probes every test binary. Four tests need
        it, and it is a pure function of the tree, so building it once keeps
        the suite honest without paying that cost four times.
        """
        if cls._INVENTORY is None:
            cls._INVENTORY = inventory.build_inventory(REPO_ROOT, None)
        return cls._INVENTORY

    @classmethod
    def _list_names(cls, binary_path, env, cwd, timeout=None):
        """Case names as reported by the binary's `--list` surface.

        `cwd` is a scratch directory, never the repo root: this helper runs
        every test binary in the tree, and `source_fingerprint` hashes
        untracked files, so a binary that drops a stray file into its
        working directory would otherwise change the fingerprint the same
        run is recording. Same reason as `catalog_index`'s probe.

        The timeout defaults to the probe's own bound so the two surfaces
        cannot disagree merely because one of them was given less time on a
        loaded host.
        """
        if timeout is None:
            timeout = inventory.CATALOG_PROBE_TIMEOUT_SECONDS
        try:
            completed = subprocess.run(
                [str(binary_path), "--list"],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=timeout,
                cwd=str(cwd),
                env=env,
            )
        except (subprocess.TimeoutExpired, OSError):
            return None
        if completed.returncode != 0:
            return None
        return [line for line in completed.stdout.splitlines() if line.strip()]

    def test_catalog_counts_match_each_binary_list_surface(self):
        """Every catalog-counted source equals its binary's own `--list`.

        This is the assertion that makes the catalog rework load-bearing: if
        a binary's registered case set drifts from what the inventory
        records, or a binary silently stops answering the protocol, the
        inventory can no longer quietly keep a stale number.
        """
        data = self.inventory_data()
        catalog_entries = [
            item
            for item in data["tests"]
            if item.get("countSource") == "catalog"
        ]
        self.assertGreater(len(catalog_entries), 1000)

        env = inventory.catalog_probe_env()
        cache_path = REPO_ROOT / self.LIST_CROSSCHECK_CACHE
        try:
            payload = json.loads(cache_path.read_text(encoding="utf-8"))
            cached = (
                payload.get("entries", {})
                if payload.get("version") == self.LIST_CROSSCHECK_VERSION
                else {}
            )
        except (OSError, ValueError):
            cached = {}

        pending = []
        resolved = {}
        for item in catalog_entries:
            binary_path = REPO_ROOT / item["binary"]
            key = inventory.binary_cache_key(binary_path)
            self.assertIsNotNone(
                key, f"catalog-counted binary is missing: {item['binary']}"
            )
            entry = cached.get(item["source"])
            # Only a POSITIVE entry may be reused. A cached `None` is a
            # cached failure, and a failure recorded on a loaded host is
            # not a fact about the binary — the same rule `catalog_index`
            # applies to its own cache.
            if (
                isinstance(entry, dict)
                and entry.get("key") == key
                and entry.get("names") is not None
            ):
                resolved[item["source"]] = entry.get("names")
            else:
                pending.append((item["source"], binary_path, key))

        if pending:
            from concurrent.futures import ThreadPoolExecutor

            scratch = tempfile.TemporaryDirectory(prefix="repro-list-check-")
            self.addCleanup(scratch.cleanup)

            def run_one(job):
                source, binary_path, key = job
                return source, key, self._list_names(
                    binary_path, env, scratch.name
                )

            with ThreadPoolExecutor(max_workers=16) as pool:
                for source, key, names in pool.map(run_one, pending):
                    resolved[source] = names
                    if names is None:
                        # Never persist a negative result.
                        cached.pop(source, None)
                    else:
                        cached[source] = {"key": key, "names": names}
            try:
                cache_path.parent.mkdir(parents=True, exist_ok=True)
                cache_path.write_text(
                    json.dumps(
                        {
                            "version": self.LIST_CROSSCHECK_VERSION,
                            "entries": cached,
                        },
                        sort_keys=True,
                    ),
                    encoding="utf-8",
                )
            except OSError:
                pass

        mismatches = []
        for item in catalog_entries:
            names = resolved.get(item["source"])
            if names is None:
                mismatches.append(
                    f"{item['source']}: --list did not produce a case list, "
                    "but the inventory counted it from the catalog"
                )
                continue
            catalog_names = [case["name"] for case in item["catalogCases"]]
            if catalog_names != names:
                mismatches.append(
                    f"{item['source']}: catalog {len(catalog_names)} cases != "
                    f"--list {len(names)} cases"
                )
            elif item["sourceCaseCount"] != len(names):
                mismatches.append(
                    f"{item['source']}: sourceCaseCount "
                    f"{item['sourceCaseCount']} != --list {len(names)}"
                )
        self.assertEqual(mismatches, [], "\n".join(mismatches[:40]))

        # Spot pins for the three sources that motivated this rework. Each
        # is a case the static scanner got wrong in a different way, so a
        # regression to static counting fails here explicitly rather than
        # only in the aggregate.
        by_source = {item["source"]: item for item in data["tests"]}
        for source, expected in (
            # wrapper template: static scanner counted 0
            ("tests/e2e/m69/t_e2e_windows_vs_installer.nim", 16),
            # wrapper template: static scanner counted 0
            ("tests/e2e/m69/t_e2e_repro_infra_plan_apply_convergent.nim", 7),
            # summed when/else branches: static scanner counted 8
            (
                "tests/e2e/m76/"
                "t_integration_stow_byte_identical_target_is_cache_hit.nim",
                4,
            ),
        ):
            with self.subTest(source=source):
                self.assertEqual(by_source[source]["countSource"], "catalog")
                self.assertEqual(by_source[source]["sourceCaseCount"], expected)
                self.assertEqual(len(resolved[source]), expected)

    def test_catalog_quarantine_is_pinned_by_size_and_membership(self):
        """The quarantine list is exhaustive, enumerated and pinned.

        A binary that silently loses protocol support must fail this test
        rather than quietly fall back to a static count. Membership is
        pinned, not just the size, so one binary dropping out and another
        dropping in cannot cancel out.
        """
        data = self.inventory_data()
        catalog = data["catalogEnumeration"]

        # Exactly one binary in the tree cannot enumerate. Everything in
        # `libs/repro_peer_cache/tests/t_n7_multicast_windows_smoke.nim` is
        # inside `when defined(windows)` with `else: discard`, so on Linux
        # the binary registers no cases at all and never links the protocol
        # — it emits nothing for `--list-json`.
        #
        # It is labelled `quarantined` and contributes 0 cases. The static
        # scanner says 1 for this file (it counts the `when`-branch
        # declaration it cannot evaluate), and that 1 used to be added to
        # the authoritative total — making the pinned Nim total 6821 while
        # the binaries actually register 6820. The one place the static
        # fallback was still used was the exact over-count this rework
        # exists to eliminate. `staticCaseCount` keeps the number visible;
        # it no longer votes.
        expected_quarantine = {
            "libs/repro_peer_cache/tests/"
            "t_n7_multicast_windows_smoke.nim": "no-protocol-support",
        }
        actual_quarantine = {
            item["source"]: item["reason"] for item in catalog["quarantine"]
        }
        self.assertEqual(actual_quarantine, expected_quarantine)
        self.assertEqual(catalog["quarantineCount"], len(expected_quarantine))
        self.assertEqual(
            catalog["quarantineReasonCounts"], {"no-protocol-support": 1}
        )

        # Every quarantine entry carries a machine-readable reason drawn
        # from the declared taxonomy, and every quarantined reason must be
        # INTRINSIC: an environmental failure aborts the run rather than
        # joining this set, so its presence here would be a defect in
        # `catalog_index`, not a fact about the tree.
        for item in catalog["quarantine"]:
            with self.subTest(quarantined=item["source"]):
                self.assertIn(
                    item["reason"],
                    inventory.QUARANTINE_REASON_DESCRIPTIONS,
                )
                self.assertIn(
                    item["reason"], inventory.INTRINSIC_QUARANTINE_REASONS
                )
                self.assertNotIn(
                    item["reason"],
                    inventory.ENVIRONMENTAL_QUARANTINE_REASONS,
                )
                self.assertTrue(item["reasonDescription"])
                self.assertIsInstance(item["staticCaseCount"], int)
                entry = next(
                    test
                    for test in data["tests"]
                    if test["source"] == item["source"]
                )
                self.assertEqual(entry["countSource"], "quarantined")
                # The authoritative count is 0, NOT the static fallback.
                self.assertEqual(entry["sourceCaseCount"], 0)
                self.assertEqual(
                    entry["staticCaseCount"], item["staticCaseCount"]
                )
        # The one quarantined source is the phantom `when`-branch file, and
        # its static count really is the non-zero one that used to leak
        # into the total. Pinned explicitly so "0 cases contributed" cannot
        # be satisfied by the static scan quietly also becoming 0.
        self.assertEqual(catalog["quarantine"][0]["staticCaseCount"], 1)
        self.assertTrue(catalog["quarantinedCasesExcludedFromTotal"])
        # Published beside it: a source whose binary was never built imputes
        # nothing either, so the total reads BUILT BINARIES ONLY. Asserted on
        # the artifact rather than only in `authoritative_case_count`'s unit
        # test, because the artifact is what a reader who never opens this
        # repository actually sees.
        self.assertTrue(catalog["missingBinaryCasesExcludedFromTotal"])

        # The taxonomy partitions every declared reason. A reason belonging
        # to neither set (or both) would silently pick up whichever default
        # the code happened to apply.
        declared = set(inventory.QUARANTINE_REASON_DESCRIPTIONS)
        intrinsic = set(inventory.INTRINSIC_QUARANTINE_REASONS)
        environmental = set(inventory.ENVIRONMENTAL_QUARANTINE_REASONS)
        self.assertEqual(intrinsic | environmental, declared)
        self.assertEqual(intrinsic & environmental, set())
        # `timeout` is the reason that motivated the split: it is a fact
        # about how busy the host was, never about the test.
        self.assertIn("timeout", environmental)
        self.assertIn("dynamic-link-failure", environmental)
        self.assertIn("no-protocol-support", intrinsic)

        # A dynamic-link failure is an environment defect, not a coverage
        # fact. Probed correctly (inside the nix dev shell) there are none;
        # if this ever trips, the inventory was generated without the
        # dev-shell runtime library path and its counts are not evidence.
        self.assertEqual(catalog["dynamicLinkFailureCount"], 0)
        self.assertFalse(catalog["environmentDegraded"])

        # Count-provenance census. Every Nim entry is catalog-counted except
        # the single quarantined one; the five `static` entries are the
        # Python files, which have no built binary. `missing-binary` is a
        # distinct label from `static` and is absent here because every Nim
        # source in the tree currently has a built binary — if a build gap
        # appeared it would show up as its own bucket instead of hiding
        # among the Python files.
        #
        # 1208 -> 1209 catalog: the M2 step-1 catalog-selection regression
        # `tests/integration/t_repro_test_runner_catalog_selection.nim`.
        # Its binary was built and probed, so it joins the `catalog`
        # bucket rather than `missing-binary`; recomputed from a live
        # `build_inventory`, not bumped.
        #
        # 4 -> 5 static: `tests/unit/test_package_root_anchor.py`, the
        # package-root-anchor guard. The `static` bucket is exactly the
        # Python file set, so that key is attributable to it on its own.
        #
        # 1209 -> 1211 catalog: the six sources `0b9205f7` renamed and the
        # two it added. Before this change the six renamed sources and the
        # two new ones had no binary under their current names, so a live
        # probe reported `{"catalog": 1203, "missing-binary": 8,
        # "quarantined": 1, "static": 5}` — the `missing-binary` bucket the
        # `assertNotIn` below exists to forbid, showing up because the
        # binaries were never rebuilt after the rename rather than because
        # anything was wrong with the sources. All eight are built now, the
        # six stale binaries under the pre-rename names are gone, and the
        # bucket is empty again: 1211 = 1212 Nim specs - 1 quarantined.
        #
        # 1211 -> 1212 catalog: the one source this change adds,
        # `t_protocol_document_survives_suite_body_echo.nim`. Its binary is
        # built and probed, so it joins the `catalog` bucket and the
        # `missing-binary` bucket stays empty:
        # 1212 = 1213 Nim specs - 1 quarantined.
        #
        # 1212 -> 1219 catalog: `b2dabbc96` and `6b342175e` add the seven
        # one-case develop sources enumerated by the aggregate-count assertion.
        # All seven binaries speak the protocol and were probed successfully.
        # The one source outside this bucket remains the pre-existing
        # Windows-only multicast smoke test above, so 1219 = 1220 Nim specs -
        # 1 quarantined; none of the seven additions is outside the catalog.
        # 1219 -> 1224 catalog: upstream `391a892a4` adds the five one-case
        # sources pinned above. The sole quarantine and five Python-static
        # entries are unchanged, so 1224 = 1225 Nim specs - 1 quarantined.
        # Four recovered enrollments plus fail-closed bring that bucket to
        # 1229; upstream 11cea6789 adds six more. The sole quarantine and five
        # Python-static entries remain. The linked-worktree regression is a
        # normal built catalog entry, moving the catalog bucket 1235 -> 1236.
        self.assertEqual(
            catalog["countSourceCounts"],
            # 1236 -> 1238: the two sources the graph regeneration enrols. Both
            # binaries are built and probed, so both join the `catalog` bucket
            # and `missing-binary` stays empty: 1238 = 1239 Nim specs - 1
            # quarantined.
            {"catalog": 1238, "quarantined": 1, "static": 5},
        )
        self.assertNotIn("missing-binary", catalog["countSourceCounts"])
        # ...and no source outran its binary, which is now a statement that
        # CAN be false. While no such field existed, a reader summing it got
        # 0 from a healthy tree and 0 from a document that had never heard of
        # the property. `sum_field` raises on the second case; the field being
        # emitted for every spec, in every language, is the other half.
        self.assertEqual(catalog["staleBinaryCount"], 0)
        self.assertEqual(catalog["staleBinaries"], [])
        self.assertEqual(catalog["staleBinaryNote"], "")
        self.assertTrue(catalog["staleBinaryCasesExcludedFromTotal"])
        self.assertNotIn(
            inventory.STALE_BINARY_STATUS, catalog["countSourceCounts"]
        )
        self.assertEqual(
            inventory.sum_field(data["tests"], "sourceNewerThanBinary"), 0
        )
        for item in data["tests"]:
            self.assertIn("sourceNewerThanBinary", item)
        self.assertEqual(
            sum(catalog["countSourceCounts"].values()),
            data["static"]["testEntryCount"],
        )

        # Field completeness of the retained catalog. M2 deliverable 2
        # requires `bodyHash`, `group`, `threadsRequired`, `xfail`, `tags`
        # and `deterministic` to survive into this inventory, so the sources
        # that do NOT supply them are pinned rather than left implicit.
        #
        # Exactly one does: reprobuild's own `ct_test_unittest_parallel`
        # shim implements a narrower `--list-json` than the codetracer-nim
        # `std/unittest` fork — it emits `name`, `suite`, `file` and `line`
        # only. Its two cases therefore carry null for the rich fields. This
        # is a real gap in the shim, not in the inventory; when the shim is
        # brought up to the fork's catalog, this pin drops to zero and the
        # assertion below is what will say so.
        incomplete = sorted(
            {
                item["source"]
                for item in data["tests"]
                for case in item.get("catalogCases", [])
                if case.get("bodyHash") is None
            }
        )
        self.assertEqual(
            incomplete,
            [
                "libs/ct_test_unittest_parallel/tests/"
                "t_smoke_ct_test_unittest_parallel.nim"
            ],
        )
        # Every other catalog-counted case carries the full field set.
        for item in data["tests"]:
            if item["source"] in incomplete:
                continue
            for case in item.get("catalogCases", []):
                self.assertIsNotNone(case["bodyHash"])
                self.assertIsNotNone(case["group"])
                self.assertIsNotNone(case["threadsRequired"])
                self.assertIsNotNone(case["deterministic"])
                self.assertIsInstance(case["tags"], list)

    def test_tracked_artifact_is_path_stable_and_carries_no_body_hashes(self):
        """The TRACKED inventory must be reproducible across checkout paths.

        `bodyHash` is a function of the project's absolute path (campaign
        defect #52): any construct expanding to a string literal that
        carries the absolute source path is hashed verbatim by the
        compiler's `hashBodyTree`. Tracking 6,800+ such hashes would rewrite
        the whole artifact for every developer and CI runner whose checkout
        lives elsewhere — churn with no signal, and exactly the byte-level
        comparability that spec §16.4 protects when it forbids an embedded
        `compiled_at`.

        So the per-case detail goes to a build-local artifact instead, and
        this test is what keeps it there.

        The same argument disqualifies every other host-dependent field,
        and this test now checks all of them rather than naming a property
        it only partly enforced: no absolute path of ANY kind (not just the
        repo root), no timestamp, and no `footprint` / `host` / `tools` /
        `environment` / checkout-path block.
        """
        data = self.inventory_data()
        tracked, detail = inventory.split_case_catalog(
            data, inventory.DEFAULT_CASE_CATALOG
        )

        # No per-case payload survives into the tracked half.
        for item in tracked["tests"]:
            with self.subTest(source=item["source"]):
                self.assertNotIn("catalogCases", item)

        serialized = json.dumps(tracked, sort_keys=True)
        # `bodyHash` may appear as a FIELD NAME (retainedCaseFields) and in
        # the explanatory reason string, but never as a hash value. Real
        # hashes emitted by the protocol start with `__`.
        self.assertNotIn('"bodyHash": "__', serialized)
        for case in (
            case
            for item in data["tests"]
            for case in item.get("catalogCases", [])
            if case.get("bodyHash")
        ):
            self.assertNotIn(case["bodyHash"], serialized)

        # ---- the property this test is NAMED for -------------------------
        # "path-stable" previously meant one thing: `str(REPO_ROOT)` is
        # absent. That checked one of four channels. `/nix/store/...` is
        # not under REPO_ROOT, so seven absolute store paths in
        # `metadata.runtime.environment` sailed through, as did the
        # absolute `.so` path inside a loader-failure `quarantine[].detail`
        # and the absolute sibling-checkout paths in `sourceCheckouts`.
        #
        # The property asserted now is the real one: NO absolute path of
        # any kind, anywhere in the tracked document.
        self.assertNotIn(str(REPO_ROOT), serialized)
        absolute_paths = sorted(
            set(re.findall(r"(?<![\w:/])((?:/[A-Za-z0-9._+~@%-]+){2,})", serialized))
        )
        self.assertEqual(
            absolute_paths,
            [],
            "tracked inventory carries absolute host paths: "
            + ", ".join(absolute_paths[:10]),
        )

        # No timestamp, and no absolute repo root.
        self.assertNotIn("generatedAt", tracked["metadata"])
        self.assertEqual(tracked["metadata"]["repoRoot"], ".")

        # The host-dependent block is GONE from the tracked half, not
        # merely sanitized in place. Each of these changes on every build
        # or every host, which is the same defect as an embedded
        # timestamp.
        self.assertNotIn("footprint", tracked)
        self.assertNotIn("runtime", tracked["metadata"])
        self.assertIsNotNone(detail["footprint"])
        self.assertTrue(detail["footprint"]["entries"])
        runtime = detail["runtime"]
        for moved in ("environment", "host", "tools", "sourceCheckouts"):
            with self.subTest(moved=moved):
                self.assertIn(moved, runtime)
        for leaked in ("argv", "cwd", "pythonExecutable"):
            with self.subTest(field=leaked):
                self.assertNotIn(leaked, runtime)

        # What survives is the part that is a fact about the INPUTS rather
        # than the host: each external checkout's revision, keyed by name,
        # carrying no path.
        revisions = tracked["metadata"]["sourceCheckoutRevisions"]
        self.assertIsInstance(revisions, dict)
        self.assertEqual(
            set(revisions),
            set(runtime.get("sourceCheckouts", {})),
        )
        for name, entry in revisions.items():
            with self.subTest(checkout=name):
                self.assertEqual(set(entry), {"head", "branch", "dirty"})
        self.assertFalse(tracked["metadata"]["runtimeDetailTracked"])
        self.assertTrue(tracked["metadata"]["runtimeDetailPath"])
        for pointer in (
            tracked["metadata"]["runtimeDetailPath"],
            tracked["metadata"]["environmentReportPath"],
            tracked["catalogEnumeration"]["caseDetailPath"],
        ):
            with self.subTest(pointer=pointer):
                self.assertFalse(Path(pointer).is_absolute())

        # The gate-relevant, path-stable data is retained.
        for item in tracked["tests"]:
            with self.subTest(source=item["source"]):
                self.assertIn("sourceCaseCount", item)
                self.assertIn("staticCaseCount", item)
                self.assertIn("countSource", item)
        self.assertIn("quarantine", tracked["catalogEnumeration"])
        self.assertFalse(tracked["catalogEnumeration"]["caseDetailTracked"])

        # The detail half is complete: every catalog-counted source, with
        # its full case list, is present and its counts agree with the
        # tracked half. The split must lose nothing.
        catalog_sources = {
            item["source"]
            for item in data["tests"]
            if item.get("countSource") == "catalog"
        }
        self.assertEqual(set(detail["sources"]), catalog_sources)
        self.assertEqual(detail["sourceCount"], len(catalog_sources))
        tracked_by_source = {item["source"]: item for item in tracked["tests"]}
        for source, entry in detail["sources"].items():
            with self.subTest(detail_source=source):
                self.assertEqual(
                    entry["caseCount"],
                    tracked_by_source[source]["sourceCaseCount"],
                )
                self.assertEqual(len(entry["cases"]), entry["caseCount"])
        self.assertEqual(
            detail["caseCount"],
            sum(
                item["sourceCaseCount"]
                for item in tracked["tests"]
                if item.get("countSource") == "catalog"
            ),
        )
        self.assertFalse(detail["tracked"])

    def test_tracked_markdown_report_is_stable_across_hosts_and_builds(self):
        """The TRACKED markdown is held to the same rule as the tracked JSON.

        `benchmarks/reports/reprobuild-suite-m0-baseline.md` is checked into
        git, and it used to render four host-dependent things: the recorded
        environment (absolute `/nix/store` values), the host's kernel and
        glibc version, the git/nim/nix/python versions, and a `du` over
        `build/` — `build/nimcache` alone is multi-GiB and moves whenever
        anything is compiled. So regenerating the report rewrote a tracked
        file even when nothing about the suite had changed, which is the
        same defect spec §16.4 forbids for an embedded build timestamp.

        The information is relocated, not deleted: this test asserts BOTH
        halves — absent from the tracked report, present in the build-local
        one — so a future "simplification" cannot satisfy it by dropping
        the data on the floor.
        """
        data = self.inventory_data()
        tracked, detail = inventory.split_case_catalog(
            data, inventory.DEFAULT_CASE_CATALOG
        )
        report = inventory.render_report(
            tracked, inventory.DEFAULT_JSON.as_posix(), detail
        )
        environment_report = inventory.render_environment_report(data, detail)

        # (1) No absolute path of any kind, same property as the JSON.
        absolute_paths = sorted(
            set(re.findall(r"(?<![\w:/])((?:/[A-Za-z0-9._+~@%-]+){2,})", report))
        )
        self.assertEqual(
            absolute_paths,
            [],
            "tracked markdown carries absolute host paths: "
            + ", ".join(absolute_paths[:10]),
        )
        self.assertNotIn(str(REPO_ROOT), report)
        self.assertNotIn("/nix/store", report)

        # (2) No host identity, no tool versions, no recorded environment.
        # Every value is read from the LIVE runtime block, so this cannot
        # pass by accident on a machine whose strings happen to differ.
        #
        # Live values are checked as whole rendered rows rather than as bare
        # substrings:
        # `logicalCpuCount` is "32" and so is more than one legitimate
        # count elsewhere in the report, while `machine` can be `arm64` and
        # legitimately occur in compiler arguments and test identities.
        # A second render with unique sentinels below additionally catches a
        # value leaked into prose rather than a table row.
        runtime = detail["runtime"]
        volatile_rows = [
            f"| {key} | {block[key]} |"
            for block in (
                runtime["host"],
                runtime["tools"],
                runtime["environment"],
            )
            for key in sorted(block)
        ]
        self.assertTrue(volatile_rows)
        for rendered in volatile_rows:
            with self.subTest(volatile_row=rendered):
                self.assertNotIn(rendered, report)

        # Give one established field in the host and tool blocks, plus one
        # recorded-environment field, values that cannot legitimately occur
        # in the inventory. Keeping this as an independent render preserves
        # the relocation proof for every real live value above and below.
        sentinel_data = copy.deepcopy(data)
        runtime_sentinels = {
            "host": ("machine", "mcl-host-identity-7f3a620bd1b94fa6"),
            "tools": ("python", "mcl-tool-version-621ad98ce0d04e12"),
            "environment": (
                "MCL_TEST_RECORDED_ENVIRONMENT",
                "mcl-recorded-environment-8d29bf9d13e843e8",
            ),
        }
        sentinel_input_runtime = sentinel_data["metadata"]["runtime"]
        for block_name, (key, value) in runtime_sentinels.items():
            sentinel_input_runtime[block_name][key] = value
        sentinel_tracked, sentinel_detail = inventory.split_case_catalog(
            sentinel_data, inventory.DEFAULT_CASE_CATALOG
        )
        sentinel_report = inventory.render_report(
            sentinel_tracked,
            inventory.DEFAULT_JSON.as_posix(),
            sentinel_detail,
        )
        sentinel_environment_report = inventory.render_environment_report(
            sentinel_data, sentinel_detail
        )

        def assert_sentinels_are_untracked(candidate_report):
            for block_name, (key, value) in runtime_sentinels.items():
                with self.subTest(volatile_sentinel=block_name):
                    self.assertNotIn(f"| {key} | {value} |", candidate_report)
                    self.assertNotIn(value, candidate_report)

        assert_sentinels_are_untracked(sentinel_report)
        # Architecture names are also suite vocabulary.  On an arm64 host,
        # prove the live machine value has a legitimate tracked occurrence;
        # this is why checking the bare live value would be a false positive.
        if runtime["host"].get("machine") == "arm64":
            self.assertIn('"arm64"', report)
        for block_name, (key, value) in runtime_sentinels.items():
            with self.subTest(relocated_sentinel=block_name):
                self.assertIn(
                    f"| {key} | {value} |", sentinel_environment_report
                )
                self.assertIn(value, sentinel_environment_report)

        # (3) No footprint SIZES. Which paths are measured is a property
        # of the script and stays; how big they are is a property of the
        # last build and goes. The whole rendered row is checked, not a
        # bare number: "| 15 |" legitimately occurs in the classification
        # table, and an assertion that trips on that would be noise
        # rather than signal.
        def footprint_row(entry):
            kib = entry["kib"]
            mib = "not present" if kib is None else f"{kib / 1024.0:.1f} MiB"
            exe = (
                "n/a"
                if entry["executableFiles"] is None
                else str(entry["executableFiles"])
            )
            return f"| {entry['path']} | {mib} | {exe} |"

        for entry in detail["footprint"]["entries"]:
            with self.subTest(footprint=entry["path"]):
                # The path is named — the reader still learns what is
                # measured.
                self.assertIn(entry["path"], report)
                self.assertNotIn(footprint_row(entry), report)
                if entry["kib"]:
                    self.assertNotIn(
                        f"{entry['kib'] / 1024.0:.1f} MiB", report
                    )

        # (4) The tracked report points at the build-local one, by a
        # relative path.
        pointer = tracked["metadata"]["environmentReportPath"]
        self.assertFalse(Path(pointer).is_absolute())
        self.assertIn(pointer, report)

        # (5) And the build-local report actually carries what was moved,
        # un-redacted. Relocation, not deletion — a future
        # "simplification" must not be able to satisfy (2) by dropping the
        # data on the floor.
        for rendered in volatile_rows:
            with self.subTest(relocated_row=rendered):
                self.assertIn(rendered, environment_report)
        for entry in detail["footprint"]["entries"]:
            with self.subTest(relocated_footprint=entry["path"]):
                self.assertIn(footprint_row(entry), environment_report)

    def test_missing_binary_is_its_own_label_not_plain_static(self):
        """A Nim source with no built binary gets a DISTINCT label.

        Every Nim source in the tree currently has a built binary, so this
        path has no natural example; it is exercised with a spec pointing at
        a binary that does not exist.

        `missing-binary` used to degrade to `countSource: "static"`, which
        made a BUILD GAP indistinguishable from a Python file that
        legitimately has no binary. Both said "static", so a Nim binary
        silently failing to build read as a language property.
        """
        missing = inventory.TestSpec(
            source="tests/unit/t_declared_package_deps_from_recipe.nim",
            binary="build/test-bin/definitely_not_built_binary",
            defines=[],
            requires_repro_binary=False,
            target_os="soAny",
        )
        index = inventory.catalog_index(
            REPO_ROOT, [missing], use_cache=False
        )
        self.assertEqual(index[missing.source]["status"], "missing-binary")
        # The label is what the inventory writes, and it is not "static".
        self.assertEqual(
            inventory.catalog_count_source(index[missing.source]),
            "missing-binary",
        )
        self.assertEqual(
            inventory.catalog_count_source({"status": "ok", "cases": []}),
            "catalog",
        )
        self.assertEqual(
            inventory.catalog_count_source({"status": "no-protocol-support"}),
            "quarantined",
        )
        # No probe attempted at all (`--no-catalog`) is the only `static`.
        self.assertEqual(inventory.catalog_count_source(None), "static")

    def test_a_source_with_no_built_binary_contributes_nothing(self):
        """`missing-binary` votes zero, exactly as `quarantined` does.

        A source whose binary was never built has no enumeration to offer, so
        it must contribute NOTHING to a total documented as reading built
        binaries. It used to fall through to the static source scan instead,
        which is how a build gap donated its source-text count to the
        authoritative number.

        Why that mattered more than it looks: it made the aggregate pin
        unfalsifiable. Measured on this tree with 24 binaries moved aside --
        sources registering 60 catalog cases, static scan also 60 -- the total
        came back 6912, the pinned number to the case, while 24 binaries were
        absent. The pin agreed with reality because it could not disagree.

        Pinned here at the level of the rule rather than through a broken
        build, so the property survives without a 1200-binary fixture. The
        aggregate assertions in
        `assert_inventory_case_counts_pin_multiline_and_fixture_regressions`
        are the same property measured end to end: `nim_total` must equal
        `sum(len(catalogCases))` over catalog-counted sources, which is an
        identity only while nothing else contributes.
        """
        cases = [{"name": "a"}, {"name": "b"}, {"name": "c"}]

        # The binary answered: its own catalog, and nothing else.
        self.assertEqual(
            inventory.authoritative_case_count("catalog", cases, 99), 3
        )
        # Neither silence is allowed to speak with the source text's voice.
        for silent in ("missing-binary", "quarantined"):
            with self.subTest(count_source=silent):
                self.assertEqual(
                    inventory.authoritative_case_count(silent, None, 7), 0
                )
        self.assertEqual(
            set(inventory.CASE_COUNT_AUTHORITY_ZERO_SOURCES),
            # Three ways a binary can fail to represent its source, all
            # voting zero. `source-newer-than-binary` joined them after a
            # stale binary reached `dev` reporting 8 cases for a source that
            # had 10.
            {"missing-binary", "quarantined", "source-newer-than-binary"},
        )
        # `static` is the one label for which the scan IS the only surface:
        # `--no-catalog`, and Python files, which have no binary to ask.
        self.assertEqual(
            inventory.authoritative_case_count("static", None, 7), 7
        )

    def test_a_binary_older_than_its_source_contributes_nothing(self):
        """The third way a binary can fail to represent its source.

        Unlike the other two this one ANSWERS. A missing binary is silent
        and an unenumerable binary fails loudly, but a stale binary exits 0
        with a well-formed catalog describing a revision that no longer
        exists on disk -- and nothing in that answer says so.

        Measured instance, which is why this is a rule and not a warning:
        `5688d28e` added two cases to
        `libs/repro_project_dsl/tests/test_library_macro.nim`. Its binary
        was 18 hours older and reported 8 where the source had 10. The
        pinned Nim total agreed with the stale 8 exactly, and would have
        gone on agreeing for as long as nobody rebuilt that one binary.
        Only the independent static scan of the SOURCE read 10.

        Substituting the static scan here would look defensible and be the
        same defect in a different coat: it would report a count for a
        source that nothing current measured. Zero is the only honest
        contribution, and refusing to count is what turns the two surfaces'
        disagreement into a failure instead of a number.
        """
        cases = [{"name": "a"}, {"name": "b"}]
        self.assertEqual(
            inventory.authoritative_case_count(
                inventory.STALE_BINARY_STATUS, None, 7
            ),
            0,
        )
        # And it is its own label, not a quarantine reason: quarantine means
        # "could not answer", which is a different fact from "answered about
        # a different file".
        self.assertEqual(
            inventory.catalog_count_source(
                {"status": inventory.STALE_BINARY_STATUS}
            ),
            inventory.STALE_BINARY_STATUS,
        )
        self.assertNotEqual(
            inventory.STALE_BINARY_STATUS, "quarantined"
        )
        # A binary that DID answer and is current still wins, unchanged.
        self.assertEqual(
            inventory.authoritative_case_count("catalog", cases, 99), 2
        )

    def test_staleness_is_detected_and_names_both_timestamps(self):
        """mtime over-reports; the diagnostic has to make that legible.

        A branch switch rewrites source mtimes without touching binaries, so
        a switched tree can flag hundreds of sources that are not really
        stale. That direction is deliberate -- refusing to count costs a
        rebuild, while counting from a binary that does not match its source
        is silent and wrong. The price is that the diagnostic must let a
        developer tell the two apart in one read, which means naming every
        flagged source with BOTH timestamps.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "t_thing.nim"
            binary = root / "t_thing"
            source.write_text("suite \"s\":\n  test \"t\":\n    check true\n")
            binary.write_text("binary")

            # Binary newer than source: believable, so no outcome at all.
            os.utime(source, (1_000_000, 1_000_000))
            os.utime(binary, (1_000_100, 1_000_100))
            self.assertIsNone(inventory.binary_staleness(source, binary))

            # Equal mtimes are also believable -- a rebuild that lands in the
            # same second must not be flagged.
            os.utime(binary, (1_000_000, 1_000_000))
            self.assertIsNone(inventory.binary_staleness(source, binary))

            # Source newer: refused, with both timestamps and the gap.
            os.utime(source, (1_000_500, 1_000_500))
            outcome = inventory.binary_staleness(source, binary)
            self.assertIsNotNone(outcome)
            self.assertEqual(
                outcome["status"], inventory.STALE_BINARY_STATUS
            )
            self.assertEqual(outcome["staleBySeconds"], 500.0)
            self.assertIn("Z", outcome["sourceMtime"])
            self.assertIn("Z", outcome["binaryMtime"])
            self.assertIn("rebuild it", outcome["detail"])

            # The aggregate note names the source and both timestamps, so the
            # classification can be checked rather than trusted.
            note = inventory.stale_binary_note(
                [
                    {
                        "source": "tests/integration/t_thing.nim",
                        "binary": "build/test-bin/t_thing",
                        "sourceMtime": outcome["sourceMtime"],
                        "binaryMtime": outcome["binaryMtime"],
                        "staleBySeconds": outcome["staleBySeconds"],
                        "staticCaseCount": 1,
                    }
                ]
            )
            self.assertIn("tests/integration/t_thing.nim", note)
            self.assertIn(outcome["sourceMtime"], note)
            self.assertIn(outcome["binaryMtime"], note)
            self.assertIn("REFUSED", note)
            # One source is not a branch switch, so it must not be blamed on
            # one.
            self.assertNotIn("branch switch", note)
            # Many at once is, and the hint has to appear or the developer
            # reads a wall of names with no interpretation.
            many = inventory.stale_binary_note(
                [
                    {
                        "source": f"tests/integration/t_{index}.nim",
                        "binary": f"build/test-bin/t_{index}",
                        "sourceMtime": outcome["sourceMtime"],
                        "binaryMtime": outcome["binaryMtime"],
                        "staleBySeconds": 1.0,
                        "staticCaseCount": 1,
                    }
                    for index in range(
                        inventory.STALE_BINARY_BRANCH_SWITCH_HINT_THRESHOLD
                    )
                ]
            )
            self.assertIn("branch switch", many)
            self.assertEqual(inventory.stale_binary_note([]), "")

    def test_summing_a_field_that_does_not_exist_is_an_error(self):
        """A missing field must not read as a zero count.

        This is the shape that let a fabricated measurement look verified in
        three separate places. `0 source-newer-than-binary` was reported as a
        measured property of the tree while `build_inventory` emitted no such
        field: every per-spec lookup returned `None`, `sum(... or 0)`
        returned 0, and 0 is exactly what a healthy tree reports too. The
        query and the passing check were indistinguishable.

        So the summing path indexes rather than `get`s, and says which record
        and which field when it cannot.
        """
        records = [{"sourceCaseCount": 2}, {"sourceCaseCount": 3}]
        self.assertEqual(inventory.sum_field(records, "sourceCaseCount"), 5)
        with self.assertRaises(KeyError) as caught:
            inventory.sum_field(records, "sourceNewerThanBinary")
        message = str(caught.exception)
        self.assertIn("sourceNewerThanBinary", message)
        self.assertIn("must not read as a zero count", message)
        # And it names the offending record, not just the field.
        named = [{"source": "tests/integration/t_x.nim"}]
        with self.assertRaises(KeyError) as caught_named:
            inventory.sum_field(named, "sourceCaseCount")
        self.assertIn("t_x.nim", str(caught_named.exception))

    def test_catalog_index_memo_is_keyed_by_the_spec_set(self):
        """A one-spec index must never satisfy a full-tree request.

        `_CATALOG_INDEX_MEMO` was keyed by
        `(root, timeout, workers, use_cache)` and IGNORED its `specs`
        argument. Only one caller passed `use_cache=False`, so nothing
        collided by luck. The moment `--no-cache` exists, a full-specs call
        and a one-spec call share a key: the first result wins, every real
        source degrades to `missing-binary`, and the whole inventory
        silently reverts to the static scan the catalog rework replaced.

        This reproduces the collision through the public entry point.
        """
        one = inventory.TestSpec(
            source="tests/unit/t_declared_package_deps_from_recipe.nim",
            binary="build/test-bin/definitely_not_built_binary",
            defines=[],
            requires_repro_binary=False,
            target_os="soAny",
        )
        other = inventory.TestSpec(
            source="tests/unit/t_declared_package_deps_from_recipe.nim",
            binary="build/test-bin/t_declared_package_deps_from_recipe",
            defines=[],
            requires_repro_binary=False,
            target_os="soAny",
        )
        first = inventory.catalog_index(REPO_ROOT, [one], use_cache=False)
        second = inventory.catalog_index(REPO_ROOT, [other], use_cache=False)
        # Same root, same timeout, same workers, same use_cache — different
        # specs. The second call must reflect ITS OWN specs.
        self.assertEqual(first[one.source]["status"], "missing-binary")
        self.assertEqual(second[other.source]["status"], "ok")
        self.assertNotEqual(
            inventory.specs_digest([one]), inventory.specs_digest([other])
        )
        # And the memo still memoizes: an identical request is the same
        # object, so the fix did not simply disable caching.
        self.assertIs(
            inventory.catalog_index(REPO_ROOT, [other], use_cache=False),
            second,
        )

    def test_only_successful_probes_are_ever_cached(self):
        """A failed probe must not survive the condition that produced it.

        The on-disk cache is keyed by each binary's `size:mtime_ns`, and it
        used to store EVERY result. A `timeout` recorded on a loaded host
        was therefore replayed by every later run on that machine, forever,
        with no flag to bypass it — the observed failure that motivated
        this change (`plasma-workspace` needs ~230 s and the probe budget
        was 300 s).
        """
        source = "tests/unit/t_declared_package_deps_from_recipe.nim"
        binary = "build/test-bin/t_declared_package_deps_from_recipe"
        # An isolated cache file inside the repo, so the code under test
        # exercises its real `root / CATALOG_CACHE_PATH` join without
        # touching the suite's own cache.
        scratch_cache = Path("build") / "t-cache-policy-probe.json"
        cache_path = REPO_ROOT / scratch_cache
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        self.addCleanup(cache_path.unlink, missing_ok=True)

        key = inventory.binary_cache_key(REPO_ROOT / binary)
        self.assertIsNotNone(key)
        # A hand-written cache holding a negative entry, exactly the shape
        # the old code produced and replayed.
        cache_path.write_text(
            json.dumps(
                {
                    "version": inventory.CATALOG_CACHE_VERSION,
                    "entries": {
                        source: {
                            "key": key,
                            "result": {
                                "status": "timeout",
                                "detail": "--list-json exceeded 300s",
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )

        spec = inventory.TestSpec(
            source=source,
            binary=binary,
            defines=[],
            requires_repro_binary=False,
            target_os="soAny",
        )
        with mock.patch.object(
            inventory, "CATALOG_CACHE_PATH", scratch_cache
        ), mock.patch.dict(inventory._CATALOG_INDEX_MEMO, {}, clear=True):
            index = inventory.catalog_index(REPO_ROOT, [spec], use_cache=True)
        # The negative entry was NOT replayed: the binary was re-probed and
        # answered. Under the old code this asserted "timeout" forever.
        self.assertEqual(index[spec.source]["status"], "ok")

        # The `ok` result from that run WAS persisted — the cache still
        # does its job.
        written = inventory.load_catalog_cache(cache_path)
        self.assertEqual(written[source]["result"]["status"], "ok")

        # The READ-side guard, isolated. The assertion above would also be
        # satisfied by the serial retry alone (an environmental reason is
        # re-probed even if it was replayed from cache), so it does not on
        # its own prove that the reader refuses a cached failure. An
        # INTRINSIC cached failure is never retried, so replaying one would
        # survive to the result — which is exactly what this catches.
        cache_path.write_text(
            json.dumps(
                {
                    "version": inventory.CATALOG_CACHE_VERSION,
                    "entries": {
                        source: {
                            "key": key,
                            "result": {
                                "status": "no-protocol-support",
                                "detail": "stale negative entry",
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        with mock.patch.object(
            inventory, "CATALOG_CACHE_PATH", scratch_cache
        ), mock.patch.dict(inventory._CATALOG_INDEX_MEMO, {}, clear=True):
            index = inventory.catalog_index(REPO_ROOT, [spec], use_cache=True)
        self.assertEqual(index[spec.source]["status"], "ok")

        # And the write side refuses to persist a non-ok result, including
        # an INTRINSIC one. Nothing about a failed probe is cacheable: the
        # cache key is size+mtime, so re-probing an unchanged binary is
        # cheap next to replaying a wrong answer.
        def never_enumerates(binary_path, cwd, env, timeout_seconds):
            return {
                "status": "no-protocol-support",
                "detail": "no protocol marker string present in the binary",
            }

        # Start from an empty cache so the probe actually runs (the `ok`
        # entry just written would otherwise be reused, correctly).
        cache_path.unlink()
        with mock.patch.object(
            inventory, "CATALOG_CACHE_PATH", scratch_cache
        ), mock.patch.object(
            inventory, "probe_binary_catalog", never_enumerates
        ), mock.patch.dict(inventory._CATALOG_INDEX_MEMO, {}, clear=True):
            index = inventory.catalog_index(REPO_ROOT, [spec], use_cache=True)
        self.assertEqual(index[spec.source]["status"], "no-protocol-support")
        written = inventory.load_catalog_cache(cache_path)
        self.assertNotIn(source, written)
        for cached_source, entry in written.items():
            with self.subTest(cached=cached_source):
                self.assertEqual(entry["result"]["status"], "ok")

    def test_environmental_probe_failure_aborts_instead_of_quarantining(self):
        """A timeout is not a fact about a test, so it may not become one.

        Before this change a probe `timeout` was cached AND recorded as a
        quarantine entry, which meant a busy afternoon permanently mutated
        the pinned quarantine set and the case totals derived from it.

        The required behaviour: retry serially with a longer budget, and if
        the retry also fails, ABORT with an explicit environment error.
        """
        # Run the real shim binary under the protocol variables supplied by an
        # outer per-case runner.  Those variables are not themselves the cause:
        # the codetracer Nim fork redirects descriptor 1 to stderr during
        # ``std/unittest`` module initialisation, before the shim's own exit hook
        # writes its catalog.  The old shim therefore returned zero with valid
        # JSON wholly on stderr and an empty stdout, which this exact consumer
        # boundary rejected as ``empty-output``.
        binary = (
            REPO_ROOT
            / "build/test-bin/t_smoke_ct_test_unittest_parallel"
        )
        self.assertTrue(binary.is_file(), f"missing built test binary: {binary}")
        with tempfile.TemporaryDirectory(
            prefix="repro-shim-catalog-"
        ) as scratch:
            env = inventory.catalog_probe_env()
            env.update(
                {
                    "NIMTEST_RESULT_FILE": str(Path(scratch) / "outer.json"),
                    "NIMTEST_OUTPUT_LVL": "PRINT_NONE",
                    "NIMTEST_COLOR": "never",
                }
            )
            completed = subprocess.run(
                [str(binary), "--list-json"],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=30,
                cwd=scratch,
                env=env,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertNotEqual(completed.stdout.strip(), "")
            self.assertEqual(completed.stderr, "")
            document = json.loads(completed.stdout)
            self.assertEqual(document["summary"]["total"], 2)

            outcome = inventory.probe_binary_catalog(
                binary, Path(scratch), env, timeout_seconds=30
            )
            self.assertEqual(outcome["status"], "ok", outcome)
            self.assertEqual(len(outcome["cases"]), 2)

        # Darwin's nix dev shell publishes its runtime closure through the
        # Linux-named variable only. The inventory must translate that value
        # into the child environment BEFORE subprocess.run starts; mutating
        # os.environ after this snapshot cannot repair an already-created
        # probe environment.
        with mock.patch.object(sys, "platform", "darwin"), mock.patch.dict(
            os.environ,
            {
                "LD_LIBRARY_PATH": "/nix/store/clingo/lib:/nix/store/zstd/lib",
                "DYLD_LIBRARY_PATH": "/existing/dyld:/nix/store/clingo/lib",
                "DYLD_FALLBACK_LIBRARY_PATH": "/existing/fallback",
            },
            clear=True,
        ):
            probe_env = inventory.catalog_probe_env()
            self.assertEqual(
                probe_env["DYLD_LIBRARY_PATH"],
                "/nix/store/clingo/lib:/nix/store/zstd/lib:/existing/dyld",
            )
            self.assertEqual(
                probe_env["DYLD_FALLBACK_LIBRARY_PATH"],
                "/nix/store/clingo/lib:/nix/store/zstd/lib:/existing/fallback",
            )
            os.environ["LD_LIBRARY_PATH"] = "/too/late"
            self.assertNotIn("/too/late", probe_env["DYLD_LIBRARY_PATH"])

        spec = inventory.TestSpec(
            source="tests/unit/t_declared_package_deps_from_recipe.nim",
            binary="build/test-bin/t_declared_package_deps_from_recipe",
            defines=[],
            requires_repro_binary=False,
            target_os="soAny",
        )
        budgets: list[int] = []

        def always_times_out(binary_path, cwd, env, timeout_seconds):
            budgets.append(timeout_seconds)
            return {
                "status": "timeout",
                "detail": f"--list-json exceeded {timeout_seconds}s",
            }

        with mock.patch.object(
            inventory, "probe_binary_catalog", always_times_out
        ), mock.patch.dict(inventory._CATALOG_INDEX_MEMO, {}, clear=True):
            with self.assertRaises(inventory.CatalogEnvironmentError) as caught:
                inventory.catalog_index(REPO_ROOT, [spec], use_cache=False)
        message = str(caught.exception)
        self.assertIn("timeout", message)
        self.assertIn(spec.source, message)
        # It was retried, and the retry budget was LARGER than the
        # parallel-pass budget: a contended parallel pass is the dominant
        # cause of these failures, so re-measuring with the same bound
        # would prove nothing.
        self.assertEqual(len(budgets), 2)
        self.assertGreater(budgets[1], budgets[0])
        self.assertEqual(budgets[0], inventory.CATALOG_PROBE_TIMEOUT_SECONDS)
        self.assertEqual(
            budgets[1], inventory.CATALOG_PROBE_RETRY_TIMEOUT_SECONDS
        )

        # A transient failure that clears on the retry is NOT an abort and
        # NOT a quarantine: the serial pass is believed.
        attempts: list[int] = []

        def times_out_once(binary_path, cwd, env, timeout_seconds):
            attempts.append(timeout_seconds)
            if len(attempts) == 1:
                return {"status": "timeout", "detail": "transient"}
            return {"status": "ok", "cases": []}

        with mock.patch.object(
            inventory, "probe_binary_catalog", times_out_once
        ), mock.patch.dict(inventory._CATALOG_INDEX_MEMO, {}, clear=True):
            index = inventory.catalog_index(REPO_ROOT, [spec], use_cache=False)
        self.assertEqual(index[spec.source]["status"], "ok")
        self.assertEqual(len(attempts), 2)

        # Defence in depth on the timeout constant itself. The slowest
        # binary in the tree needs ~230 s at idle and the suite was
        # observed inflating ~7x under load (703 s against a ~104 s
        # baseline), so a bound below ~1610 s is a bound that load alone
        # can cross.
        self.assertGreaterEqual(inventory.CATALOG_PROBE_TIMEOUT_SECONDS, 1610)

    def test_probe_never_runs_a_test_binary_inside_the_repository(self):
        """The probe must not be able to change the fingerprint it records.

        `source_fingerprint` hashes `git ls-files --others
        --exclude-standard`, i.e. untracked files. The probe executes 1206
        test binaries 16 at a time; a recipe binary was observed dropping
        `test_kglobalaccel_source_linkerArgs.txt` into its working
        directory. With `cwd` at the repo root that stray file is an
        untracked file, so the measurement perturbed its own input.
        """
        seen: list[Path] = []

        def record_cwd(binary_path, cwd, env, timeout_seconds):
            seen.append(Path(cwd))
            return {"status": "ok", "cases": []}

        spec = inventory.TestSpec(
            source="tests/unit/t_declared_package_deps_from_recipe.nim",
            binary="build/test-bin/t_declared_package_deps_from_recipe",
            defines=[],
            requires_repro_binary=False,
            target_os="soAny",
        )
        with mock.patch.object(
            inventory, "probe_binary_catalog", record_cwd
        ), mock.patch.dict(inventory._CATALOG_INDEX_MEMO, {}, clear=True):
            inventory.catalog_index(REPO_ROOT, [spec], use_cache=False)
        self.assertEqual(len(seen), 1)
        probe_cwd = seen[0].resolve()
        self.assertNotEqual(probe_cwd, REPO_ROOT.resolve())
        self.assertNotIn(REPO_ROOT.resolve(), probe_cwd.parents)

    def test_no_cache_flag_exists_and_reaches_the_catalog_index(self):
        """`--no-catalog` was the only escape hatch, and it is the wrong one.

        A poisoned cache could previously be cleared only by deleting the
        file by hand: `--no-catalog` disables probing altogether and falls
        back to the static scan, which is the known-broken counter. A
        cache bypass must keep the binary as the enumeration authority.
        """
        args = inventory.parse_args([])
        self.assertFalse(args.no_cache)
        args = inventory.parse_args(["--no-cache"])
        self.assertTrue(args.no_cache)
        # `--no-cache` is not `--no-catalog`: probing stays on.
        self.assertFalse(args.no_catalog)

        captured: dict[str, object] = {}

        def fake_index(root, specs, **kwargs):
            captured.update(kwargs)
            return {}

        with mock.patch.object(inventory, "catalog_index", fake_index):
            inventory.build_inventory(REPO_ROOT, None, use_catalog_cache=False)
        self.assertIs(captured.get("use_cache"), False)

    def test_absolute_paths_are_redacted_to_their_basename(self):
        """The sanitizer keeps the signal and drops the host."""
        self.assertEqual(
            inventory.redact_absolute_paths(
                "error while loading shared libraries: "
                "/nix/store/abc-clingo/lib/libclingo.so.4"
            ),
            "error while loading shared libraries: <abs>/libclingo.so.4",
        )
        # Relative paths and URLs are untouched: over-redaction would
        # destroy the parts of the artifact that are legitimately stable.
        for kept in (
            "build/test-bin/t_thing",
            "libs/repro_peer_cache/tests/t_n7_multicast_windows_smoke.nim",
            "https://example.invalid/a/b/c",
        ):
            with self.subTest(kept=kept):
                self.assertEqual(inventory.redact_absolute_paths(kept), kept)

    def render_failed_tests_section(self, doc: dict) -> str:
        """Summarize a runner document and render its failure section.

        Goes through the real `summarize_runner` -> `render_failed_tests_section`
        path, so an assertion here covers the producer and the renderer
        together rather than a hand-built intermediate.
        """
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "parallel-run.json"
            path.write_text(json.dumps(doc), encoding="utf-8")
            summary = inventory.summarize_runner(path)
        return "\n".join(inventory.render_failed_tests_section(summary))

    def test_runner_summary_names_every_case_and_splits_harness_errors(self):
        """The consumer side of the runner's reporting contract.

        Two properties of ``test-logs/parallel-run.json`` that gates depend
        on, asserted here because this is the function every gate goes
        through:

        1. every entry is nameable from the artifact alone — an entry with
           a missing or blank ``name`` pushes verification back to grepping
           the console log, which is the practice that let a false "zero
           skips" conclusion survive three consecutive runs that each
           carried 176 skips; and
        2. ``ERROR`` (the harness could not run the case) is reported
           separately from ``FAIL`` (the case ran and failed). Merging them
           in the consumer would undo the split the runner makes, and the
           two demand different responses: one is a defect in the tree, the
           other is a defect in the run.
        """
        doc = {
            "summary": {
                "total": 4,
                "passed": 1,
                "failed": 1,
                "skipped": 1,
                "harness_errors": 1,
                "status_disagreements": 0,
            },
            "tests": [
                {
                    "binary_stem": "t_alpha",
                    "name": "passes",
                    "suite": "alpha",
                    "qualified_name": "alpha::passes",
                    "run_name": "alpha::passes",
                    "protocol_aware": True,
                    "status": "PASS",
                    "duration_ms": 5,
                },
                {
                    "binary_stem": "t_alpha",
                    "name": "fails",
                    "suite": "alpha",
                    "qualified_name": "alpha::fails",
                    "run_name": "alpha::fails",
                    "protocol_aware": True,
                    "status": "FAIL",
                    "duration_ms": 6,
                },
                {
                    "binary_stem": "t_alpha",
                    "name": "skips",
                    "suite": "alpha",
                    "qualified_name": "alpha::skips",
                    "run_name": "alpha::skips",
                    "protocol_aware": True,
                    "status": "SKIP",
                    "duration_ms": 0,
                },
                {
                    "binary_stem": "t_alpha",
                    "name": "never started",
                    "suite": "alpha",
                    "qualified_name": "alpha::never started",
                    "run_name": "alpha::never started",
                    "protocol_aware": True,
                    "status": "ERROR",
                    "harness_error": "spawn failed: Bad file descriptor",
                    "duration_ms": 83,
                },
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "parallel-run.json"
            path.write_text(json.dumps(doc), encoding="utf-8")
            report = inventory.summarize_runner(path)

        self.assertIsNotNone(report)
        self.assertEqual(report["unnamedCaseCount"], 0)
        self.assertEqual([t["name"] for t in report["failedTests"]], ["fails"])
        self.assertEqual(
            [t["name"] for t in report["harnessErrorTests"]], ["never started"]
        )
        self.assertEqual(
            report["harnessErrorTests"][0]["harness_error"],
            "spawn failed: Bad file descriptor",
        )
        self.assertEqual(report["unrecognizedStatusTests"], [])

        # And the detection side: a nameless entry must be counted, not
        # quietly tolerated. This is the regression the artifact had —
        # every entry carried only ``qualified_name`` and consumers
        # reading ``name`` saw ``None`` across the whole run.
        damaged = json.loads(json.dumps(doc))
        del damaged["tests"][0]["name"]
        damaged["tests"][1]["name"] = "   "
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "parallel-run.json"
            path.write_text(json.dumps(damaged), encoding="utf-8")
            report = inventory.summarize_runner(path)
        self.assertEqual(report["unnamedCaseCount"], 2)
        self.assertEqual(
            [t["qualified_name"] for t in report["unnamedCases"]],
            ["alpha::passes", "alpha::fails"],
        )

        # ---- and the RENDERED half of the same contract ----------------
        # Splitting ERROR out of FAIL in `summarize_runner` closed a hole
        # in the runner and opened the same hole one layer up: the
        # "## Failed Tests" section rendered `failedTests` only, so a run
        # that exited NON-ZERO purely on harness errors printed a green
        # "No failed tests were reported" sentence into the tracked
        # baseline. `harnessErrorTests` and `unrecognizedStatusTests`
        # rendered nowhere at all.
        rendered = self.render_failed_tests_section(doc)
        # Every non-passing outcome is named.
        self.assertIn("alpha::fails", rendered)
        self.assertIn("alpha::never started", rendered)
        # ...and the ERROR carries its reason, not just its name.
        self.assertIn("spawn failed: Bad file descriptor", rendered)
        # The green sentence must not appear while anything is red.
        self.assertNotIn("No failed tests", rendered)

        # A run whose ONLY non-passing outcome is a harness error is the
        # exact shape that used to render green. Assert it directly:
        # zero FAILs must not buy a clean report.
        errors_only = json.loads(json.dumps(doc))
        errors_only["tests"] = [
            t for t in errors_only["tests"] if t["status"] != "FAIL"
        ]
        rendered_errors_only = self.render_failed_tests_section(errors_only)
        self.assertIn("alpha::never started", rendered_errors_only)
        self.assertNotIn("No failed tests", rendered_errors_only)

        # An unrecognized status is a protocol violation and must also
        # reach the page rather than being silently dropped.
        weird = json.loads(json.dumps(doc))
        weird["tests"][1]["status"] = "BANANA"
        rendered_weird = self.render_failed_tests_section(weird)
        self.assertIn("alpha::fails", rendered_weird)
        self.assertIn("BANANA", rendered_weird)

        # Only an entirely clean run may say so.
        clean = json.loads(json.dumps(doc))
        clean["tests"] = [t for t in clean["tests"] if t["status"] == "PASS"]
        self.assertIn("No failed tests", self.render_failed_tests_section(clean))

        # The excerpt column must survive a per-case failure, whose
        # `stdout` is empty by construction (a `--run` child registers no
        # console formatter, so it prints nothing). Before this, the
        # column rendered blank for exactly those failures.
        per_case = {
            "status": "FAIL",
            "qualified_name": "alpha::fails",
            "checkpoints": ["t_x.nim(9, 12): Check failed: 1 == 2", "1 was 1"],
            "exception": None,
            "stdout": "",
        }
        self.assertIn("Check failed: 1 == 2", inventory.failure_excerpt(per_case))

    def test_static_inventory_covers_every_declared_test(self):
        data = self.inventory_data()
        self.assert_nde0a_catalog_preserves_real_cross_platform_and_linux_coverage(
            data
        )
        self.assert_linux_darwin_catalog_delta_is_exact(data)
        self.assert_nim_case_counter_lexes_declarations_not_fixture_text()
        self.assert_nim_case_counter_accepts_compiler_backed_statement_forms()
        self.assert_nim_case_counter_resolves_only_imported_unittest_receivers()
        self.assert_nim_case_counter_rejects_compiler_rejected_operator_endings()
        self.assert_inventory_case_counts_pin_multiline_and_fixture_regressions(data)
        self.assert_runtime_compiler_flow_inventory(data)
        nim_specs, python_specs = inventory.parse_repro_tests(REPO_ROOT)
        declarations = (REPO_ROOT / "repro_tests.nim").read_text(encoding="utf-8")
        declared_nim_count = len(
            re.findall(r"(?m)^\s*TestSpec\(\s*$", declarations)
        )
        python_block = re.search(
            r"const\s+pythonTestPaths\*:\s*seq\[string\]\s*=\s*@\[(.*?)\]",
            declarations,
            re.S,
        )
        self.assertIsNotNone(python_block)
        declared_python_count = len(
            re.findall(r'(?m)^\s*"[^"]+\.py",?\s*$', python_block.group(1))
        )
        # Exact checked-in graph specification counts, read textually from
        # repro_tests.nim. This is an independent reading of the same
        # generated file as the parse_repro_tests pins above, so a dropped,
        # duplicated, or hand-edited specification fails here too.
        # Same +1 (upstream) / +4 (this branch) split as the
        # parse_repro_tests pin above; see the comment there.
        # 1204 -> 1207 for M2 step 2's three new test sources, each pinned
        # individually in `expected_m2_step2_sources`.
        # 1208 -> 1209 for the daemon accept-loop survival regression,
        # pinned individually in `expected_enrollments`.
        # 1209 -> 1210 for the M2 step-1 catalog-selection regression,
        # pinned individually in `expected_enrollments`.
        # 1210 -> 1212 for the two integration sources the workspace-CLI
        # verb split (`0b9205f7`) added, each pinned individually in
        # `expected_enrollments`; its six renames net to zero and are
        # pinned there too.
        # 4 -> 5: `tests/unit/test_package_root_anchor.py`, the
        # package-root-anchor guard added with the nim-fork bump to 4e93a8a4.
        # 1212 -> 1213: the one source this change adds,
        # `t_protocol_document_survives_suite_body_echo.nim`.
        # 1213 -> 1220: the six one-case develop sources from `b2dabbc96` and
        # the one-case SHA-pinned-manifest regression from `6b342175e`, listed
        # beside the parsed-spec aggregate assertion above.
        # 1220 -> 1225: the five one-case develop regressions from upstream
        # `391a892a4`, pinned individually in `expected_enrollments` above.
        # Four recovered graph enrollments plus fail-closed: 1225 -> 1230;
        # upstream 11cea6789 then adds six: 1236. The linked-worktree source
        # is the one new generated graph entry, producing 1237.
        # 1237 -> 1239: the `develop --all` post-condition source and the
        # recovered `t_branch_fork_clones_root_submodules.nim`, both pinned
        # individually beside the parsed-spec aggregate above.
        self.assertEqual(declared_nim_count, 1239)
        self.assertEqual(declared_python_count, 5)
        self.assertEqual(len(nim_specs), declared_nim_count)
        self.assertEqual(len(python_specs), declared_python_count)
        for enrolled in (
            "recipes/packages/source/dejavu-fonts/"
            "test_dejavu_fonts_source.nim",
            "recipes/packages/source/font-util/test_font_util_source.nim",
            "recipes/packages/source/libpciaccess/"
            "test_libpciaccess_source.nim",
            "recipes/packages/source/util-macros/test_util_macros_source.nim",
            "recipes/packages/source/xorg-server/test_xorg_server_source.nim",
            "recipes/packages/source/grub/test_grub_source.nim",
            "tests/integration/"
            "t_branch_forks_new_workspace_on_feature_branch.nim",
        ):
            with self.subTest(enrolled_source=enrolled):
                self.assertIn(enrolled, {spec.source for spec in nim_specs})
        self.assertEqual(
            len({spec.source for spec in nim_specs}), declared_nim_count
        )
        self.assertEqual(
            len({spec.binary for spec in nim_specs}), declared_nim_count
        )
        self.assertTrue(
            all((REPO_ROOT / spec.source).is_file() for spec in nim_specs + python_specs)
        )
        self.assertEqual(
            data["static"]["testEntryCount"],
            declared_nim_count + declared_python_count,
        )
        # 1211 -> 1212: the one new Nim spec above (1208 nim + 4 python).
        # 1212 -> 1213: the daemon accept-loop survival regression
        # (1209 nim + 4 python).
        # 1213 -> 1214: the M2 step-1 catalog-selection regression
        # (1210 nim + 4 python).
        #
        # 1214 -> 1217 = 1212 nim + 5 python: +2 nim for the sources
        # `0b9205f7` added (its six renames net to zero), +1 python for the
        # package-root-anchor guard.
        # 1217 -> 1218 = 1213 nim + 5 python: the one new nim source.
        # 1218 -> 1225 = 1220 nim + 5 python: the seven develop sources above.
        # 1225 -> 1230 = 1225 nim + 5 python: upstream `391a892a4`'s five
        # additional, individually pinned develop sources.
        # The recovered graph enrollments plus fail-closed move 1230 -> 1235;
        # upstream 11cea6789's six pinned sources move 1235 -> 1241.
        # The linked-worktree regression then adds one Nim entry.
        # The linked-worktree regression then adds one Nim entry: 1242.
        # Final graph: 1239 Nim + 5 Python = 1244 entries — the two sources
        # the graph regeneration enrols.
        self.assertEqual(data["static"]["testEntryCount"], 1244)
        self.assertEqual(len(data["tests"]), data["static"]["testEntryCount"])
        self.assertEqual(
            sum(data["static"]["classificationCounts"].values()),
            data["static"]["testEntryCount"],
        )
        self.assertTrue(data["staticallyDetectedRuntimeCompilerFlows"])
        self.assertTrue(data["pureUnitConsolidationCandidates"])
        self.assertTrue(data["static"]["graphOwnedTestArtifacts"])
        self.assertFalse(data["timing"]["complete"])
        self.assertFalse(data["slowTestReview"]["complete"])
        self.assertEqual(data["slowTestReview"]["candidateCount"], 0)
        self.assertGreater(
            data["slowTestReview"]["retainedDiagnosticReviewCount"], 0
        )
        self.assertEqual(
            data["performanceAssessment"]["status"],
            "structural-inference-only",
        )
        self.assertIsNone(
            data["performanceAssessment"]["measured"]["coldRunMs"]
        )
        self.assertEqual(
            data["performanceAssessment"]["measured"]["warmRunMs"], []
        )
        self.assertIsNone(
            data["performanceAssessment"]["measured"]["speedupFactor"]
        )
        report = inventory.render_report(data, inventory.DEFAULT_JSON.as_posix())
        self.assertIn("structural inventory and correctness facts only", report)
        self.assertIn("No numeric speedup is claimed", report)
        self.assertIn("Deferred empirical command", report)
        tests_by_source = {item["source"]: item for item in data["tests"]}
        for group in data["pureUnitConsolidationCandidates"]:
            self.assertTrue(
                all(tests_by_source[source]["language"] == "nim" for source in group["sources"])
            )
            self.assertTrue(
                all(
                    tests_by_source[source]["localDependencyShape"]
                    == group["dependencyShape"]
                    for source in group["sources"]
                )
            )
            if group["owner"] == "tests/unit":
                self.assertTrue(group["dependencyShape"])
        helper_sources = {
            item["source"] for item in data["staticallyDetectedRuntimeCompilerFlows"]
        }
        self.assertIn(
            "tests/integration/t_stackable_hooks_extracted_process_tree.nim",
            helper_sources,
        )
        self.assertIn(
            "tests/e2e/io-monitor/t_debug_io_monitor_reads_monitor_depfile.nim",
            helper_sources,
        )
        self.assertIn(
            "tests/unit/t_m9r13a_provider_compile_sharing.nim", helper_sources
        )
        self.assertIn(
            "tests/unit/t_m9r14f_2_rpath_patching.nim", helper_sources
        )
        self.assertIn(
            "tests/integration/t_e2e_cross_compilation_aarch64.nim",
            helper_sources,
        )
        self.assertIn(
            "libs/repro_home_apply/tests/t_builtin_adapter_installer.nim",
            helper_sources,
        )
        self.assertIn(
            "tests/integration/t_ti2_separate_module_producer.nim",
            helper_sources,
        )
        self.assertIn(
            "tests/integration/t_ti2_thin_interface_consumer_reads_cached_artifact.nim",
            helper_sources,
        )
        self.assertNotIn(
            "tests/e2e/codetracer-subset/t_e2e_codetracer_dev_environment_slice.nim",
            helper_sources,
        )

    def test_compiler_detection_tracks_transitive_command_composition(self):
        compile_fragment = "c " + "--compileOnly --hints:off"
        executor = "execCmd" + "Ex"
        source = f"""
proc compileFixture() =
  let nimExe = findExe("nim")
  let compileVerb =
    if false:
      "check --hints:off"
    else:
      "{compile_fragment}"
  let cmd = nimExe & " " & compileVerb & " fixture.nim"
  discard {executor}("cd /tmp && " & cmd)
"""
        matches = inventory.compiler_invocations("tests/integration/example.nim", source)
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["patterns"], ["nim-compile-verb"])
        self.assertEqual(matches[0]["assignedCommandVariable"], "compileVerb")
        self.assertTrue(matches[0]["commandVariableExecuted"])
        self.assert_runtime_compiler_api_detection_resolves_imports_and_wrappers()
        self.assert_runtime_compiler_api_detection_rejects_non_runtime_text()

    def assert_runtime_compiler_api_detection_resolves_imports_and_wrappers(self):
        source = r'''
import std/unittest
import repro_interface_artifacts as artifacts
from repro_profile_compile import compileProfileBinary

proc providerLeaf() =
  artifacts.compileProviderBinary()

proc providerMiddle() =
  providerLeaf()

suite "runtime compiler API detector":
  test "follows module aliases, selective imports, and local call closure":
    providerMiddle()
    compileProfileBinary()
'''
        compiled = self.run_nim_fixture(
            source,
            run=True,
            companions={
                "repro_interface_artifacts.nim": r'''
proc compileProviderBinary*() =
  discard
''',
                "repro_profile_compile.nim": r'''
proc compileProfileBinary*() =
  discard
''',
            },
        )
        self.assertEqual(compiled.returncode, 0, compiled.stdout)
        self.assertEqual(compiled.stdout.count("[OK]"), 1, compiled.stdout)
        matches = inventory.nim_runtime_compiler_api_invocations(
            "tests/integration/example.nim", source
        )
        self.assertEqual(
            [item["runtimeCompilerApi"] for item in matches],
            ["compileProviderBinary", "compileProfileBinary"],
        )
        self.assertEqual(matches[0]["enclosingCallable"], "providerLeaf")
        self.assertTrue(matches[0]["callableReachable"])
        self.assertEqual(matches[1]["enclosingCallable"], "")

    def assert_runtime_compiler_api_detection_rejects_non_runtime_text(self):
        source = r'''
import std/unittest
import repro_interface_artifacts as artifacts

const generatedFixture = """
import repro_interface_artifacts
discard compileProviderBinary()
"""

# artifacts.extractInterfaceFromModule()
proc unusedWrapper() =
  artifacts.extractInterfaceFromModule()

static:
  artifacts.compileProviderBinary()

when false:
  artifacts.liftInterfaceArtifact()

suite "runtime compiler API detector negatives":
  test "fixture text and unreachable declarations are not runtime flows":
    check generatedFixture.len > 0
'''
        compiled = self.run_nim_fixture(
            source,
            run=True,
            companions={
                "repro_interface_artifacts.nim": r'''
proc compileProviderBinary*() =
  discard
proc extractInterfaceFromModule*() =
  discard
proc liftInterfaceArtifact*() =
  discard
''',
            },
        )
        self.assertEqual(compiled.returncode, 0, compiled.stdout)
        self.assertEqual(compiled.stdout.count("[OK]"), 1, compiled.stdout)
        self.assertEqual(
            inventory.nim_runtime_compiler_api_invocations(
                "tests/integration/example.nim", source
            ),
            [],
        )

        unrelated = r'''
import unrelated_compiler
proc wrapper() =
  compileProviderBinary()
wrapper()
'''
        unrelated_checked = self.run_nim_fixture(
            unrelated,
            command="check",
            companions={
                "unrelated_compiler.nim": r'''
proc compileProviderBinary*() =
  discard
''',
            },
        )
        self.assertEqual(
            unrelated_checked.returncode, 0, unrelated_checked.stdout
        )
        self.assertEqual(
            inventory.nim_runtime_compiler_api_invocations(
                "tests/integration/unrelated.nim", unrelated
            ),
            [],
        )

        shadowed = r'''
import repro_profile_compile
proc compileProfileBinary() =
  discard
compileProfileBinary()
'''
        self.assertEqual(
            inventory.nim_runtime_compiler_api_invocations(
                "tests/integration/shadowed.nim", shadowed
            ),
            [],
        )

    def assert_nde0a_catalog_preserves_real_cross_platform_and_linux_coverage(
        self, data
    ):
        """NDE0-A enumerates real host coverage instead of a zero-case stub.

        The Debian archive/layout cases are intentionally Linux-only.  The
        recipe registry assertions are pure DSL behavior and must remain real
        cases on every supported host.  Pin both sets by exact catalog name:
        on Darwin this proves the binary did not merely gain a protocol
        sentinel, while Linux CI proves all archive cases still build and
        enumerate rather than being traded away to repair the Darwin count.
        """
        source = "libs/repro_dsl_stdlib/tests/t_nde0a_apt_jammy.nim"
        entry = next(item for item in data["tests"] if item["source"] == source)

        dsl_names = {
            "NDE0-A apt-jammy DSL surface::"
            "recipe registers exactly one version via the DSL versions: block",
            "NDE0-A apt-jammy DSL surface::"
            "recorded version string matches AptJammyAdapterVersion constant",
            "NDE0-A apt-jammy DSL surface::"
            "recorded version carries the snapshot pin as sourceRevision",
        }
        linux_names = {
            "NDE0-A apt-jammy adapter::"
            "sha256 verification: matching sha succeeds",
            "NDE0-A apt-jammy adapter::"
            "sha256 verification: wrong sha raises AptVerifyError",
            "NDE0-A apt-jammy adapter::"
            "content-addressed store path: different debs → different paths",
            "NDE0-A apt-jammy adapter::"
            "content-addressed store path: same deb twice → same path",
            "NDE0-A apt-jammy adapter::"
            "expectedFiles failure: missing entry raises AptExpectedFileMissing",
            "NDE0-A apt-jammy adapter::"
            "expectedFiles success: present entry produces output",
            "NDE0-A apt-jammy adapter::"
            "installSystemdUnit: normalises lib/systemd/system/ -> "
            "usr/lib/systemd/system/",
            "NDE0-A apt-jammy adapter::"
            "determinism: extract same deb twice into separate roots → "
            "byte-identical trees",
            "NDE0-A apt-jammy adapter::"
            "fingerprint composition: install hash is order-independent",
            "NDE0-A apt-jammy adapter::"
            "fingerprint composition: install hash changes when snapshot changes",
            "NDE0-A apt-jammy adapter::"
            "extractFingerprint: changes with sha256, stable with same sha256",
        }
        expected_names = dsl_names | linux_names if sys.platform.startswith(
            "linux"
        ) else dsl_names

        self.assertEqual(entry["countSource"], "catalog")
        self.assertEqual(entry["sourceSuiteCount"], 2)
        self.assertEqual(entry["staticCaseCount"], 14)
        self.assertEqual(entry["sourceCaseCount"], len(expected_names))
        self.assertEqual(
            {case["name"] for case in entry["catalogCases"]}, expected_names
        )
        self.assertNotIn(
            source,
            {item["source"] for item in data["catalogEnumeration"]["quarantine"]},
        )

    def platform_gated_test_sources(self, data):
        """Find enrolled sources whose platform gate owns a real test.

        This uses the inventory's Nim lexer and declaration resolver, so
        comments, fixture strings, and unrelated platform-specific helpers do
        not turn into census entries.  A complete ``when``/``elif``/``else``
        chain is considered because a platform condition can select a test in
        its fallback branch.
        """

        def next_non_newline(tokens, position):
            position += 1
            while position < len(tokens) and tokens[position].kind == "newline":
                position += 1
            return position

        def mentions_linux_or_macos(tokens):
            for position, token in enumerate(tokens):
                if not inventory.nim_identifier_matches(token, "defined"):
                    continue
                value = next_non_newline(tokens, position)
                if value < len(tokens) and tokens[value].value == "(":
                    value = next_non_newline(tokens, value)
                if value < len(tokens) and (
                    inventory.nim_identifier_matches(tokens[value], "linux")
                    or inventory.nim_identifier_matches(tokens[value], "macosx")
                ):
                    return True
            return False

        def branch(tokens, depths, header):
            base_depth = depths[header]
            colon = header + 1
            while colon < len(tokens):
                if tokens[colon].value == ":" and depths[colon] == base_depth:
                    break
                colon += 1
            if colon == len(tokens):
                return None
            body = inventory.nim_next_token(tokens, colon)
            if body is None:
                return None
            end = len(tokens)
            for position in range(body + 1, len(tokens)):
                token = tokens[position]
                if (
                    token.kind != "newline"
                    and token.line > tokens[body].line
                    and token.column <= tokens[header].column
                    and depths[position] == base_depth
                ):
                    end = position
                    break
            return colon, body, end

        result = set()
        for item in data["tests"]:
            if item["language"] != "nim":
                continue
            source = item["source"]
            tokens = inventory.nim_tokens(
                (REPO_ROOT / source).read_text(encoding="utf-8", errors="replace")
            )
            depths = inventory.nim_outer_depths(tokens)
            test_tokens = {
                (declaration.token.line, declaration.token.column)
                for declaration in inventory.nim_declarations(tokens)
                if declaration.kind == "test"
            }
            for header, token in enumerate(tokens):
                if not (
                    inventory.nim_identifier_matches(token, "when")
                    or inventory.nim_identifier_matches(token, "elif")
                ):
                    continue
                current = branch(tokens, depths, header)
                if current is None or not mentions_linux_or_macos(
                    tokens[header + 1 : current[0]]
                ):
                    continue
                chain_has_test = False
                while current is not None:
                    _, body, end = current
                    chain_has_test = chain_has_test or any(
                        (tokens[position].line, tokens[position].column)
                        in test_tokens
                        for position in range(body, end)
                    )
                    if end == len(tokens) or not (
                        inventory.nim_identifier_matches(tokens[end], "elif")
                        or inventory.nim_identifier_matches(tokens[end], "else")
                    ):
                        break
                    current = branch(tokens, depths, end)
                if chain_has_test:
                    result.add(source)
                    break
        return result

    def assert_linux_darwin_catalog_delta_is_exact(self, data):
        """Pin every qualified identity that differs between Linux and Darwin.

        These are the complete source-scoped symmetric differences from real
        catalogs built at the same revision on both hosts.  Most are honest
        real-case/sentinel swaps and therefore cardinality-neutral.  The six
        asymmetric sources explain the aggregate exactly: NDE0-A contributes
        eleven extra Linux cases; loopback and stackable hooks contribute one
        each; SIP launch, FHS stubs, and watch contribute four, two, and a net
        six extra Darwin cases.  The resulting Linux total is exactly one
        greater -- it is not a stale host-independent pin.

        A lexer-derived census below covers all nineteen enrolled sources in
        which a Linux/macOS gate owns a real test declaration.  Four gates
        select the same catalog on both hosts; the remaining fifteen are
        exactly the keys of ``exclusive``.  This distinction keeps a new
        gated source from hiding behind a cardinality-neutral catalog swap.
        """
        if sys.platform.startswith("linux"):
            host = "linux"
        elif sys.platform == "darwin":
            host = "darwin"
        else:
            # This invariant describes the two hosts that publish the exact
            # suite totals below.  Other hosts retain the aggregate guard and
            # their own platform-specific catalog assertions.
            return

        exclusive = {
            "libs/repro_build_engine/tests/"
            "t_engine_macos_sip_safe_launch.nim": {
                "linux": set(),
                "darwin": {
                    "Portable-Macos-Sandbox-Tools B1: macOS SIP-safe "
                    "monitored launch::fail-safe: monitored action fails when "
                    "no non-SIP shell is resolvable",
                    "Portable-Macos-Sandbox-Tools B1: macOS SIP-safe "
                    "monitored launch::positive: monitored action launches "
                    "via a non-SIP wrapper shell",
                    "Portable-Macos-Sandbox-Tools B1: macOS SIP-safe "
                    "monitored launch::resolveNonSipShell never returns a "
                    "SIP-protected shell",
                    "Portable-Macos-Sandbox-Tools B1: macOS SIP-safe "
                    "monitored launch::resolveNonSipShell prefers the "
                    "CT_SANDBOX_TOOLS_DIR drop-in",
                },
            },
            "libs/repro_dsl_stdlib/tests/t_nde0a_apt_jammy.nim": {
                "linux": {
                    "NDE0-A apt-jammy adapter::content-addressed store path: "
                    "different debs → different paths",
                    "NDE0-A apt-jammy adapter::content-addressed store path: "
                    "same deb twice → same path",
                    "NDE0-A apt-jammy adapter::determinism: extract same deb "
                    "twice into separate roots → byte-identical trees",
                    "NDE0-A apt-jammy adapter::expectedFiles failure: missing "
                    "entry raises AptExpectedFileMissing",
                    "NDE0-A apt-jammy adapter::expectedFiles success: present "
                    "entry produces output",
                    "NDE0-A apt-jammy adapter::extractFingerprint: changes "
                    "with sha256, stable with same sha256",
                    "NDE0-A apt-jammy adapter::fingerprint composition: "
                    "install hash changes when snapshot changes",
                    "NDE0-A apt-jammy adapter::fingerprint composition: "
                    "install hash is order-independent",
                    "NDE0-A apt-jammy adapter::installSystemdUnit: normalises "
                    "lib/systemd/system/ -> usr/lib/systemd/system/",
                    "NDE0-A apt-jammy adapter::sha256 verification: matching "
                    "sha succeeds",
                    "NDE0-A apt-jammy adapter::sha256 verification: wrong sha "
                    "raises AptVerifyError",
                },
                "darwin": set(),
            },
            "libs/repro_elevation/tests/t_m2_nixos_darwin_modules.nim": {
                "linux": {
                    "Dotfiles-Migration-Completion M2 — "
                    "macos.darwinSystemModule::observe + apply raise "
                    "ENotImplementedPlatform off-macOS"
                },
                "darwin": {
                    "Dotfiles-Migration-Completion M2 — "
                    "linux.nixosSystemModule::observe + apply raise "
                    "ENotImplementedPlatform off-Linux"
                },
            },
            "libs/repro_elevation/tests/"
            "t_sandbox_m1_fhssandbox_driver.nim": {
                "linux": set(),
                "darwin": {
                    "Linux-Third-Party-Sandbox-MVP M1 — off-platform "
                    "stubs::destroy raises ENotImplementedPlatform off-Linux",
                    "Linux-Third-Party-Sandbox-MVP M1 — off-platform "
                    "stubs::observe + apply raise ENotImplementedPlatform "
                    "off-Linux",
                },
            },
            "tests/e2e/hcr-debug-unwind/"
            "t_e2e_hcr_direct_patch_debug_unwind_replay.nim": {
                "linux": {
                    "e2e_hcr_direct_patch_debug_unwind_replay::M28 "
                    "debug/unwind/replay gate is macOS arm64-only"
                },
                "darwin": {
                    "e2e_hcr_direct_patch_debug_unwind_replay::direct patch "
                    "registers debugger and unwind metadata and replays IPC "
                    "bytes"
                },
            },
            "tests/e2e/hcr-direct-linker/"
            "t_e2e_hcr_in_target_link_and_trampoline.nim": {
                "linux": {
                    "e2e_hcr_in_target_link_and_trampoline::M27 real direct "
                    "trampoline gate is macOS arm64-only"
                },
                "darwin": {
                    "e2e_hcr_in_target_link_and_trampoline::shared direct-HCR "
                    "transaction applies to fake and real target process"
                },
            },
            "tests/e2e/macos-monitor/"
            "t_macos_monitor_shim_event_taxonomy.nim": {
                "linux": {
                    "e2e_macos_monitor_shim_event_taxonomy::macOS monitor shim "
                    "event taxonomy is unsupported on non-macOS"
                },
                "darwin": {
                    "e2e_macos_monitor_shim_event_taxonomy::real macOS shim "
                    "records supported taxonomy and structured gaps"
                },
            },
            "tests/e2e/watch/t_e2e_repro_watch.nim": {
                "linux": {
                    "e2e_repro_watch::event-driven watch E2E is macOS "
                    "kqueue-only in M31"
                },
                "darwin": {
                    "e2e_repro_watch::CodeTracer copied checkout watch builds "
                    "added frontend public resource",
                    "e2e_repro_watch::CodeTracer copied checkout watch "
                    "rebuilds selected C action only",
                    "e2e_repro_watch::CodeTracer copied checkout watch "
                    "rebuilds selected app aggregate",
                    "e2e_repro_watch::CodeTracer copied checkout watch "
                    "rebuilds selected frontend aggregate",
                    "e2e_repro_watch::local project no-target watch uses "
                    "current project default action",
                    "e2e_repro_watch::local project watch rebuilds selected "
                    "target from depfile event",
                    "e2e_repro_watch::local project watch reruns provider root "
                    "after enumerated directory add",
                },
            },
            "tests/integration/"
            "t_integration_hcr_linkgraph_relocation_classification.nim": {
                "linux": {
                    "integration_hcr_linkgraph_relocation_classification::M26 "
                    "Mach-O arm64 gate is macOS-only"
                },
                "darwin": {
                    "integration_hcr_linkgraph_relocation_classification::"
                    "Mach-O arm64 objects produce LinkGraph facts, diffs, "
                    "relocation classes, and pure plans"
                },
            },
            "tests/integration/t_m9r22b_2_apply_loopback.nim": {
                "linux": {
                    "M9.R.22b.2: loopback end-to-end (Linux, --loopback "
                    "gated)::Test#5 (loopback): simple-ext4 against a 1G image"
                },
                "darwin": set(),
            },
            "tests/integration/"
            "t_stackable_hooks_extracted_process_tree.nim": {
                "linux": {
                    "integration_stackable_hooks_extracted_process_tree::"
                    "linux preload runtime dispatches registered hooks in "
                    "priority order"
                },
                "darwin": set(),
            },
            "tests/integration/"
            "t_cache_daemon_drains_dedups_persists_and_warms_from_disk.nim": {
                "linux": {
                    "integration_cache_daemon_drains_dedups_persists_and_warms_from_disk::"
                    "pinned origin dev peer interoperates in both directions"
                },
                "darwin": {
                    "integration_cache_daemon_drains_dedups_persists_and_warms_from_disk::"
                    "Darwin v1 and v2 peers isolate volatile state and share Tier-1"
                },
            },
            "tests/unit/t_hcr_agent_process_target.nim": {
                "linux": {
                    "HCR process target runtime::process target runtime is "
                    "macOS arm64-only"
                },
                "darwin": {
                    "HCR process target runtime::agent runtime patches "
                    "executable memory in the current process"
                },
            },
            "tests/unit/t_m9r14f_2_rpath_patching.nim": {
                "linux": {
                    "DSL-port M9.R.14f.2 — install-mirror RPATH patching::"
                    "linux_end_to_end_patchelf_against_synthetic_elf"
                },
                "darwin": {
                    "DSL-port M9.R.14f.2 — install-mirror RPATH patching::"
                    "non_linux_host_documents_runtime_skip"
                },
            },
            "tests/unit/t_m9r15q_5_rpath_nix_stub_deps.nim": {
                "linux": {
                    "DSL-port M9.R.15q.5.1 — RPATH resolution for nix-stub "
                    "deps::linux_end_to_end_rpath_excludes_dangling_includes_real"
                },
                "darwin": {
                    "DSL-port M9.R.15q.5.1 — RPATH resolution for nix-stub "
                    "deps::non_linux_host_documents_runtime_skip_q5"
                },
            },
        }

        catalog_identical = {
            "tests/e2e/codetracer-subset/"
            "t_e2e_codetracer_in_place_project_file.nim",
            "tests/e2e/local-build-engine/"
            "t_e2e_local_reprobuild_project_build.nim",
            "tests/e2e/watch/t_e2e_repro_watch_multiple_named_targets.nim",
            "tests/integration/"
            "t_integration_scheduler_dependency_gathering_policies.nim",
        }
        gated_sources = self.platform_gated_test_sources(data)
        self.assertEqual(gated_sources, set(exclusive) | catalog_identical)
        self.assertEqual(len(exclusive), 15)
        self.assertEqual(len(catalog_identical), 4)

        by_source = {item["source"]: item for item in data["tests"]}
        for source, expected_by_host in exclusive.items():
            all_platform_names = (
                expected_by_host["linux"] | expected_by_host["darwin"]
            )
            actual_names = {
                case["name"] for case in by_source[source]["catalogCases"]
            }
            self.assertEqual(
                actual_names & all_platform_names,
                expected_by_host[host],
                source,
            )

        linux_only = sum(len(item["linux"]) for item in exclusive.values())
        darwin_only = sum(len(item["darwin"]) for item in exclusive.values())
        self.assertEqual((linux_only, darwin_only), (23, 22))
        self.assertEqual(linux_only - darwin_only, 1)

    def test_completed_clean_attempt_requires_one_coherent_three_run_attempt(self):
        fingerprint = "same-source"
        timing = {
            "sourceFingerprint": fingerprint,
            "runs": [
                {
                    "attemptIndex": 4,
                    "attemptKind": "clean",
                    "cleanFirst": True,
                    "label": label,
                    "exitCode": 0,
                    "timedOut": False,
                    "elapsedMs": 1000 + index,
                    "summaryJson": f"evidence/{label}.json",
                    "summarySha256": f"{index + 1:064x}",
                    "sourceFingerprint": fingerprint,
                    "runnerSummary": {
                        "summary": {
                            "total": 10,
                            "passed": 10,
                            "failed": 0,
                            "skipped": 0,
                        }
                    },
                }
                for index, label in enumerate(
                    ["clean-cold", "clean-warm-1", "clean-warm-2"]
                )
            ],
        }
        self.assertEqual(inventory.completed_clean_attempt(timing), 4)
        self.assertEqual(
            inventory.measured_timing(timing),
            {
                "coldRunMs": 1000,
                "warmRunMs": [1001, 1002],
                "speedupFactor": round(1000 / 1002, 3),
            },
        )

        def clone():
            return json.loads(json.dumps(timing))

        rejected = clone()
        rejected["runs"][0].pop("runnerSummary")
        self.assertIsNone(inventory.completed_clean_attempt(rejected))

        rejected = clone()
        rejected["runs"][2]["sourceFingerprint"] = "different-source"
        self.assertIsNone(inventory.completed_clean_attempt(rejected))

        for field, value in [
            ("exitCode", 1),
            ("timedOut", True),
        ]:
            with self.subTest(field=field):
                rejected = clone()
                rejected["runs"][1][field] = value
                self.assertIsNone(inventory.completed_clean_attempt(rejected))

        for summary_update in [
            {"passed": 9, "failed": 1},
            {"passed": 9, "skipped": 1},
        ]:
            with self.subTest(summary_update=summary_update):
                rejected = clone()
                rejected["runs"][1]["runnerSummary"]["summary"].update(
                    summary_update
                )
                self.assertIsNone(inventory.completed_clean_attempt(rejected))

        rejected = clone()
        rejected["runs"][2]["attemptIndex"] = 5
        self.assertIsNone(inventory.completed_clean_attempt(rejected))

        for missing in ["elapsedMs", "summaryJson", "summarySha256"]:
            with self.subTest(missing=missing):
                rejected = clone()
                rejected["runs"][2].pop(missing)
                self.assertIsNone(inventory.completed_clean_attempt(rejected))

        rejected = clone()
        rejected["runs"].append(json.loads(json.dumps(rejected["runs"][2])))
        self.assertIsNone(inventory.completed_clean_attempt(rejected))

    def test_timed_runs_force_and_record_live_benchmark_policy(self):
        captured_environments = []

        def fake_run_logged_command(
            root, command, log_path, timeout_seconds, env=None
        ):
            self.assertIsNotNone(env)
            captured_environments.append(dict(env))
            return 0, False

        with tempfile.TemporaryDirectory(prefix="repro-m0-live-policy-") as tmp:
            root = Path(tmp)
            with (
                mock.patch.object(
                    inventory, "source_fingerprint", return_value="same-source"
                ),
                mock.patch.object(
                    inventory,
                    "run_logged_command",
                    side_effect=fake_run_logged_command,
                ),
                mock.patch.object(
                    inventory, "external_source_checkouts", return_value={}
                ),
            ):
                timing = inventory.run_suite(
                    root,
                    warm_runs=2,
                    clean_first=False,
                    timeout_seconds=60,
                )

        self.assertEqual(len(captured_environments), 3)
        self.assertTrue(
            all(env["REPROBUILD_BENCH_LIVE"] == "1"
                for env in captured_environments)
        )
        self.assertNotIn("REPROBUILD_TEST_WARM_REUSE", captured_environments[0])
        self.assertEqual(captured_environments[1]["REPROBUILD_TEST_WARM_REUSE"], "1")
        self.assertEqual(captured_environments[2]["REPROBUILD_TEST_WARM_REUSE"], "1")
        self.assertEqual(len(timing["runs"]), 3)
        for run in timing["runs"]:
            self.assertEqual(
                run["environment"]["REPROBUILD_BENCH_LIVE"], "1"
            )

    def test_slow_reviews_require_exact_authoritative_final_warm_provenance(self):
        fingerprint = "measured-source"
        summary_hash = "a" * 64
        timing = {
            "sourceFingerprint": fingerprint,
            "currentSourceFingerprint": fingerprint,
            "runs": [
                {
                    "attemptIndex": 7,
                    "attemptKind": "clean",
                    "cleanFirst": True,
                    "label": label,
                    "exitCode": 0,
                    "timedOut": False,
                    "elapsedMs": 2000 + index,
                    "summaryJson": f"evidence/{label}.json",
                    "summarySha256": summary_hash if index == 2 else f"{index + 1:064x}",
                    "sourceFingerprint": fingerprint,
                    "runnerSummary": {
                        "summary": {
                            "total": 1,
                            "passed": 1,
                            "failed": 0,
                            "skipped": 0,
                        }
                    },
                }
                for index, label in enumerate(
                    ["clean-cold", "clean-warm-1", "clean-warm-2"]
                )
            ],
        }
        review = {
            "classification": "runtime compilation",
            "justification": "The production compiler path is the contract.",
            "followUp": "Move reusable setup into a graph-owned artifact.",
        }
        with tempfile.TemporaryDirectory(prefix="repro-m0-reviews-") as tmp:
            root = Path(tmp)
            review_path = root / inventory.DEFAULT_SLOW_REVIEWS
            review_path.parent.mkdir(parents=True)

            def write_review(provenance):
                review_path.write_text(
                    json.dumps(
                        {
                            "schema": "reprobuild.test-suite-m0-slow-review.v2",
                            "provenance": provenance,
                            "reviews": {"slow_case": review},
                        }
                    ),
                    encoding="utf-8",
                )

            write_review(
                {
                    "measurementStatus": "diagnostic-only",
                    "sourceFingerprint": None,
                }
            )
            self.assertFalse(inventory.slow_review_provenance_matches(root, timing))
            self.assertEqual(inventory.authoritative_slow_reviews(root, timing), {})

            exact = {
                "measurementStatus": "authoritative",
                "sourceFingerprint": fingerprint,
                "attemptIndex": 7,
                "summaryLabel": "clean-warm-2",
                "summaryJson": "evidence/clean-warm-2.json",
                "summarySha256": summary_hash,
            }
            write_review(exact)
            self.assertTrue(inventory.slow_review_provenance_matches(root, timing))
            self.assertEqual(
                inventory.authoritative_slow_reviews(root, timing),
                {"slow_case": review},
            )

            for field, value in [
                ("sourceFingerprint", "stale-source"),
                ("attemptIndex", 6),
                ("summaryLabel", "clean-warm-1"),
                ("summaryJson", "evidence/other.json"),
                ("summarySha256", "b" * 64),
            ]:
                with self.subTest(field=field):
                    stale = dict(exact)
                    stale[field] = value
                    write_review(stale)
                    self.assertFalse(
                        inventory.slow_review_provenance_matches(root, timing)
                    )
                    self.assertEqual(
                        inventory.authoritative_slow_reviews(root, timing), {}
                    )

    def test_source_fingerprint_survives_evidence_commit_but_tracks_source(self):
        with tempfile.TemporaryDirectory(prefix="repro-m0-fingerprint-") as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "tester@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "M0 Tester"], cwd=root, check=True
            )
            (root / "source.txt").write_text("one\n", encoding="utf-8")
            subprocess.run(["git", "add", "source.txt"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "seed"], cwd=root, check=True)

            first = inventory.source_fingerprint(root)
            report = root / inventory.DEFAULT_REPORT
            report.parent.mkdir(parents=True)
            report.write_text("generated\n", encoding="utf-8")
            json_path = root / inventory.DEFAULT_JSON
            json_path.write_text(json.dumps({"generated": True}), encoding="utf-8")
            reviews_path = root / inventory.DEFAULT_SLOW_REVIEWS
            reviews_path.write_text(json.dumps({"reviews": {}}), encoding="utf-8")
            self.assertEqual(first, inventory.source_fingerprint(root))

            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "record generated evidence"],
                cwd=root,
                check=True,
            )
            self.assertEqual(first, inventory.source_fingerprint(root))

            source_path = root / "source.txt"
            source_path.chmod(0o755)
            self.assertNotEqual(first, inventory.source_fingerprint(root))
            source_path.chmod(0o644)
            self.assertEqual(first, inventory.source_fingerprint(root))

            source_path.write_text("two\n", encoding="utf-8")
            self.assertNotEqual(first, inventory.source_fingerprint(root))

            source_path.unlink()
            deleted_before_commit = inventory.source_fingerprint(root)
            subprocess.run(["git", "add", "-u"], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "delete source"], cwd=root, check=True
            )
            self.assertEqual(
                deleted_before_commit, inventory.source_fingerprint(root)
            )

    def test_completed_attempt_is_stale_when_current_source_changes(self):
        fingerprint = "measured-source"
        timing = {
            "sourceFingerprint": fingerprint,
            "currentSourceFingerprint": "changed-source",
            "runs": [
                {
                    "attemptIndex": 1,
                    "attemptKind": "clean",
                    "cleanFirst": True,
                    "label": label,
                    "exitCode": 0,
                    "timedOut": False,
                    "sourceFingerprint": fingerprint,
                }
                for label in ["clean-cold", "clean-warm-1", "clean-warm-2"]
            ],
        }
        self.assertIsNone(inventory.completed_clean_attempt(timing))

    def test_missing_warm_summary_never_completes_slow_review_gate(self):
        data = self.inventory_data()
        self.assertFalse(data["timing"]["complete"])
        self.assertEqual(data["runnerSummaries"], [])
        self.assertEqual(data["slowTestReview"]["candidateCount"], 0)
        self.assertFalse(data["slowTestReview"]["complete"])

    def test_external_source_metadata_records_exact_checkout_revisions(self):
        with tempfile.TemporaryDirectory(prefix="repro-m0-external-") as tmp:
            workspace = Path(tmp)
            expected: dict[str, str] = {}
            for name in [
                "codetracer",
                "isonim",
                "nim-shm-gset",
                "nim-stackable-hooks",
            ]:
                root = workspace / name
                root.mkdir()
                subprocess.run(["git", "init", "-q"], cwd=root, check=True)
                subprocess.run(
                    ["git", "config", "user.email", "tester@example.invalid"],
                    cwd=root,
                    check=True,
                )
                subprocess.run(
                    ["git", "config", "user.name", "M0 Tester"],
                    cwd=root,
                    check=True,
                )
                source_root = root / "src"
                source_root.mkdir()
                (source_root / "source.txt").write_text(
                    name + "\n", encoding="utf-8"
                )
                subprocess.run(["git", "add", "src/source.txt"], cwd=root, check=True)
                subprocess.run(["git", "commit", "-qm", "seed"], cwd=root, check=True)
                expected[name] = subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=root, text=True
                ).strip()

            with mock.patch.dict(
                os.environ,
                {
                    "CODETRACER_ROOT": str(workspace / "codetracer"),
                    "CODETRACER_SRC": str(workspace / "codetracer" / "src"),
                    "CODETRACER_TEST_ISONIM_ROOT": str(workspace / "isonim"),
                    "SHM_GSET_SRC": str(workspace / "nim-shm-gset" / "src"),
                    "STACKABLE_HOOKS_SRC": str(
                        workspace / "nim-stackable-hooks" / "src"
                    ),
                },
                clear=False,
            ):
                metadata = inventory.runtime_metadata()

            self.assertEqual(
                metadata["sourceCheckouts"]["codetracer"]["head"],
                expected["codetracer"],
            )
            self.assertEqual(
                metadata["sourceCheckouts"]["isonim"]["head"],
                expected["isonim"],
            )
            self.assertEqual(
                metadata["sourceCheckouts"]["nim-shm-gset"]["head"],
                expected["nim-shm-gset"],
            )
            self.assertEqual(
                metadata["sourceCheckouts"]["nim-stackable-hooks"]["head"],
                expected["nim-stackable-hooks"],
            )
            self.assertFalse(metadata["sourceCheckouts"]["codetracer"]["dirty"])
            self.assertEqual(
                metadata["environment"]["CODETRACER_ROOT"],
                str(workspace / "codetracer"),
            )
            self.assertEqual(
                metadata["environment"]["CODETRACER_TEST_ISONIM_ROOT"],
                str(workspace / "isonim"),
            )

            # Where those values END UP. `runtime_metadata` still records
            # the exact revisions and the exact environment — that is what
            # the assertions above pin and it is unchanged. What changed is
            # the destination: the absolute paths (`environment` values,
            # `sourceCheckouts[*].path`) are build-local, while the
            # revisions survive into the tracked artifact WITHOUT paths.
            #
            # Asserted here rather than left to the split's own test,
            # because this is the test that knows what the values are.
            document = {
                "metadata": {"runtime": metadata},
                "tests": [],
                "catalogEnumeration": {},
            }
            tracked, detail = inventory.split_case_catalog(
                document, inventory.DEFAULT_CASE_CATALOG
            )
            self.assertEqual(
                detail["runtime"]["environment"]["CODETRACER_ROOT"],
                str(workspace / "codetracer"),
            )
            self.assertEqual(
                detail["runtime"]["sourceCheckouts"]["codetracer"]["head"],
                expected["codetracer"],
            )
            self.assertNotIn("runtime", tracked["metadata"])
            revisions = tracked["metadata"]["sourceCheckoutRevisions"]
            for name in ("codetracer", "isonim", "nim-shm-gset",
                         "nim-stackable-hooks"):
                with self.subTest(revision=name):
                    self.assertEqual(revisions[name]["head"], expected[name])
                    self.assertNotIn("path", revisions[name])
            self.assertNotIn(
                str(workspace), json.dumps(tracked, sort_keys=True)
            )


if __name__ == "__main__":
    unittest.main()
