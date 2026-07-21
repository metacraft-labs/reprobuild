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
        self.assertTrue(data["helperCompilationInTestBody"])
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
            item["source"] for item in data["helperCompilationInTestBody"]
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
