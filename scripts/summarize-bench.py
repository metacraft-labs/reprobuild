#!/usr/bin/env python3
"""Summarize a cmake-vs-ninja benchmark JSON result file."""
import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 2:
        print("usage: summarize-bench.py <result.json> [<result.json> ...]")
        sys.exit(2)
    for path in sys.argv[1:]:
        p = Path(path)
        with p.open() as f:
            d = json.load(f)
        print(f"# {p.name}")
        rows = []
        for proj in d.get("projects", []):
            for r in proj.get("ratios", []):
                rows.append(
                    (
                        proj["key"],
                        r["scenario"],
                        r["executionMode"],
                        r["ninjaWallMs"],
                        r["reprobuildWallMs"],
                        r["ratioReprobuildToNinja"],
                    )
                )
        col_widths = [max(len(str(row[i])) for row in rows + [(0,) * 6]) for i in range(6)]
        header = ("project", "scenario", "mode", "ninjaMs", "reproMs", "ratio")
        for h, w in zip(header, col_widths):
            print(f"{h:>{w}}", end="  ")
        print()
        for row in rows:
            project, scenario, mode, ninja_ms, repro_ms, ratio = row
            ratio_str = f"{ratio:.3f}" if ratio is not None else "n/a"
            print(
                f"{project:>{col_widths[0]}}  "
                f"{scenario:>{col_widths[1]}}  "
                f"{mode:>{col_widths[2]}}  "
                f"{ninja_ms:>{col_widths[3]}.0f}  "
                f"{repro_ms:>{col_widths[4]}.0f}  "
                f"{ratio_str:>{col_widths[5]}}"
            )
        print()


if __name__ == "__main__":
    main()
