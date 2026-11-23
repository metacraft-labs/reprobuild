#!/usr/bin/env python3
"""Delete the binaries of failed `.#test-builds` actions before the runner walks
`build/test-bin`, so a copy left by an EARLIER run is never executed as if this
revision had built it.

usage: drop_failed_test_binaries.py <build-failure-report.json> <bin-dir>

Exit 0, after naming every binary it removed, when the rest of the suite can
run soundly. Exit 1, naming why, when it cannot tell which binaries are stale:
no report attributed to this build, a blocked action (the failure report does
not list a blocked action's outputs), a failed action with no recorded outputs,
or an output outside <bin-dir>. `scripts/run_tests.sh` then stops, as it did
before this existed.
"""
import json
import os
import sys


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    report_path, bin_dir = argv[1], os.path.normpath(argv[2])
    try:
        with open(report_path) as f:
            report = json.load(f)
    except (OSError, ValueError) as err:
        print(f"drop_failed_test_binaries: no usable failure report ({err}); "
              "cannot tell which test binaries are stale", file=sys.stderr)
        return 1
    blocked = report.get("blockedActions") or []
    if blocked:
        print(f"drop_failed_test_binaries: {len(blocked)} blocked action(s); "
              "the report does not list their outputs", file=sys.stderr)
        return 1
    failed = report.get("failedActions") or []
    if not failed:
        print("drop_failed_test_binaries: the report names no failed action",
              file=sys.stderr)
        return 1
    removals = []
    for action in failed:
        outputs = action.get("outputs") or []
        if not outputs:
            print(f"drop_failed_test_binaries: failed action {action.get('id')} "
                  "has no recorded outputs", file=sys.stderr)
            return 1
        for out in outputs:
            norm = os.path.normpath(out)
            if os.path.dirname(norm) != bin_dir:
                print(f"drop_failed_test_binaries: {action.get('id')} writes "
                      f"{out}, outside {bin_dir}", file=sys.stderr)
                return 1
            removals.append((action.get("id"), norm))
    for action_id, path in removals:
        existed = os.path.lexists(path)
        if existed:
            os.remove(path)
        print(f"::error:: test binary NOT BUILT ({action_id}): {path}"
              f"{' (stale copy removed)' if existed else ''}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
