#!/usr/bin/env python3
import json
import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


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
        import re

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
        names = [r["name"] for r in records]

        for record in records:
            self.assertEqual(set(record), {"name", "unit", "value", "extra"})
            self.assertIsInstance(record["value"], (int, float))

        def has(fragment):
            return any(fragment in n for n in names)

        self.assertTrue(has("interface mode"), names)
        self.assertTrue(has("full mode"), names)
        self.assertTrue(has("provider session round-trip (cold"), names)
        self.assertTrue(has("provider session round-trip (warm"), names)
        self.assertTrue(has("consumer build (cold"), names)
        self.assertTrue(has("consumer build (warm"), names)


if __name__ == "__main__":
    unittest.main()
