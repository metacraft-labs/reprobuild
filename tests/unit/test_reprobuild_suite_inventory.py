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
        expected_multiline_counts = {
            "libs/repro_cli_support/tests/test_engine_publisher_wiring.nim": 5,
            "libs/repro_profile_compile/tests/t_template_in_template_named_args.nim": 2,
            "libs/repro_standard_provider/tests/test_examples_layout.nim": 1,
            "tests/e2e/m72/t_integration_stow_non_destructive_over_existing.nim": 4,
            "tests/e2e/m76/t_integration_stow_byte_identical_target_is_cache_hit.nim": 4,
            "tests/e2e/m79/t_integration_shell_integration_replan_idempotent.nim": 1,
            "tests/e2e/m83/t_e2e_profile_modules.nim": 6,
        }
        for source, expected in expected_multiline_counts.items():
            with self.subTest(source=source):
                self.assertEqual(by_source[source]["sourceCaseCount"], expected)

        # The three test files added while this scanner change was in review
        # contribute five real cases. The exact-destination ref-validation
        # change contributes one more case in its existing source. Pin each
        # source independently so aggregate drift cannot be accepted by merely
        # updating the totals below.
        expected_rebased_source_counts = {
            "libs/repro_cli_support/tests/t_daemon_carried_environment.nim": 5,
            "libs/repro_resources/tests/"
            "t_attr_missing_interface_diagnostic.nim": 1,
            "libs/repro_resources/tests/t_attr_ssz_envelope_roundtrip.nim": 3,
            "tests/integration/t_d6_runner_test_timeout.nim": 3,
            "tests/integration/t_extension_type_lifted_and_consumed.nim": 1,
            "tests/integration/t_local_daemons_control_plane_m10.nim": 5,
            "tests/integration/t_pre_push_protocol_v2_ref_validation.nim": 3,
            "tests/integration/"
            "t_repro_test_runner_process_group_cleanup.nim": 8,
        }
        for source, expected in expected_rebased_source_counts.items():
            with self.subTest(source=source):
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
        nim_specs, _ = inventory.parse_repro_tests(REPO_ROOT)
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
        self.assertEqual(nim_total, 6501)
        self.assertEqual(python_total, 31)
        self.assertEqual(data["static"]["sourceCaseCount"], 6532)

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
        # so adding 46 + 21 directly would double count them.
        cleanup_source = (
            "tests/integration/"
            "t_repro_test_runner_process_group_cleanup.nim"
        )
        self.assertIn(cleanup_source, explicit_sources)
        self.assertEqual(len(explicit_sources), 46)
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
        self.assertEqual(derived_total, 64)
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
        cases = {
            "invalid": 1,
            "0": 1,
            "1": 1,
            "2": 1,
            "7": 3,
            "8": 4,
            "23": 4,
            "24": 8,
            "32": 8,
            "64": 8,
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

    def test_static_inventory_covers_every_declared_test(self):
        data = inventory.build_inventory(REPO_ROOT, None)
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
        self.assertEqual(len(nim_specs), declared_nim_count)
        self.assertEqual(len(python_specs), declared_python_count)
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
        data = inventory.build_inventory(REPO_ROOT, None)
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


if __name__ == "__main__":
    unittest.main()
