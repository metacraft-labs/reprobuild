#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "cmake_generator_competitiveness_bench.py"

spec = importlib.util.spec_from_file_location("cmake_generator_competitiveness_bench", SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class NinjaStatsParserTests(unittest.TestCase):
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

    def test_build_command_passes_native_args_after_separator(self):
        command = bench.build_command("cmake", "build-dir", "all", 4, ["-d", "stats"])

        self.assertEqual(
            command,
            ["cmake", "--build", "build-dir", "--target", "all", "--parallel", "4", "--", "-d", "stats"],
        )


if __name__ == "__main__":
    unittest.main()
