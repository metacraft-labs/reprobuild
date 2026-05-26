#!/usr/bin/env python3
"""Aggregate per-`repro build`-invocation stats files into a configure-level
breakdown.

Each `repro build` invocation writes one JSON file to ``$REPRO_STATS_DIR``
containing its wall time, exit code, fast-path tag, and the full BuildStats
metric set. This script reads those files and rolls them up.

Usage:
    REPRO_STATS_DIR=$(mktemp -d) cmake -S src -B build -G Reprobuild
    python aggregate-stats.py "$REPRO_STATS_DIR"
"""
import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path


def load_records(stats_dir):
    records = []
    for entry in sorted(Path(stats_dir).glob("*.json")):
        try:
            with entry.open() as f:
                records.append(json.load(f))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"# skipping {entry.name}: {exc}", file=sys.stderr)
    return records


def fmt_ms(value):
    return f"{value:8.1f}"


def render_summary(records, total_wall_ms=None):
    if not records:
        return "(no stats records found)"

    fast_counts = defaultdict(int)
    invocation_wall = 0.0
    metric_totals_ms = defaultdict(float)
    metric_counts = defaultdict(int)
    exit_codes = defaultdict(int)
    for r in records:
        tag = r.get("fastPath") or "slow-path"
        fast_counts[tag] += 1
        invocation_wall += r.get("wallMs", 0.0)
        exit_codes[r.get("exitCode", 0)] += 1
        for m in r.get("metrics", []):
            metric_totals_ms[m["name"]] += m.get("totalUs", 0.0) / 1000.0
            metric_counts[m["name"]] += m.get("count", 0)

    out = []
    out.append(f"# invocations: {len(records)}")
    out.append("# fast-path distribution:")
    for tag, count in sorted(fast_counts.items(), key=lambda x: -x[1]):
        out.append(f"    {count:4d}  {tag}")
    out.append("# exit codes:")
    for code, count in sorted(exit_codes.items()):
        out.append(f"    {count:4d}  exit={code}")
    out.append("")
    out.append(f"sum of repro-build invocation wall:  {fmt_ms(invocation_wall)} ms")
    if total_wall_ms is not None:
        out.append(f"outer configure wall:                {fmt_ms(total_wall_ms)} ms")
        out.append(
            f"residual (cmake + spawn + gcc outside repro): "
            f"{fmt_ms(total_wall_ms - invocation_wall)} ms"
        )

    out.append("")
    out.append("# top metrics by aggregate total (across all invocations)")
    out.append(f"{'metric':38s}  {'count':>5s}  {'total ms':>10s}")
    sorted_metrics = sorted(
        metric_totals_ms.items(), key=lambda kv: -kv[1]
    )
    for name, total_ms in sorted_metrics[:25]:
        out.append(
            f"{name[:38]:38s}  {metric_counts[name]:5d}  {total_ms:10.1f}"
        )
    return "\n".join(out)


def render_per_invocation(records):
    lines = ["# per-invocation wall times"]
    lines.append(f"{'#':>3s}  {'fastPath':25s}  {'wall ms':>8s}  target")
    for i, r in enumerate(records):
        tag = (r.get("fastPath") or "slow-path")[:25]
        wall = r.get("wallMs", 0.0)
        target = r.get("target", "?")
        if len(target) > 70:
            target = "..." + target[-67:]
        lines.append(f"{i:3d}  {tag:25s}  {wall:8.1f}  {target}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stats_dir", help="path to REPRO_STATS_DIR")
    parser.add_argument(
        "--outer-wall-ms", type=float, default=None,
        help="outer-wrapper wall time (e.g. the configure command) for residual computation",
    )
    parser.add_argument(
        "--per-invocation", action="store_true",
        help="also print per-invocation rows",
    )
    args = parser.parse_args()

    records = load_records(args.stats_dir)
    print(render_summary(records, total_wall_ms=args.outer_wall_ms))
    if args.per_invocation:
        print()
        print(render_per_invocation(records))


if __name__ == "__main__":
    main()
