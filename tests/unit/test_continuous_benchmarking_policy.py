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

    def test_benchmark_workflow_follows_metacraft_policy(self):
        workflow = (ROOT / ".github" / "workflows" / "benchmark.yml").read_text()

        self.assertIn("branches: [main]", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn('runner: \'["self-hosted", "benchmark"]\'', workflow)
        self.assertIn('runner: \'["self-hosted", "macos"]\'', workflow)
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


if __name__ == "__main__":
    unittest.main()
