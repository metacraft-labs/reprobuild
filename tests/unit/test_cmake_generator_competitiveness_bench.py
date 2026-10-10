#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "cmake_generator_competitiveness_bench.py"

spec = importlib.util.spec_from_file_location("cmake_generator_competitiveness_bench", SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class StatsParserTests(unittest.TestCase):
    def test_parse_ninja_stats_metrics(self):
        output = """[1/1] Linking app
metric           count   avg (us)        total (ms)
.ninja parse     1       1189.0          1.2
node stat        37      4.2             0.2
StartEdge        3       16.7            0.1
"""

        stats = bench.parse_ninja_stats(output)

        self.assertEqual(
            stats,
            {
                "metrics": [
                    {"name": ".ninja parse", "count": 1, "avgUs": 1189.0, "totalMs": 1.2},
                    {"name": "node stat", "count": 37, "avgUs": 4.2, "totalMs": 0.2},
                    {"name": "StartEdge", "count": 3, "avgUs": 16.7, "totalMs": 0.1},
                ]
            },
        )

    def test_parse_reprobuild_stats_metrics(self):
        output = """buildReport: /tmp/repro/build-report.json
metric                               count   avg (us)        total (ms)
repro provider compile                   1   12450.5        12.5
repro process wait                       2    9900.0        19.8
repro scheduler total                    1   25100.0        25.1
"""

        stats = bench.parse_reprobuild_stats(output)

        self.assertEqual(
            stats,
            {
                "metrics": [
                    {"name": "repro provider compile", "count": 1, "avgUs": 12450.5, "totalMs": 12.5},
                    {"name": "repro process wait", "count": 2, "avgUs": 9900.0, "totalMs": 19.8},
                    {"name": "repro scheduler total", "count": 1, "avgUs": 25100.0, "totalMs": 25.1},
                ]
            },
        )

    def test_build_command_passes_native_args_after_separator(self):
        command = bench.build_command("cmake", "build-dir", "all", 4, ["-d", "stats"])

        self.assertEqual(
            command,
            ["cmake", "--build", "build-dir", "--target", "all", "--parallel", "4", "--", "-d", "stats"],
        )

    def test_direct_ninja_build_command_uses_native_tool_shape(self):
        command = bench.direct_ninja_build_command(
            "ninja", "build-dir", "all", 4, ["-d", "stats"])

        self.assertEqual(
            command,
            ["ninja", "-C", "build-dir", "-j", "4", "-d", "stats", "all"],
        )

    def test_direct_reprobuild_build_command_targets_generated_provider(self):
        command = bench.direct_reprobuild_build_command(
            "repro", "build-dir", "genbench", "stats")

        self.assertEqual(
            command,
            [
                "repro",
                "build",
                "build-dir#genbench",
                "--tool-provisioning=path",
                "--work-root=build-dir/CMakeFiles/reprobuild",
                "--show=timing",
            ],
        )

    def test_ratio_records_execution_mode(self):
        record = bench.ratio_record(
            "demo", "noop_rebuild", "direct",
            {"wallMs": 10.0}, {"wallMs": 25.0})

        self.assertEqual(record["executionMode"], "direct")
        self.assertEqual(record["ratioReprobuildToNinja"], 2.5)

    def test_repeated_result_uses_median_wall_time_and_summary(self):
        samples = iter([
            {"wallMs": 30.0, "label": "slow"},
            {"wallMs": 10.0, "label": "fast"},
            {"wallMs": 20.0, "label": "median"},
        ])

        result = bench.repeated_result(lambda: next(samples), 3)

        self.assertEqual(result["label"], "median")
        self.assertEqual(result["wallMs"], 20.0)
        self.assertEqual(result["timingSamples"], [30.0, 10.0, 20.0])
        self.assertEqual(
            result["timingSummary"],
            {
                "runs": 3,
                "firstWallMs": 30.0,
                "bestWallMs": 10.0,
                "medianWallMs": 20.0,
                "worstWallMs": 30.0,
                "meanWallMs": 20.0,
            },
        )

    def test_selected_execution_modes_expands_both(self):
        self.assertEqual(
            bench.selected_execution_modes("both"),
            ["cmake-driver", "direct"],
        )

    def test_header_incremental_source_uses_project_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            source_dir = Path(tmp)
            self.assertIsNone(bench.header_incremental_source("unknown", source_dir))
            header = source_dir / "zlib.h"
            header.write_text("/* test header */\n")
            self.assertEqual(
                bench.header_incremental_source("zlib", source_dir),
                header,
            )


def write_stats_record(stats_dir, name, project_root, actions=None,
                       exit_code=0, wall_ms=100.0):
    record = {
        "pid": 1,
        "projectRoot": project_root,
        "wallMs": wall_ms,
        "exitCode": exit_code,
        "fastPath": "tier2a-trycompile-direct",
        "metrics": [],
    }
    if actions is not None:
        record["actions"] = actions
    (Path(stats_dir) / f"{name}.json").write_text(
        json.dumps(record), encoding="utf-8")


CONFIGURE_LOG = """---
events:
  -
    kind: "message-v1"
    message: |
      The C compiler identification is GNU
  -
    kind: "try_compile-v1"
    checks:
      - "Detecting C compiler ABI info"
    directories:
      source: "C:/b/CMakeFiles/CMakeScratch/TryCompile-aaa111"
      binary: "C:/b/CMakeFiles/CMakeScratch/TryCompile-aaa111"
    buildResult:
      variable: "CMAKE_C_ABI_COMPILED"
  -
    kind: "try_compile-v1"
    checks:
      - "Looking for sys/types.h"
    directories:
      source: "C:/b/CMakeFiles/CMakeScratch/TryCompile-bbb222"
      binary: "C:/b/CMakeFiles/CMakeScratch/TryCompile-bbb222"
...
"""


class CrossProjectReuseTests(unittest.TestCase):
    def test_parse_cross_project_pair(self):
        self.assertEqual(bench.parse_cross_project_pair("zlib:libuv"),
                         ("zlib", "libuv"))
        for bad in ("zlib", "zlib:", ":libuv", "a:b:c"):
            with self.assertRaises(RuntimeError):
                bench.parse_cross_project_pair(bad)

    def test_default_pairs_follow_the_profile_unless_given(self):
        self.assertEqual(bench.default_cross_project_pairs("medium", None),
                         [("zlib", "libuv")])
        self.assertEqual(bench.default_cross_project_pairs("quick", None), [])
        self.assertEqual(
            bench.default_cross_project_pairs("quick", ["fmt:nlohmann_json"]),
            [("fmt", "nlohmann_json")])

    def test_configure_log_maps_scratch_dirs_to_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "CMakeConfigureLog.yaml"
            log.write_text(CONFIGURE_LOG, encoding="utf-8")
            checks = bench.parse_configure_log_checks(log)
        self.assertEqual(checks, {
            "c:/b/cmakefiles/cmakescratch/trycompile-aaa111":
                "Detecting C compiler ABI info",
            "c:/b/cmakefiles/cmakescratch/trycompile-bbb222":
                "Looking for sys/types.h",
        })

    def test_trycompile_summary_counts_only_trycompile_invocations(self):
        with tempfile.TemporaryDirectory() as tmp:
            stats = Path(tmp) / "stats"
            stats.mkdir()
            log = Path(tmp) / "CMakeConfigureLog.yaml"
            log.write_text(CONFIGURE_LOG, encoding="utf-8")
            # Served entirely from the cache.
            write_stats_record(
                stats, "1", "C:\\b\\CMakeFiles\\CMakeScratch\\TryCompile-bbb222",
                {"total": 2, "launched": 0, "cacheHit": 2, "failed": 0})
            # The compile hit, the link ran; then a probe that failed.
            write_stats_record(
                stats, "2", "C:/b/CMakeFiles/CMakeScratch/TryCompile-ccc333",
                {"total": 2, "launched": 1, "cacheHit": 1, "failed": 0})
            write_stats_record(
                stats, "3", "C:/b/CMakeFiles/CMakeScratch/TryCompile-aaa111",
                {"total": 1, "launched": 1, "cacheHit": 0, "failed": 1},
                exit_code=1)
            # The main project's own invocation is not a TryCompile.
            write_stats_record(
                stats, "4", "C:/b",
                {"total": 5, "launched": 5, "cacheHit": 0, "failed": 0})

            summary = bench.summarize_trycompile_stats(stats, log)

        self.assertEqual(summary["invocations"], 3)
        self.assertEqual(summary["failedInvocations"], 1)
        self.assertEqual(summary["actions"], 5)
        self.assertEqual(summary["cacheHitActions"], 3)
        self.assertEqual(summary["launchedActions"], 2)
        self.assertEqual(summary["failedActions"], 1)
        self.assertEqual(summary["invocationsServedFromCache"], 1)
        self.assertEqual(summary["hitRate"], 0.6)
        self.assertEqual(
            [probe["check"] for probe in summary["executedProbes"]],
            ["(unknown check)", "Detecting C compiler ABI info"])

    def test_trycompile_summary_refuses_to_guess_without_a_tally(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_stats_record(
                tmp, "1", "C:/b/CMakeFiles/CMakeScratch/TryCompile-aaa111")
            summary = bench.summarize_trycompile_stats(tmp)
        self.assertEqual(summary["invocations"], 1)
        self.assertIsNone(summary["hitRate"])
        self.assertIn("hitRateUnavailable", summary)

    def test_cross_project_env_points_every_cache_at_the_store_root(self):
        base = {
            "PATH": "p",
            "REPROBUILD_ACTION_CACHE_ROOT": "C:/warm-cache",
            "REPROBUILD_STORE_ROOT": "C:/user-store",
        }
        env = bench.cross_project_env(base, "repro", "C:/fresh", "C:/stats")
        self.assertEqual(env["REPROBUILD_STORE_ROOT"], "C:/fresh")
        self.assertEqual(env["REPRO_STATS_DIR"], "C:/stats")
        self.assertNotIn("REPROBUILD_ACTION_CACHE_ROOT", env)
        self.assertEqual(env["REPRO_DAEMON"], "off")
        self.assertEqual(
            bench.cross_project_env({"REPRO_DAEMON": "auto"}, "repro", "s",
                                    "t")["REPRO_DAEMON"], "auto")

    def test_one_sample_primes_a_shared_store_and_keeps_the_baseline_empty(self):
        calls = []

        def fake_configure(cmake, ninja, generator, source, binary_dir, cc,
                           cxx, install_prefix, configure_args, env=None):
            calls.append({
                "project": Path(source).parent.name,
                "store": env["REPROBUILD_STORE_ROOT"],
                "generator": generator,
                "args": configure_args,
            })
            return {"wallMs": 10.0, "status": "succeeded",
                    "commandLine": "cmake"}

        with tempfile.TemporaryDirectory() as tmp:
            sources = Path(tmp) / "sources"
            for key in ("liba", "libb"):
                (sources / key).mkdir(parents=True)
                (sources / key / "CMakeLists.txt").write_text("")
            context = {"cmake": "cmake", "ninja": "ninja", "repro": "repro",
                       "cCompiler": "cc", "cxxCompiler": "c++"}
            sample = bench.run_cross_project_once(
                context, Path(tmp) / "run-1",
                {"key": "liba", "sourceDir": sources / "liba",
                 "configureArgs": ["-DA=1"]},
                {"key": "libb", "sourceDir": sources / "libb",
                 "configureArgs": ["-DB=1"]},
                configure=fake_configure)

        self.assertEqual([c["project"] for c in calls],
                         ["b-cold", "a-prime", "b-warm"])
        self.assertEqual([c["args"] for c in calls],
                         [["-DB=1"], ["-DA=1"], ["-DB=1"]])
        self.assertTrue(all(c["generator"] == "Reprobuild" for c in calls))
        self.assertTrue(calls[0]["store"].endswith("store-empty"))
        self.assertTrue(calls[1]["store"].endswith("store-shared"))
        self.assertEqual(calls[1]["store"], calls[2]["store"])
        self.assertEqual(sample["primeA"]["project"], "liba")
        self.assertEqual(sample["warmB"]["project"], "libb")

    def test_summary_reports_hit_rate_and_saving_with_spread(self):
        def side(wall_ms, hits, actions):
            return {"wallMs": wall_ms, "tryCompile": {
                "invocations": 2, "actions": actions,
                "cacheHitActions": hits, "launchedActions": actions - hits,
                "invocationsServedFromCache": 1 if hits else 0,
                "hitRate": round(hits / actions, 4)}}

        samples = [
            {"coldB": side(1000.0, 0, 4), "warmB": side(700.0, 3, 4)},
            {"coldB": side(1100.0, 0, 4), "warmB": side(900.0, 2, 4)},
            {"coldB": side(1200.0, 0, 4), "warmB": side(800.0, 3, 4)},
        ]
        summary = bench.cross_project_summary("liba", "libb", samples)

        self.assertEqual(summary["scenario"], "cross_project_trycompile_reuse")
        self.assertEqual(summary["hitRate"], 0.6667)
        self.assertEqual(summary["warmBTryCompileCacheHits"], 8)
        self.assertEqual(summary["warmBTryCompileActions"], 12)
        self.assertEqual(summary["coldBaselineHitRate"], 0.0)
        self.assertEqual(summary["wallSavingMs"]["medianWallMs"], 300.0)
        self.assertEqual(summary["wallSavingMs"]["bestWallMs"], 200.0)
        self.assertEqual(summary["wallSavingMs"]["worstWallMs"], 400.0)
        self.assertEqual(summary["coldBWallMs"]["medianWallMs"], 1100.0)
        self.assertEqual(summary["wallSavingPct"], 27.27)
        self.assertEqual(summary["status"], "recorded")

    def test_summary_applies_the_hit_rate_threshold(self):
        sample = {
            "coldB": {"wallMs": 10.0, "tryCompile": {
                "invocations": 1, "actions": 2, "cacheHitActions": 0,
                "launchedActions": 2, "invocationsServedFromCache": 0,
                "hitRate": 0.0}},
            "warmB": {"wallMs": 10.0, "tryCompile": {
                "invocations": 1, "actions": 2, "cacheHitActions": 1,
                "launchedActions": 1, "invocationsServedFromCache": 0,
                "hitRate": 0.5}},
        }
        env = bench.CROSS_PROJECT_MIN_HIT_RATE_ENV
        previous = os.environ.get(env)
        try:
            os.environ[env] = "0.9"
            failing = bench.cross_project_summary("a", "b", [sample])
            os.environ[env] = "0.5"
            passing = bench.cross_project_summary("a", "b", [sample])
        finally:
            if previous is None:
                os.environ.pop(env, None)
            else:
                os.environ[env] = previous
        self.assertEqual(failing["status"], "fail")
        self.assertEqual(passing["status"], "pass")


if __name__ == "__main__":
    unittest.main()
