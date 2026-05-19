#!/usr/bin/env python3
import importlib.util
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
                "--stats",
            ],
        )

    def test_ratio_records_execution_mode(self):
        record = bench.ratio_record(
            "demo", "noop_rebuild", "direct",
            {"wallMs": 10.0}, {"wallMs": 25.0})

        self.assertEqual(record["executionMode"], "direct")
        self.assertEqual(record["ratioReprobuildToNinja"], 2.5)

    def test_selected_execution_modes_expands_both(self):
        self.assertEqual(
            bench.selected_execution_modes("both"),
            ["cmake-driver", "direct"],
        )


if __name__ == "__main__":
    unittest.main()
