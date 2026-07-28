#!/usr/bin/env python3
import json
import math
import os
import re
import subprocess
import unittest
from copy import deepcopy
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

EXPECTED_COMPOSITION_METRICS = [
    (
        "Reprobuild rp1: provider compile time "
        "(interface mode: thin interface extract)",
        "ms",
        "rp1",
        "rp1-provider-compile.json",
    ),
    (
        "Reprobuild rp1: provider compile time "
        "(full mode: provider binary compile)",
        "ms",
        "rp1",
        "rp1-provider-compile.json",
    ),
    (
        "Reprobuild rp2: provider session round-trip "
        "(cold: launch+handshake+invoke)",
        "ms",
        "rp2",
        "rp2-provider-session.json",
    ),
    (
        "Reprobuild rp2: provider session round-trip "
        "(warm: reused session invoke)",
        "ms",
        "rp2",
        "rp2-provider-session.json",
    ),
    (
        "Reprobuild rp3: consumer build "
        "(cold: materialize+launch shared dependency provider)",
        "ms",
        "rp3",
        "rp3-consumer-build.json",
    ),
    (
        "Reprobuild rp3: consumer build "
        "(warm: reuse shared dependency session)",
        "ms",
        "rp3",
        "rp3-consumer-build.json",
    ),
    (
        "Reprobuild rp3: shared dependency provider launches "
        "across all consumer builds",
        "count",
        "rp3",
        "rp3-consumer-build.json",
    ),
]


def parse_metric_extra(extra):
    metadata = {}
    for item in extra.split("; "):
        key, separator, value = item.partition("=")
        if not separator or not key or key in metadata:
            raise AssertionError(f"invalid metric metadata field: {item!r}")
        metadata[key] = value
    return metadata


def assert_exact_composition_metrics(test_case, records):
    test_case.assertIsInstance(records, list)
    test_case.assertEqual(len(records), len(EXPECTED_COMPOSITION_METRICS))
    test_case.assertEqual(
        [record.get("name") for record in records],
        [expected[0] for expected in EXPECTED_COMPOSITION_METRICS],
    )

    for record, (name, unit, suite, source) in zip(
        records, EXPECTED_COMPOSITION_METRICS
    ):
        test_case.assertEqual(set(record), {"name", "unit", "value", "extra"})
        test_case.assertEqual(record["name"], name)
        test_case.assertEqual(record["unit"], unit)
        test_case.assertIsInstance(record["value"], (int, float))
        test_case.assertNotIsInstance(record["value"], bool)
        test_case.assertTrue(math.isfinite(record["value"]))
        test_case.assertIsInstance(record["extra"], str)

        metadata = parse_metric_extra(record["extra"])
        test_case.assertEqual(
            set(metadata),
            {
                "quick",
                "suite",
                "direction",
                "status",
                "providerArtifactId",
                "source",
            },
        )
        test_case.assertEqual(metadata["quick"], "true")
        test_case.assertEqual(metadata["suite"], suite)
        test_case.assertEqual(metadata["direction"], "lower-is-better")
        test_case.assertEqual(metadata["status"], "measured")
        test_case.assertNotIn(metadata["providerArtifactId"], {"", "unknown"})
        test_case.assertEqual(metadata["source"], source)

    test_case.assertEqual(records[6]["value"], 1)


def assert_observed_rp3_launch_derivation(test_case, source):
    witnesses = [
        "let launchesBeforeCold = pool.launchCount",
        "let launchesAfterCold = pool.launchCount",
        "let coldLaunches = launchesAfterCold - launchesBeforeCold",
        "let launchesAfterWarm = pool.launchCount",
        "let warmLaunches = launchesAfterWarm - launchesAfterCold",
        "if launchesBeforeCold != 0 or coldLaunches != 2:",
        "if launchesAfterWarm != 3 or warmLaunches != 1:",
        "let sharedDependencyLaunches = coldLaunches - warmLaunches",
        "if sharedDependencyLaunches != 1:",
        "warmDependencyHandle.session != coldDependencyHandle.session",
        "observedDependencyArtifactId != dep.artifactId",
        "warmDependencyHandle.providerArtifactId != observedDependencyArtifactId",
        '"providerArtifactId": observedDependencyArtifactId',
        '"dependencyProviderArtifactId": dep.artifactId',
        '"value": sharedDependencyLaunches',
    ]
    for witness in witnesses:
        test_case.assertIn(witness, source)
    test_case.assertIsNone(
        re.search(r"\blet\s+sharedDependencyLaunches\s*=\s*1\b", source)
    )


class ContinuousBenchmarkingPolicyTests(unittest.TestCase):
    def test_collector_emits_policy_json_and_report_for_m0_suite(self):
        env = os.environ.copy()
        env["REPROBUILD_BENCH_SUITES"] = "m0"
        result = subprocess.run(
            ["bash", "scripts/collect-benchmark-metrics.sh", "--quick"],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

        records = json.loads(result.stdout)

        self.assertGreaterEqual(len(records), 3)
        for record in records:
            self.assertEqual(set(record), {"name", "unit", "value", "extra"})
            self.assertIsInstance(record["name"], str)
            self.assertIsInstance(record["unit"], str)
            self.assertIsInstance(record["value"], (int, float))
            self.assertIsInstance(record["extra"], str)
        self.assertTrue((ROOT / "bench-results" / "report.html").exists())
        self.assertIn("running Reprobuild M0 benchmark suite", result.stderr)

    def test_collector_wires_cross_repo_benchmark_suites(self):
        script = (ROOT / "scripts" / "collect-benchmark-metrics.sh").read_text()

        self.assertIn("REPROBUILD_BENCH_SUITES", script)
        self.assertIn("run-m23-benchmark.sh", script)
        self.assertIn("run-cmake-generator-competitiveness-benchmark.sh", script)
        self.assertIn("append_benchmark_metrics bench-results/reprobuild-core-mvp-performance.json m23", script)
        self.assertIn('append_benchmark_metrics "${output}" cmake', script)
        self.assertIn('run-m23-benchmark.sh "${args[@]}" >&2', script)
        self.assertIn('run-cmake-generator-competitiveness-benchmark.sh "${args[@]}" >&2', script)
        self.assertIn("ratioSummary", script)

    def test_collector_wires_composition_benchmark_suites(self):
        # RP7 close-out: the collector must wire ALL composition suites, not
        # just the m0/m23/cmake cross-repo suites. Each composition suite must
        # be in the default suite list, have its run_<suite>_suite defined and
        # invoked, and be handled by append_benchmark_metrics.
        script = (ROOT / "scripts" / "collect-benchmark-metrics.sh").read_text()

        composition_suites = ["rp1", "rp2", "rp3", "rp5b", "ti1", "ti3"]

        # Default suite list contains every composition suite.
        match = re.search(
            r'benchmark_suites="\$\{REPROBUILD_BENCH_SUITES:-([^}"]+)\}"', script
        )
        self.assertIsNotNone(
            match, "could not find default benchmark_suites assignment"
        )
        default_suites = match.group(1).split(",")
        for suite in composition_suites:
            self.assertIn(
                suite, default_suites, f"{suite} missing from default suite list"
            )

        for suite in composition_suites:
            self.assertIn(
                f"run_{suite}_suite() {{",
                script,
                f"run_{suite}_suite not defined",
            )
            # Defined AND invoked (guarded by suite_enabled).
            self.assertIn(f"suite_enabled {suite}; then", script)
            self.assertIn(
                f"  run_{suite}_suite",
                script,
                f"run_{suite}_suite not invoked",
            )

        # append_benchmark_metrics handles each composition kind. rp1/rp2/rp3/
        # rp5b/ti1/ti3 share the rp1-shaped parser branch.
        self.assertIn(
            'kind in ("rp1", "rp2", "rp3", "rp5b", "ti1", "ti3")', script
        )
        for suite in composition_suites:
            self.assertIn(
                f'append_benchmark_metrics "${{output}}" {suite}',
                script,
                f"append_benchmark_metrics not called for {suite}",
            )

    def test_composition_gate_metrics_are_wired(self):
        # RP7 close-out: the specific gate METRICS named by the milestone must
        # be emitted by the composition harnesses so the customSmallerIsBetter
        # regression gate actually guards them:
        #   - RP1 provider-compile-time: INTERFACE mode vs FULL mode.
        #   - RP2 provider-session round-trip: WARM and COLD.
        #   - RP3 cold-vs-warm consumer build.
        # Asserted structurally (against the harness sources) so the unit test
        # stays fast; a live `just bench --quick` JSON check lives in the
        # separate slow path below.
        bench = ROOT / "benchmarks" / "lib"

        rp1 = (bench / "rp1_provider_compile_bench.nim").read_text()
        self.assertIn('"suite": "rp1"', rp1)
        self.assertIn("interface mode", rp1)
        self.assertIn("full mode", rp1)

        rp2 = (bench / "rp2_provider_session_bench.nim").read_text()
        self.assertIn('"suite": "rp2"', rp2)
        self.assertIn("provider session round-trip (cold", rp2)
        self.assertIn("provider session round-trip (warm", rp2)

        rp3 = (bench / "rp3_consumer_build_bench.nim").read_text()
        self.assertIn('"suite": "rp3"', rp3)
        self.assertIn("consumer build (cold", rp3)
        self.assertIn("consumer build (warm", rp3)
        assert_observed_rp3_launch_derivation(self, rp3)

        # Exercise the exact live-record validator cheaply as part of the
        # default policy module, so schema/value hardening does not depend on
        # source-text assertions or an opt-in benchmark run.
        valid_records = []
        for index, (name, unit, suite, source) in enumerate(
            EXPECTED_COMPOSITION_METRICS
        ):
            value = 1 if index == 6 else float(index + 1)
            valid_records.append(
                {
                    "name": name,
                    "unit": unit,
                    "value": value,
                    "extra": (
                        f"quick=true; suite={suite}; "
                        "direction=lower-is-better; status=measured; "
                        f"providerArtifactId=fixture-{suite}; source={source}"
                    ),
                }
            )
        assert_exact_composition_metrics(self, valid_records)

        mutations = [
            ("removed seventh record", lambda records: records.pop()),
            (
                "changed seventh record",
                lambda records: records[6].update(name="unrelated metric"),
            ),
            ("boolean value", lambda records: records[0].update(value=True)),
            ("NaN value", lambda records: records[0].update(value=float("nan"))),
            (
                "infinite value",
                lambda records: records[0].update(value=float("inf")),
            ),
            ("wrong unit", lambda records: records[6].update(unit="ms")),
            (
                "extra record field",
                lambda records: records[0].update(unexpected="field"),
            ),
            (
                "wrong quick metadata",
                lambda records: records[0].update(
                    extra=records[0]["extra"].replace(
                        "quick=true", "quick=false"
                    )
                ),
            ),
            (
                "wrong suite metadata",
                lambda records: records[0].update(
                    extra=records[0]["extra"].replace("suite=rp1", "suite=rp3")
                ),
            ),
            (
                "wrong direction",
                lambda records: records[0].update(
                    extra=records[0]["extra"].replace(
                        "direction=lower-is-better", "direction=higher-is-better"
                    )
                ),
            ),
            (
                "wrong status",
                lambda records: records[0].update(
                    extra=records[0]["extra"].replace(
                        "status=measured", "status=estimated"
                    )
                ),
            ),
            (
                "unknown provider artifact",
                lambda records: records[0].update(
                    extra=records[0]["extra"].replace(
                        "providerArtifactId=fixture-rp1",
                        "providerArtifactId=unknown",
                    )
                ),
            ),
            (
                "wrong source metadata",
                lambda records: records[0].update(
                    extra=records[0]["extra"].replace(
                        "source=rp1-provider-compile.json",
                        "source=unrelated.json",
                    )
                ),
            ),
            ("wrong launch count", lambda records: records[6].update(value=2)),
        ]
        for label, mutate in mutations:
            with self.subTest(mutation=label):
                mutated = deepcopy(valid_records)
                mutate(mutated)
                with self.assertRaises(AssertionError):
                    assert_exact_composition_metrics(self, mutated)

        hardcoded = rp3.replace(
            "let sharedDependencyLaunches = coldLaunches - warmLaunches",
            "let sharedDependencyLaunches = 1",
        )
        with self.assertRaises(AssertionError):
            assert_observed_rp3_launch_derivation(self, hardcoded)
        hardcoded_output = rp3.replace(
            '"value": sharedDependencyLaunches',
            '"value": 1',
        )
        with self.assertRaises(AssertionError):
            assert_observed_rp3_launch_derivation(self, hardcoded_output)

    def test_benchmark_workflow_follows_metacraft_policy(self):
        workflow = (ROOT / ".github" / "workflows" / "benchmark.yml").read_text()

        self.assertIn("branches: [main]", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn(
            'runner: \'["self-hosted", "Linux", "X64", "benchmark"]\'', workflow
        )
        self.assertIn('runner: \'["eph-macos-arm64"]\'', workflow)
        self.assertIn("metacraft-labs/runquota", workflow)
        self.assertIn("metacraft-labs/reprobuild-cmake", workflow)
        self.assertIn("ref: reprobuild", workflow)
        self.assertIn("run: nix develop --command just bench --quick", workflow)
        self.assertIn("benchmark-action/github-action-benchmark@v1", workflow)
        self.assertIn("tool: customSmallerIsBetter", workflow)
        self.assertIn("auto-push: false", workflow)
        self.assertIn("save-data-file: false", workflow)
        self.assertIn("comment-always: true", workflow)
        self.assertIn("auto-push: true", workflow)
        self.assertIn("gh-pages-branch: gh-pages", workflow)
        self.assertIn("benchmark-data-dir-path: perf/bench/", workflow)
        self.assertIn("alert-threshold: '120%'", workflow)

    def test_agents_lists_available_benchmark_targets(self):
        agents = (ROOT / "AGENTS.md").read_text()

        for target in [
            "just bench",
            "just bench --quick",
            "just bench-quick",
            "just bench_reprobuild_core_mvp_performance",
            "just bench_cmake_reprobuild_vs_ninja",
            "just bench_cmake_reprobuild_vs_ninja_quick",
            "just bench_cmake_reprobuild_vs_ninja_medium",
        ]:
            self.assertIn(target, agents)


@unittest.skipUnless(
    os.environ.get("REPROBUILD_BENCH_LIVE") == "1",
    "live composition-bench run is slow; set REPROBUILD_BENCH_LIVE=1 to enable",
)
class ContinuousBenchmarkingLiveGateTests(unittest.TestCase):
    def test_quick_run_emits_composition_gate_metrics(self):
        # Slow path: actually run the composition suites and assert the gate
        # metrics land in the collector JSON as customSmallerIsBetter records.
        env = os.environ.copy()
        env["REPROBUILD_BENCH_SUITES"] = "rp1,rp2,rp3"
        result = subprocess.run(
            ["bash", "scripts/collect-benchmark-metrics.sh", "--quick"],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        records = json.loads(result.stdout)
        assert_exact_composition_metrics(self, records)

        rp3 = json.loads(
            (ROOT / "bench-results" / "rp3-consumer-build.json").read_text()
        )
        self.assertEqual(set(rp3), {"schema", "metadata", "metrics"})
        self.assertEqual(
            rp3["schema"], "reprobuild.rp3-consumer-build-bench.v1"
        )
        self.assertEqual(
            set(rp3["metadata"]),
            {
                "quick",
                "warmRuns",
                "launchesBeforeCold",
                "launchesAfterCold",
                "launchesAfterWarm",
                "coldLaunches",
                "warmLaunches",
                "providerArtifactId",
                "dependencyProviderArtifactId",
            },
        )
        self.assertIs(rp3["metadata"]["quick"], True)
        for field in [
            "warmRuns",
            "launchesBeforeCold",
            "launchesAfterCold",
            "launchesAfterWarm",
            "coldLaunches",
            "warmLaunches",
        ]:
            self.assertIsInstance(rp3["metadata"][field], int)
            self.assertNotIsInstance(rp3["metadata"][field], bool)
        self.assertEqual(rp3["metadata"]["warmRuns"], 3)
        self.assertEqual(rp3["metadata"]["launchesBeforeCold"], 0)
        self.assertEqual(rp3["metadata"]["launchesAfterCold"], 2)
        self.assertEqual(rp3["metadata"]["launchesAfterWarm"], 3)
        self.assertEqual(rp3["metadata"]["coldLaunches"], 2)
        self.assertEqual(rp3["metadata"]["warmLaunches"], 1)
        self.assertEqual(
            rp3["metadata"]["providerArtifactId"],
            rp3["metadata"]["dependencyProviderArtifactId"],
        )
        self.assertIsInstance(rp3["metadata"]["providerArtifactId"], str)
        self.assertIsInstance(
            rp3["metadata"]["dependencyProviderArtifactId"], str
        )
        self.assertNotEqual(rp3["metadata"]["providerArtifactId"], "")

        self.assertEqual(len(rp3["metrics"]), 3)
        expected_rp3 = EXPECTED_COMPOSITION_METRICS[4:]
        for metric, (collector_name, unit, suite, _) in zip(
            rp3["metrics"], expected_rp3
        ):
            self.assertEqual(
                set(metric),
                {"suite", "name", "unit", "value", "direction", "status"},
            )
            self.assertEqual(metric["suite"], suite)
            self.assertEqual(
                f"Reprobuild {suite}: {metric['name']}", collector_name
            )
            self.assertEqual(metric["unit"], unit)
            self.assertIsInstance(metric["value"], (int, float))
            self.assertNotIsInstance(metric["value"], bool)
            self.assertTrue(math.isfinite(metric["value"]))
            self.assertEqual(metric["direction"], "lower-is-better")
            self.assertEqual(metric["status"], "measured")

        observed_shared_launches = (
            rp3["metadata"]["coldLaunches"] - rp3["metadata"]["warmLaunches"]
        )
        self.assertEqual(observed_shared_launches, 1)
        self.assertIsInstance(rp3["metrics"][2]["value"], int)
        self.assertNotIsInstance(rp3["metrics"][2]["value"], bool)
        self.assertEqual(rp3["metrics"][2]["value"], observed_shared_launches)


if __name__ == "__main__":
    unittest.main()
